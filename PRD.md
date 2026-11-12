# PRD — `codemux` (working name)

One command to make Termux "ready to use": OpenCode V1 + V2 + menu/banner + a
base toolset + storage, both on a bare Termux and on a partially set-up one.
New repo, public, idempotent (safe to run repeatedly).

Status: **DRAFT v2 — no code yet.** The name and the 3 main decisions are approved (see §18).

---

## 1. Problem

Installing a working setup is currently spread over 3 places and 3 memories:

| Item | Today | Consequence |
|---|---|---|
| OpenCode V1 | `opencode-termux` repo | installs itself, upgrades itself |
| OpenCode V2 | `opencode-termux-v2` repo | same + glibc/LD_PRELOAD shim |
| Toolset (chromium, gh, python, etc.) | manual commands in notes | forgotten, versions drift |
| Menu + banner + guide | local `~/.bashrc` | lost when Termux is uninstalled |
| Android storage | manual `termux-setup-storage` | forgotten, broken paths |
| Health check | `doctor.sh` per repo | no end-to-end check |

Goal: **one copy-paste line** → everything installed, verified, and updatable
with a single command.

---

## 2. Goals

1. `curl … | bash` → a bare Termux becomes ready to use (V1, V2, menu, toolset, storage).
2. Idempotent: run on an already set-up Termux → only fills what is missing,
   never overwrites user config.
3. `codemux check` reports the status of each component (installed / missing / broken).
4. `codemux upgrade` updates apt packages, the selected V1/V2 payloads, and the
   launcher in one go.
5. Every step has detection (precheck) + action + verification + rollback.
6. Transparent: every action is printed, `--dry-run` included.
7. **Cross-session memory** for V1 *and* V2: a new conversation immediately knows
   the memory + summary of earlier sessions (§12A).
8. **Automatic update check**: when an upstream repo has a new release a notice
   appears; once approved, the latest version is downloaded & installed (§12B).

## 3. Non-goals (out of scope for v1)

- Does not replace the Termux package manager; it only orchestrates `pkg`/`apt`.
- Does not store any token/secret (no automatic GitHub login).
- Does not build from source (everything prebuilt).
- Does not support architectures other than `aarch64` (arm64 Android) in v1.
- Does not delete user data (never `rm -rf` inside HOME/config).

## 4. Users & scenarios

| Scenario | Starting point | Expected |
|---|---|---|
| S1 bare Termux | nothing installed | everything installed, menu appears, `doctor` green |
| S2 half set-up Termux | V1 present, V2 missing | V2 + menu + missing toolset installed, V1 skipped |
| S3 fully set-up Termux | everything present | everything skipped, finishes in < 60 seconds, no files changed |
| S4 Update | present, old versions | `upgrade` → apt + V1/V2 bumped, config kept |
| S5 Broken | V2 fails on glibc/LD_PRELOAD | `doctor` points at the cause + `repair` fixes it |
| S6 Offline | no internet | stops fast, clear message, can continue (`--resume`) |

---

## 5. Design principles

1. **Detect first, act later.** Every module has a `probe()`; when it already
   qualifies → `SKIP` and record it.
2. **Non-destructive.** User files (`.bashrc`, `MEMORY.md`, plugins) are backed up
   to `~/.config/codemux/backup/<timestamp>/` before being changed; merge, don't
   overwrite.
3. **Resumable.** Per-module state (`DONE/SKIP/FAIL`) so a rerun needs no new
   downloads.
4. **No `jq`/python needed for orchestration.** State = a plain TSV.
5. **Single source of truth.** V1/V2 logic is not duplicated; `codemux` calls the
   official installers from the `opencode-termux` and `opencode-termux-v2` repos.
6. **Adapter, not a copy.** `lib/v1.sh` & `lib/v2.sh` call the official installer of
   each repo; when a repo is unreachable, use the last release tarball cached in
   `~/.cache/codemux/`.
7. **Safe on a busy Termux.** `apt-mark hold opencode` so `pkg upgrade` does not
   overwrite the V1 payload (a bug that really happened).

---

## 6. Commands (CLI)

```
codemux [command] [options]

commands:
  install            install everything that is missing (default)
  check              status of each module, changes nothing
  upgrade            apt + the selected V1/V2 payloads + launcher (update prompt)
  update-check       check upstream for new releases, write the cache, exit (no install)
  repair             fix modules that failed/broke
  doctor             full diagnosis (shareable, no sensitive data)
  uninstall          remove components (needs confirmation; user config stays)
  self-update        update codemux itself

options:
  --yes / -y         no confirmation
  --dry-run          print the plan, do not execute
  --only a,b,c       limit to specific modules (for `install`: v1, v2, or both)
  --skip a,b,c       skip specific modules
  --latest           use the newest versions (ignore versions.env)
  --no-storage       do not run termux-setup-storage
  --no-memory        do not install the memory feature (default: installed)
  --auto-update      download+install right away when an update exists (default: ask)
  --no-update-check  skip the update check during install/upgrade
  --mirror auto|id|official
  --json             machine output (for `check`/`doctor`)
  --verbose          show the commands being run
```

Exit codes: `0` success/satisfied, `1` partial failure, `2` prerequisites not
met (not Android / wrong arch / not enough disk).

### 6A. Component selection (V1 only / V2 only / both)

The user picks which OpenCode to install; every shared dependency is installed
either way, so any choice works on a fresh Termux.

```
codemux install --only v1     # OpenCode V1 only (V2 is not touched)
codemux install --only v2     # OpenCode V2 only
codemux install --only both   # V1 + V2 (default)
```

- `--components X` is an alias; `CODEMUX_COMPONENTS=v1` does the same.
- Without a flag/env (interactive): an arrow-key picker appears once
  (↑/↓ + Enter, or 1/2/3; q cancels). Without a TTY (CI, `curl | bash`) the
  saved/default choice is used — default `v1 v2`.
- The choice is saved in `~/.config/codemux/components` (`v1`, `v2`, `v1 v2`)
  and reused by `install`, `check`, `update-check`; `--only` overrides it.
- Base modules are always installed: `deps mirror storage toolset glibc` +
  `launcher dotfiles memory self`. Only the payload module (`v1`/`v2`) follows
  the choice, so V1-only = 10 modules, V2-only = 10, both = 11.
- `check` reports an unselected component as `SKIP` ("not selected") and counts
  it in `ringkasan.skip`; `--json` gains a `komponen` key.
- `upgrade` (no `--only`) updates apt + **only the payloads actually installed**
  (detected by `$PREFIX/share/opencode{,-v2}/opencode.real`) + the launcher, so
  a V1-only device never pulls V2 in; `update-check` omits rows for components
  that are not installed.
- The startup menu always shows V1 and V2. A missing component is marked
  "not installed" and selecting it asks for confirmation before installing only
  that component.

### 6B. Progress feedback (never look frozen)

Long operations report live progress on stderr, one line, overwritten in place:

```
[4/11] toolset    | installing (37s)
[6/11] v1         / waiting for the upstream V1 installer (1m 12s)
  ↓ downloading memory.js (7 KB)
```

- `codemux_spin_start <prefix> [message]` / `codemux_spin_msg` /
  `codemux_spin_size <file>` / `codemux_spin_stop` live in `lib/common.sh`.
- Downloads report the growing `.part` size; the message comes from
  `codemux_download`, so every module (plugins, adapters, self-update) gets it.
- `log_*` pause the spinner first, so lines never collide.
- Automatic silence when stderr is not a TTY; `CODEMUX_PROGRESS=1` forces it on
  (tests), `CODEMUX_PROGRESS=0` / `CODEMUX_NO_PROGRESS=1` turns it off.
- `install.sh` shows a curl/wget progress bar for the release tarball,
  `extracting…`, then hands over to `codemux install`.

---

## 7. Repo architecture

```
codemux/
├── install.sh              # small bootstrap: download the release → run bin/codemux
├── bin/codemux        # entry point (bash), loads lib/*.sh
├── lib/
│   ├── common.sh           # log, colors, die, need, backup, confirm, state
│   ├── state.sh            # read/write the state TSV, resume
│   ├── modules/*.sh        # 1 file per module (see §8)
│   ├── memory.sh           # install/merge V1+V2 memory (§12A)
│   ├── updater.sh          # check upstream releases + prompt (§12B)
│   ├── v1.sh               # adapter to the opencode-termux repo
│   └── v2.sh               # adapter to the opencode-termux-v2 repo
├── assets/
│   ├── bashrc-snippet      # banner + arrow menu + guide (marked block)
│   ├── bash_profile        # `. ~/.bashrc`
│   └── hushlogin           # hide the stock MOTD
├── memory/                 # templates: MEMORY.md, AGENTS.md, opencode.jsonc
├── plugins/                # memory.js + session-digest.py (mechanism only)
├── versions.env            # pinned versions (V1, V2, chromium, …)
├── tools/doctor.sh         # diagnosis
└── tests/
    ├── sandbox-home.sh     # test installing twice in a fake HOME
    └── smoke.sh
```

`install.sh` is deliberately small (< 60 lines): make sure `curl` exists, download
the release tarball, verify the sha256, extract to `~/.cache/codemux/src`, then
execute.

---

## 8. Modules & detection (the core mechanism)

Execution order = the table below. `probe` decides SKIP/APPLY.

| # | Module | Detection (probe) | Action when missing |
|---|---|---|---|
| 0 | `preflight` | `uname -o`=Android, `uname -m`=aarch64, `id -u`≠0, disk ≥ 3 GB, DNS ok | refuse with a clear message |
| 1 | `bootstrap-deps` | `command -v curl tar sha256sum` | `pkg update -y && pkg install -y curl tar coreutils` |
| 2 | `mirror` | contents of `$PREFIX/etc/apt/sources.list` + `apt-get update` < N seconds | non-interactive `termux-change-repo` / write sources.list |
| 3 | `storage` | `[ -d ~/storage ]` and `/sdcard` writable | `termux-setup-storage` (interactive! see §11) |
| 4 | `apt-toolset` | `dpkg-query -W` for each package in `versions.env` | `pkg install -y <missing packages>` (including the `browser` group: chromium, playwright, agent-browser) |
| 5 | `glibc-runtime` | `$PREFIX/glibc/lib/ld-linux-aarch64.so.1` exists | `pkg install -y glibc-repo glibc termux-exec-glibc` |
| 6 | `opencode-v1` | `$PREFIX/share/opencode/opencode.real --version` | call `lib/v1.sh` (install/upgrade) + `apt-mark hold opencode` (only when V1 is selected) |
| 7 | `opencode-v2` | `$PREFIX/share/opencode-v2/VERSION` + `opencode-v2 --version` | call `lib/v2.sh` (npm tarball + `lib/compat` shim + env sanitizing) (only when V2 is selected) |
| 8 | `launcher` | `~/.bashrc` contains the `# codemux:launcher v1` marker | back up, then insert the block from `assets/bashrc-snippet` |
| 9 | `dotfiles` | `~/.bash_profile`, `~/.hushlogin` | write/merge (never overwrite other content) |
| 10 | `memory` | `memory.js` + `session-digest.py` present, `instructions` lists `MEMORY.md` & `RECENT.md` | install the templates + merge `opencode.jsonc`; existing files are **not** overwritten; `--no-memory` skips it |
| 11 | `update-check` | `~/.config/codemux/update-cache.tsv` younger than 24 hours | check upstream releases (`releases/latest` redirect, no API quota), write the cache; `--no-update-check` skips it |
| 12 | `verify` | run `doctor` | short report + exit code |

Per-module contract:

```bash
module_probe()   # 0 = already satisfied, 1 = action needed
module_apply()   # 0 = success, !=0 failure
module_verify()  # 0 = actually working
```

Uniform output: `[3/11] storage        SKIP  (already present)`,
`[6/11] opencode-v1    APPLY (1.19.0 → 1.19.3)`, `… OK`, `… FAIL (reason)`.

---

## 9. State & resume

`~/.config/codemux/state.tsv` (append-only, human readable):

```
# ts             module         status  version  note
2026-10-22T19:40  preflight      DONE    -       android/aarch64, disk 3.3G
2026-10-22T19:41  apt-toolset    SKIP    -       145 packages already present
2026-10-22T19:44  opencode-v2    APPLY   2.1.2   compat shim installed
```

Backup: `~/.config/codemux/backup/20261022-194000/.bashrc` etc.
Lock: `~/.config/codemux/lock` (prevents 2 parallel processes).

---

## 10. Installer flow (phases)

```
[bootstrap]  install.sh: check bash+curl → download the release tarball → sha256 → exec bin/codemux install
     │
[preflight]  OS/arch/uid/disk/DNS/bash version → failure = stop (exit 2)
     │
[plan]       probe every module → print the plan table (APPLY/SKIP) → confirm (unless -y / --dry-run)
     │
[execute]    modules 1..10 in order; per module: apply → verify → record state
     │        one failing module ≠ total failure: continue, collect the FAIL list
     │
[verify]     full doctor → summary: OK/SKIP/FAIL + suggested next steps
     │
[done]       print: how to open the menu, how to upgrade, where the log is
```

Full log: `~/.config/codemux/logs/<timestamp>.log` (mode 600).

---

## 11. `termux-setup-storage` (special, interactive)

The Android permission dialog cannot be fully automated. Mechanism:

1. `probe`: when `~/storage` exists and `/sdcard/Android` is readable → SKIP.
2. Otherwise: run `termux-setup-storage` and **wait**; instruct the user to
   "tap Allow on screen". Timeout 90 seconds.
3. On failure/timeout: record `WARN`, continue with the other modules (not
   fatal), show the manual steps at the end.
4. `--no-storage` skips this step entirely.

---

## 12. Upgrade & maintenance

| Command | Contents |
|---|---|
| `codemux upgrade` | `pkg update && pkg upgrade -y` (opencode held) → `lib/v1.sh upgrade` → `lib/v2.sh upgrade` (only the installed components) → re-sync the launcher block (version) → `doctor` |
| `codemux self-update` | download the latest `codemux` release, replace `bin/`+`lib/` (assets untouched when the user modified them) |
| `codemux repair` | pick modules in FAIL/broken state → apply again (e.g. reinstall the V2 compat shim, sanitize `LD_PRELOAD`) |
| `codemux uninstall` | remove the V1/V2 payloads + launcher block; does **not** delete `MEMORY.md`, projects, or backups |

Optional schedule: Termux has no cron by default → it is enough to suggest
"run `codemux upgrade` once a month".

---

## 12A. Cross-session memory feature (V1 + V2)

Problem: every `/new` (V1) or new session (V2) starts from zero; facts discussed
earlier are gone. `codemux` installs a mechanism that is **identical for both
versions**: memory contents stay local, the repo only holds the mechanism
(templates).

### What gets installed (the `memory` module)

| File | Role | When it already exists |
|---|---|---|
| `~/.config/opencode/opencode.jsonc` | `instructions: ["MEMORY.md","RECENT.md"]` | **merge**: add the missing entries, never remove other keys |
| `~/.config/opencode/MEMORY.md` | permanent memory (facts, decisions, paths) | **not** overwritten |
| `~/.config/opencode/AGENTS.md` | permanent rules (language, style, prohibitions) | not overwritten |
| `~/.config/opencode/RECENT.md` | summary of the last 8 sessions (auto-generated) | created/overwritten by every digest |
| `~/.config/opencode/bin/session-digest.py` | producer of `RECENT.md` | not overwritten (compare script versions) |
| `~/.config/opencode/plugins/memory.js` | `memory_save` tool + compaction hook + digest refresh | not overwritten; when a newer version exists → offer `--force` |
| `~/.bashrc` (`# codemux:memory` block) | run the digest before opencode starts | only added when `_oc_refresh_digest` is missing |

### How one plugin serves two versions

`memory.js` has a dual default export:

```js
export default {
  id: 'memory',
  setup(ctx) { … },   // V2: Plugin.define, tools through ctx.tool.transform
  server() { … },     // V1: classic plugin server
}
```

The V1 helpers/tools are imported **dynamically** inside `server()` so V2 never
loads V1 packages (that used to crash).

### Digest data sources

| Version | Database | Tables |
|---|---|---|
| V1 | `~/.local/share/opencode/opencode.db` | `session`, `message`, `part` |
| V2 | `~/.opencode-v2/data/opencode/opencode.db` | `session_v2`, `session_message` |

The digest takes the **last 8 sessions from both**, one paragraph per session
(the user's commands + the final result, truncated to ~600 characters), written
to `RECENT.md`, which is loaded automatically through `instructions`.

### Important rules

1. **Hard limit for `MEMORY.md` = 24,000 bytes.** The plugin refuses to write past
   it (proven in production). `doctor` checks the size; above 90% of the limit →
   warning + trimming advice (`codemux memory prune` only **suggests**, it does
   not delete).
2. **Never overwrite user memory.** A reinstall must not wipe
   `MEMORY.md`/`AGENTS.md` — that is the most expensive mistake.
3. **No personal data in the repo.** The repo only holds templates; memory
   contents are never pushed.
4. **V1/V2 isolation.** Both share the config folder (same memory), but the
   session DBs are separate; the digest reads both.
5. **Verification**: the `memory` module (probe = verify) checks that the files
   exist, `instructions` lists `MEMORY.md` & `RECENT.md`, the digest wrapper is
   present, and `MEMORY.md` is < 24,000 bytes. `tests/launcher-memory.sh` tests
   fresh installs, personal data not being overwritten, a config missing entries,
   adoption of an old block, idempotency, and a broken `~/.bashrc` (restored, not
   left broken).
6. **`--no-memory`** skips the whole module (for those who want a clean config).

### Related commands

```
codemux memory              # status + size of MEMORY.md/RECENT.md (read-only)
codemux memory --json       # for scripts
```

`memory digest` and `memory prune --dry-run` are not implemented yet; for now the
digest runs automatically through the `~/.bashrc` wrapper and the plugin, and
trimming memory is done manually on `doctor`'s advice (M5).

---

## 12B. Automatic update check + download after approval

Problem: Termux has no cron; V1/V2/codemux versions go stale quickly and nothing
notifies anyone. Solution: a light check when the menu opens, a notification, then
download only after approval.

### Sources being checked

| Component | How the latest version is fetched | Quota cost |
|---|---|---|
| `codemux` | redirect `https://github.com/kusnuzon/codemux/releases/latest` → tag | 0 (no API) |
| `opencode-termux` (V1) | redirect `…/opencode-termux/releases/latest` | 0 |
| `opencode-termux-v2` (V2) | redirect `…/opencode-termux-v2/releases/latest` | 0 |
| apt packages | `apt list --upgradable` (uses the cache) | 0 |
| local versions | `dpkg-query`, `$PREFIX/share/opencode-v2/VERSION`, `codemux --version` | 0 |

The GitHub API is only used as a **fallback** (quota 60/hour without a token).

### Flow

```
menu opens
   └─ update cache < 24 hours? ── yes ──> show the notice line (instant)
                │ no
                └─ run `codemux update-check --quiet` in the background
                   (6 second timeout, output to the cache, never blocks the prompt)
                        └─ done → cache updated → the notice appears
                           on the next menu / when returning from opencode

a newer version exists:
   ⬆ updates available: V2 2.1.2 → 2.1.3 · codemux 1.0.0 → 1.1.0
     press [u] to update now (later: codemux upgrade)
   └─ [u] → change summary → confirm [y/N]
             └─ y → download the release → sha256 → backup → install → verify
                    ├─ success → new version shown, cache cleared
                    └─ failure → automatic rollback + report
```

### Configuration (`~/.config/codemux/config`)

```ini
auto_update_check=on        # on|off
auto_update_mode=ask        # ask (default) | notify | auto
check_interval=24h
include_apt=yes
```

- `ask` → notify + ask before downloading (**default**).
- `notify` → only informs, never asks.
- `auto` → download+install right away (`--auto-update`), still with backup + verify.

### Safety & behaviour

- Never updates while an opencode/TUI session is running — only from the menu/CLI.
- Every download is sha256-verified; the old payload is backed up
  (`~/.config/codemux/backup/<ts>/`) and restored when `verify` fails.
- Offline/timeout → fails **silently**, the cache is not modified, startup is
  unaffected.
- `opencode` stays `apt-mark hold` so apt does not overwrite the V1 payload.
- Check/download history is logged in `~/.config/codemux/logs/update.log` (mode 600).

### Related commands

```
codemux update-check            # check now, print the version table
codemux update-check --json     # for scripts
codemux upgrade                 # show the summary → confirm → install
codemux upgrade --yes           # no questions
codemux upgrade --only v2       # a single component (apt,v1,v2,launcher)
```

M5 implementation: `lib/update.sh` (`releases/latest` redirect, cache
`~/.config/codemux/update-cache.tsv`, `CODEMUX_FAKE_TAG_*` /
`CODEMUX_FAKE_LOCAL_*` overrides for tests), `lib/maintenance.sh` (doctor,
upgrade, uninstall), the update notice in the launcher block (at most one
background check per 6 hours), `tests/maintenance.sh`.

---

## 13. Security & reliability

- Every download is `sha256`-verified (recorded in `versions.env` / release notes).
- No layered `curl | bash`: the bootstrap downloads a tarball, not a second piped script.
- Never writes a token; `gh` is not authenticated automatically.
- `set -Eeuo pipefail`, `shellcheck -S warning` must pass in CI.
- No `rm -rf` on a path containing `$HOME`, except the internal
  `~/.cache/codemux/src` path.
- Mode of new config files: `600` for state/log.

---

## 14. Non-functional targets

| Metric | Target |
|---|---|
| S3 time (everything present) | < 60 seconds |
| S1 time (bare → ready) | 10–25 minutes on 4G (downloads ±1.2–1.5 GB) |
| Minimum disk space checked | 3 GB free |
| Repo size (no binaries) | < 300 KB |
| Idempotency | run twice → the second run changes 0 files (checked with `find -newer`) |
| Network failure | clear message + `--resume` does not re-download what is present |
| Session digest (8 sessions, V1+V2) | < 2 seconds, never blocks the prompt |
| Update check (background) | < 6 seconds, never blocks the menu |
| Update-check cache | 1× per 24 hours per component |

---

## 15. Acceptance criteria (Given/When/Then)

1. **S1** Given a bare Termux without config, When `install -y`, Then `opencode`,
   `opencode-v2`, `menu`, `version`, `doctor` are available; `doctor` exits 0; the
   menu appears in a new session.
2. **S2** Given V1 present & V2 missing, When `install -y`, Then the V1 module is
   recorded as `SKIP` and no V1 file changes (same hash).
3. **S3** Given everything installed, When `install -y` twice, Then the second run
   is all `SKIP` and no file in `$HOME` changes (except state/log).
4. **S4** Given the user's `.bashrc` has its own content, When `install`, Then the
   launcher block is inserted and the old content stays; a backup is available.
5. **S5** Given a bionic `LD_PRELOAD` is active, When running `opencode-v2`, Then it
   still runs (env sanitizing) — verified by `doctor`.
6. **S6** Given no internet, When `install`, Then it stops at preflight with exit 2
   and an actionable message.
7. **S7 (memory)** Given the install finished, When opening a new V1 *and* V2
   session, Then `MEMORY.md` + `RECENT.md` are loaded automatically; `memory_save`
   writes facts; other sessions read them. Given `MEMORY.md` already holds user
   content, Then its hash does not change after the install.
8. **S8 (update)** Given the local version is older than the upstream release,
   When the menu opens, Then the `⬆ updates available` line appears; When answering
   `y`, Then it is downloaded + the sha256 matches + the version goes up; When
   answering `n`, Then nothing is downloaded. Given offline, Then the update check
   fails silently (startup is unaffected).

---

## 16. Risks & mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Apt mirror slow/dead | install hangs | speed probe, official mirror fallback, per-apt timeout |
| `raw.githubusercontent.com` stale cache (has happened) | old script used | download through the `Accept: vnd.github.raw` API + release tarball + `VERSION` check |
| `apt-mark hold` forgotten | `pkg upgrade` overwrites the V1 payload | the V1 module must set the hold + doctor checks it |
| bionic `LD_PRELOAD` | V2 fails to start | env sanitizing in the launcher & service; doctor checks |
| Storage permission denied | broken project paths | non-fatal WARN + manual instructions |
| 3 GB disk | downloads fail midway | preflight disk check, `--only` to save space |
| Overwriting the user's `.bashrc` | lost config | block markers + backup + merge |
| Two concurrent processes | corrupt state | lockfile |
| `MEMORY.md` > 24,000 bytes (hard plugin limit, has happened) | `memory_save` fails | `doctor` warns + `codemux memory prune --dry-run` suggests trimming (never deletes automatically) |
| `RECENT.md` grows | wasted context | the digest is limited to 8 sessions, each truncated to ~600 characters |
| False update notice / local version newer | pointless download | compare semver; `update-check --json` shows the version source |
| GitHub API limit (60/hour) | check fails | use the `releases/latest` redirect (no quota), API only as fallback |
| An update is offered while an opencode session runs | disruptive | only offered from the menu/CLI, never while the TUI is active |

---

## 17. Milestones

| # | Contents | Output |
|---|---|---|
| M1 | skeleton: `bin`, `lib/common`, `state`, `preflight`, `check` | `codemux check` works ✅ |
| M2 | env modules: deps, mirror, storage, apt-toolset, glibc (+ resume/atomic §20) | Termux "tool-ready" ✅ |
| M3 | V1 & V2 adapters (call the existing repos) | `opencode`, `opencode-v2` work [done] |
| M4 | launcher: banner+guide menu, dotfiles, **V1+V2 memory** (§12A) | startup screen + memory done ✅ |
| M5 | `doctor`, `upgrade`, `repair`, `uninstall`, **`update-check` + update prompt** (§12B) | maintenance ✅ |
| M6 | CI: shellcheck, sandbox HOME test, release tarball | 1.0 release ✅ |

---

## 18. Decisions that need approval

| # | Question | Recommendation |
|---|---|---|
| D1 | Repo name | **`codemux`** (chosen) |
| D2 | Duplicate the V1/V2 logic? | **Adapter** — call the `opencode-termux` & `opencode-termux-v2` repos (chosen) |
| D3 | Include personal memory? | Templates only, via `--with-memory`, never overwriting (**approved**) |
| D4 | Default apt mirror | `auto` (fast probe, official fallback) (**approved**) |
| D5 | Does "from scratch" Termux include Chromium/Playwright? | **Yes, installed by default** (chosen); can be skipped with `--skip browser` (saves ~400 MB) |
| D6 | Output language | English (default), `--lang id` later (**approved**) |
| D7 | Memory feature installed by default? | **Yes, ON by default** (`--no-memory` to skip) — requested |
| D8 | Update-check behaviour | **Notify first, download after approval**; `--auto-update` for no questions |
| D9 | Update-check interval | **24 hours**, run in the background (6 second timeout) when the menu opens |
| D10 | Update notice inside an opencode session | Later phase (M7), through a plugin that reads the cache |

---

## 19. One command (plan)

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh | bash -s -- --yes
```

Release assets: `codemux.tar.gz` (+ `codemux.tar.gz.sha256`). The bootstrap
downloads both, verifies the sha256, extracts to `~/.cache/codemux/src/current`
(atomic: `current.new` → swap), then `exec bin/codemux install`. When no release
exists yet → `codeload …/refs/heads/main` fallback without sha.

Lightweight variant (no heavy browser/python):

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh \
  | bash -s -- --yes --skip browser,python
```

---

## 20. Surviving a process killed midway (resume & rollback)

The question that must be answered before M2: **if the process dies midway, who
cleans up?** The answer: codemux itself, with no manual step.

The principle: every step must be **idempotent or atomic**, and the state is
written **before** the step starts (`RUNNING`) and `DONE`/`FAILED` after
verification. So a process killed at any moment always reveals where it stopped.

### 20.1 Three layers of defence

| Layer | For steps | How |
|---|---|---|
| Idempotent | apt install, mkdir, writing a config block | check first; when already correct → `SKIP`, not repeated |
| Atomic | downloading a payload, replacing a config file | `.part` → sha256 → `mv` (atomic rename), the old file becomes `.old` |
| Detached from the shell | apt, ~200 MB downloads | `setsid nohup` + pidfile + log; a dying shell/opencode ≠ a dying process |

### 20.2 Human-readable state

`state.tsv` + the `install.run` marker:

```
# step          status     start  finish   note
1 preflight     DONE       19:40  19:40    android/aarch64
2 deps          DONE       19:40  19:41    7 tools present
3 toolset       RUNNING    19:41  -        apt pid 12345
```

`codemux status` shows: which step out of how many, the active pid, the last 10
log lines. If the process is dead, the status stays `RUNNING` but the pid is no
longer alive → codemux knows it was **interrupted**, not finished.

### 20.3 Dead-process detection

- The lock holds a `pid` + `boot-id`; when the pid is dead or the boot-id differs
  (device reboot) → the stale lock is dropped automatically. No manual `rm` needed.
- A `RUNNING` step without a live process → marked `INTERRUPTED` → run again
  **from that step**, not from the beginning.

### 20.4 Steps that must not be repeated carelessly

- **apt**: `DEBIAN_FRONTEND=noninteractive`, `-o Dpkg::Options::=--force-confold`,
  `--no-install-recommends`. Before starting: `dpkg --audit` + `apt-get check`; if
  leftovers from a previous process exist → `dpkg --configure -a` + `apt-get -f
  install` first.
- **OpenCode payload**: download → sha256 → extract to `opencode.new` → test
  `--version` through the loader → **then** swap (`mv` old → `.old`, `mv` new →
  final). If the test fails the old one stays intact; `codemux repair` restores
  `.old`.
- **`.bashrc`/config**: back up to `backup/<ts>/`, write the marked block
  `# codemux:launcher begin` … `# codemux:launcher end`. An incomplete block is
  discarded and the backup is restored by `codemux repair`.

### 20.5 Never break what already works

- Modules that are already `OK` are not touched at all.
- No `rm -rf` on user paths; only codemux temp files are deleted.
- Critical steps (preflight, glibc, payload) use `--stop-on-error`: a failure means
  stop, do not continue into steps that depend on it.

### 20.6 Resumable without any human

1. Open Termux again → the menu reads `install.run` and shows a top line:
   `! installation interrupted at step 3/9 — Enter to continue`.
2. `codemux install` with no arguments = **automatic resume**; `--fresh` to start over.
3. One-command emergency repair: `codemux repair` (dpkg configure, stale lock,
   missing shim, broken config block).

### 20.7 "Kill it midway" tests

`tests/resume.sh` — sandbox with fake `apt`/`curl`, nothing touches the system:

| Scenario | Expectation |
|---|---|
| SIGKILL during the apt step | the next run continues, no duplicates |
| network drops during a download | `.part` is discarded, the next run downloads again |
| stale lock (dead pid) | dropped automatically, not an error |
| wrong payload sha256 | `.new` is discarded, the old payload still works |
| SIGKILL while writing `.bashrc` | the incomplete block is cleaned up, the backup is restored |

Pass criteria: **not a single scenario needs a manual step** beyond running
`codemux install` or `codemux repair` once.

### 20.8 What honestly cannot be guaranteed

If Android kills Termux exactly while dpkg is writing its database, the dpkg DB
can end up half-done. That is **detected** on the next run (`dpkg --audit`) and
repaired automatically (`dpkg --configure -a`, `apt-get -f install`) — still
without manual intervention, it only needs the network again.
