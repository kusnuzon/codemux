# PRD — `codemux` (working name)

One command to make Termux "ready to use": OpenCode V1 + V2 + menu/banner + a
base toolset + storage, both on a bare Termux and on a partially set-up one.
New repo, public, idempotent (safe to run repeatedly).

Status: **implemented — v0.7.4 (2026-11-13).** Every command in §6 exists and is
tested: smoke 44 · launcher-memory 45 · maintenance 19 · resume 16 · release 7 ·
adapter 12. CI (`shellcheck -S warning` + `bash -n` + `check --json` + smoke) runs
on every push. §18 keeps the decision log; §17 shows what is done and what is next.

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
4. `codemux upgrade` updates apt packages, **only the OpenCode payloads that are
   actually installed**, the launcher and the memory mechanism in one go.
5. Every step has detection (precheck) + action + verification + rollback.
6. Transparent: every action is printed, `--dry-run` included.
7. **Cross-session memory** for V1 *and* V2: a new conversation immediately knows
   the memory + summary of earlier sessions (§12A).
8. **Update check**: a notice appears in the startup menu *and* once inside a
   running session when an upstream repo has a new release; updating is a single
   explicit command (`codemux upgrade`, §12B).
9. **Quota awareness**: `kuota` estimates the remaining free-model allowance from
   the local databases and warns before it runs out (§12C).

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
| S6 Offline | no internet | stops fast, clear message, run again later (resume) |

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
  install            install what is missing; safe to repeat & resumes after a break
  check              status of each module (changes nothing)
  status             last install progress, lock, last 10 log lines
  upgrade            apt + installed V1/V2 payloads + launcher + memory mechanism
  update-check       compare local versions with upstream releases (24h cache)
  repair             clean up leftovers from a process that died midway
  doctor             full diagnosis + repair suggestions
  memory             cross-session memory status (read-only)
  uninstall          remove V1/V2 payload + launcher block (memory stays)
  self-update        update the codemux code from the upstream release
  version            codemux version + installed components
  help               the built-in help

install options:
  --dry-run          show the plan, change nothing
  --fresh            start from step 1 (do not resume)
  --only v1|v2|both  OpenCode V1 only, V2 only, or both (default: ask, or keep
                     the saved choice; non-interactive → both)
  --components X     same as --only
  --skip a,b         skip modules (deps,mirror,storage,toolset,glibc,v1,v2,
                     launcher,dotfiles,memory,self)
  -y, --yes          no confirmation, never ask (keep the saved/default choice)

other options:
  check --json       machine-readable output
  update-check --json / --quiet
  repair --dry-run   show the repairs that would be made
  upgrade --only X   apt,v1,v2,launcher,memory (default: everything installed)
  uninstall --purge  also delete ~/.config/codemux (memory/projects are never touched)

progress:
  Long steps show a live spinner with elapsed time and, while downloading, the
  size so far. CODEMUX_PROGRESS=0 (or CODEMUX_NO_PROGRESS=1) silences it;
  non-terminal output is silent automatically, so logs and CI stay clean.
```

Exit codes: `check` → `0` ready · `1` something missing · `2` prerequisite failed.
`install` → `0` finished · `1` a step failed · `2` prerequisite failed · `3`
another install is running.

Environment knobs: `CODEMUX_HOME` (default `~/.config/codemux`),
`CODEMUX_COMPONENTS`, `CODEMUX_GITHUB_TOKEN` / `GITHUB_TOKEN` / `GH_TOKEN`,
`CODEMUX_PROGRESS`, `CODEMUX_ALLOW_NONANDROID` + `CODEMUX_NO_APT_CHECK` (tests),
`CODEMUX_FAKE_TAG_*` / `CODEMUX_FAKE_LOCAL_*` (tests).

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
├── install.sh              # small bootstrap: release tarball + sha256 → bin/codemux
├── bin/codemux             # entry point (bash), sources lib/*.sh
├── lib/
│   ├── common.sh           # log, colors, die, detection, downloads, spinner,
│   │                       #   component choice, token auth
│   ├── state.sh            # state.tsv + run.tsv, lock, log, interruption detection
│   ├── exec.sh             # crash-proof execution: detached spawn, wait,
│   │                       #   atomic write, backup
│   ├── install.sh          # `install` plan, picker, module order, `status`
│   ├── check.sh            # `check` (+ --json)
│   ├── maintenance.sh      # upgrade, doctor, uninstall
│   ├── update.sh           # update-check, cache, version compare
│   ├── memory.sh           # `memory` status
│   ├── repair.sh           # `repair`
│   ├── selfupdate.sh       # `self-update`
│   ├── adapter.sh          # download + run the upstream V1/V2 installers
│   └── modules/*.sh        # 1 file per module (see §8)
├── templates/
│   ├── bashrc-block.sh     # banner + arrow menu + update notice (marked block)
│   ├── jsonc-instructions.py
│   └── memory/             # MEMORY.md, AGENTS.md, opencode.jsonc templates
├── versions.env            # pinned versions, package lists, upstream repos
├── tests/                  # smoke, launcher-memory, maintenance, resume,
│                           #   release, adapter
└── .github/workflows/ci.yml
```

`install.sh` is deliberately small (~135 lines): check `curl` → download the
release tarball → verify the sha256 → extract to `~/.cache/codemux/src/current`
(atomic swap) → `exec bin/codemux install`. When no release exists it falls back
to the `main` branch through `codeload` (no sha).

---

## 8. Modules & detection (the core mechanism)

Execution order = the table below. Each module file is `lib/modules/<name>.sh`
with `m_<name>_probe` / `m_<name>_apply` / `m_<name>_verify`. `probe` decides
SKIP vs APPLY. `install` runs `deps → mirror → storage → toolset → glibc → v1 →
v2 → launcher → dotfiles → memory → self` (10 rows for V1-only or V2-only, 11 for
both); `preflight` runs before the rows and `update-cache` is checked by `check`
only.

| # | Module | Detection (probe) | Action when missing |
|---|---|---|---|
| — | `preflight` | Android, `aarch64`, uid ≠ 0, disk ≥ 3 GB, bash present | refuse with a clear message (exit 2) |
| 1 | `deps` | `curl tar sha256sum gzip unzip awk sed jq` | `pkg install` the missing ones, heal a broken `curl` |
| 2 | `mirror` | active `sources.list` + `apt-get update` responds | pick/repair the apt mirror (official fallback) |
| 3 | `storage` | `~/storage` exists and `/sdcard` readable | `termux-setup-storage` (interactive, §11) |
| 4 | `toolset` | `dpkg-query -W` for each package in `versions.env` | `pkg install -y` what is missing (+ optional `tesseract chromium`, WARN only) |
| 5 | `glibc` | `$PREFIX/glibc/lib/ld-linux-aarch64.so.1` + `libc.so.6` | `pkg install glibc-repo glibc termux-exec-glibc`, heal `libcurl` |
| 6 | `v1` | payload at `$PREFIX/share/opencode/opencode.real` + launcher + `apt-mark hold` | run the `opencode-termux` installer (adapter) |
| 7 | `v2` | payload at `$PREFIX/share/opencode-v2/opencode.real` + `lib/compat` shim + launcher | run the `opencode-termux-v2` installer (adapter) |
| 8 | `launcher` | `~/.bashrc` has the `# codemux:launcher begin` block with `version 2` and passes `bash -n` | back up, insert the block from `templates/bashrc-block.sh` |
| 9 | `dotfiles` | `~/.bash_profile`, `~/.hushlogin` | write/merge, never overwrite other content |
| 10 | `memory` | plugins (`memory.js`, `session-title.js`, `update-notice.js`), tools (`bin/session-digest.py`, `bin/kuota`), `MEMORY.md`/`RECENT.md`, `instructions` entries | install the mechanism + templates (merge `opencode.jsonc`, never overwrite), symlink `kuota` into `$PREFIX/bin` |
| 11 | `self` | `codemux` on `PATH` points at this checkout/install | symlink into `$PREFIX/bin` |
| 12 | `update-cache` | `~/.config/codemux/update-cache.tsv` younger than 24 h | refresh the cache (`check` reports its age) |

Per-module contract:

```bash
m_<name>_probe()   # sets PROBE=OK|WARN|MISS|FAIL|SKIP + NOTE
m_<name>_apply()   # performs the action, logs every command
m_<name>_verify()  # defaults to probe; 0 = actually working
```

Uniform output: `[3/10] storage      ready   Termux storage present`,
`[6/10] v1           apply   (1.19.3 → 1.19.5)`, `… ok`, `… FAIL (reason)`.
`check` uses `OK / WARN / MISS / FAIL / SKIP` with a summary line and exit codes
(§6). `SKIP` means "not selected" (a component the user did not install), not a
problem.

---

## 9. State & resume

`~/.config/codemux/state.tsv` (append-only, human readable):

```
# ts             module       status  version  note
2026-11-11T01:59 deps         SKIP    -        curl tar sha256sum gzip unzip awk sed jq
2026-11-11T02:03 toolset      DONE    -        20/20 required packages installed
2026-11-11T02:05 v2           DONE    2.2.7    compat shim installed
```

`~/.config/codemux/run.tsv` holds the plan of the current run — one row per
module with `status pid boot started finished note`:

```
# module	status	pid	boot	started	finished	note
deps	DONE	31976	be656e9e-…	08:00:19	08:03:08	curl tar sha256sum …
v1	RUNNING	32011	be656e9e-…	08:03:09	-	adapter pid 32011
```

`codemux status` shows: which step out of how many, the active pid, the last 10
log lines. A `RUNNING` row whose pid is gone (or whose `boot` id differs → the
device rebooted) is reported as **interrupted**, never as finished.

Also in `~/.config/codemux/`: `lock` (pid + boot id, prevents parallel runs),
`logs/<timestamp>.log`, `backup/<ts>-<tag>/`, `components`, `update-cache.tsv`.

---

## 10. Installer flow (phases)

```
[bootstrap]  install.sh: check bash+curl → download the release tarball → sha256
             → extract to ~/.cache/codemux/src/current → exec bin/codemux install
     │
[choice]     --only / CODEMUX_COMPONENTS / saved ~/.config/codemux/components,
             otherwise the arrow-key picker (TTY only); the answer is saved
     │
[preflight]  Android/aarch64/uid/disk → failure = stop (exit 2)
     │
[plan]       probe every selected module → print the plan (ready / INSTALL) →
             nothing to do = exit 0 · --dry-run = stop here
     │
[execute]    modules in order; per module: apply (spinner to stderr) → verify →
             record in run.tsv + state.tsv. One failing module ≠ total failure:
             it is collected, except `deps`/`glibc` which stop the run.
     │
[done]       summary (ready/skipped/failed) + the log path; failure prints
             `codemux status` / `install` (resume) / `repair` hints
```

Full log: `~/.config/codemux/logs/<timestamp>.log` (mode 600).

---

## 11. `termux-setup-storage` (special, interactive)

The Android permission dialog cannot be fully automated. Mechanism:

1. `probe`: when `~/storage` exists and `/sdcard` is readable → `OK` (SKIP).
2. Otherwise: run `termux-setup-storage` with a 45 second timeout and **wait**;
   the dialog stays on screen until the user taps Allow.
3. On failure/timeout: record `WARN` ("storage permission not granted yet — run
   termux-setup-storage anytime"), continue with the other modules (not fatal).
4. `--skip storage` skips this step entirely (the `--only`/component choice never
   affects it).

---

## 12. Upgrade & maintenance

| Command | Contents |
|---|---|
| `codemux upgrade` | `pkg update && pkg upgrade -y` (opencode held) → V1/V2 adapters **only for the payloads that are installed** (detected via `$PREFIX/share/opencode{,-v2}/opencode.real`) → re-sync the launcher block → refresh the memory mechanism (plugins, digest, `kuota`; `MEMORY.md` untouched) → refresh the update cache |
| `codemux update-check` | compare local versions with the upstream releases (24 h cache), `--json`, `--quiet` |
| `codemux self-update` | download the latest `codemux` release, verify sha256, back up `bin lib templates VERSION versions.env install.sh` to `backup/<ts>-selfupdate/`, swap, then run `--version`; failure = automatic restore |
| `codemux repair` | drop a stale lock, mark dead `RUNNING` steps, `dpkg --configure -a` + `apt-get -f install` when apt was interrupted, reinstall the V2 compat shim, refresh the launcher block |
| `codemux uninstall` | move the V1/V2 payloads to `backup/<ts>-uninstall/`, remove the launcher/memory blocks (verified with `bash -n`, restored if broken); `--purge` also deletes `~/.config/codemux`. Never touches `MEMORY.md`, projects, or backups |

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
| `~/.config/opencode/bin/session-digest.py` | producer of `RECENT.md` (sessions + open items) | created when missing; `codemux upgrade` replaces a changed file (old copy backed up) |
| `~/.config/opencode/bin/kuota` | quota estimator (§12C), symlinked to `$PREFIX/bin/kuota` | created when missing; replaced by `codemux upgrade` when it changed |
| `~/.config/opencode/plugins/memory.js` | `memory_save` tool + compaction hook + digest refresh | created when missing; replaced by `codemux upgrade` when it changed |
| `~/.config/opencode/plugins/update-notice.js` | injects the codemux update notice into the session context | same as above |
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

### Open items (what is still unfinished)

A summary of finished work is not enough: a new session must know what was left
hanging. The digest reads the **last message** of every session and adds an
`## Open items` block above the session list:

| Signal | Example output |
|---|---|
| the last message is the user's (no reply yet) | `[13 Nov · V2] waiting for a reply to: "and then?"` |
| an explicit next step (`Next:`, `Selanjutnya:`, `## Next Move`, `TODO`, …) | `[13 Nov · V2] next: run the installer on the device` |
| the final reply ends with a question | `[13 Nov · V2] asked: "Shall I continue now?"` |

Limits: at most 6 items, 150 characters each, 1,100 bytes total, deduplicated.
Only the final assistant message of each session is scanned, so the cost stays
tiny (one row per session).

### Important rules

1. **Hard limit for `MEMORY.md` = 24,000 bytes.** The plugin refuses to write past
   it (proven in production). `check`/`doctor` show the size and warn above 90% of
   the limit; trimming is done by the model/human (codemux never deletes memory).
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
6. **`--skip memory`** skips the whole module (for those who want a clean config).

### Related commands

```
codemux memory              # status + size of MEMORY.md/RECENT.md (read-only)
codemux memory --json       # for scripts
```

No `memory digest` / `memory prune` subcommand exists: the digest runs
automatically through the `~/.bashrc` wrapper and the memory plugin, and trimming
is done by the model (or by hand) when `check`/`doctor` reports the 90% warning.

---

## 12B. Update check & cache (notify → `codemux upgrade`)

Problem: Termux has no cron; V1/V2/codemux versions go stale quickly and nothing
notifies anyone. Solution: a light check when the menu opens, a one-line notice,
and the update itself stays an explicit command.

### Sources being checked

| Component | How the latest version is fetched | Quota cost |
|---|---|---|
| `codemux` | redirect `https://github.com/kusnuzon/codemux/releases/latest` → tag | 0 (no API) |
| `opencode-termux` (V1) | redirect `…/opencode-termux/releases/latest` | 0 |
| `opencode-termux-v2` (V2) | redirect `…/opencode-termux-v2/releases/latest` | 0 |
| apt packages | `apt list --upgradable` (uses the cache) | 0 |
| local versions | `dpkg-query`, `$PREFIX/share/opencode-v2/VERSION`, `codemux --version` | 0 |

The GitHub API is only used as a **fallback** (quota 60/hour without a token).

### Flow (as implemented)

```
menu opens
   └─ cache < 6 hours old? ── yes ──> show the notice line (instant)
                │ no
                └─ `codemux update-check --quiet` in the background
                   (6 s timeout, output to the cache, never blocks the prompt)
                        └─ cache updated → the notice appears next time

a newer version / apt packages exist:
   update available: codemux 0.7.2 · opencode-v2 2.2.7
   run: codemux upgrade
   └─ the menu only informs; the update itself is a normal command
      (`codemux upgrade` → plan → confirmation → install → verify), so a TUI
      session is never interrupted mid-flight
```

### Cache & retry rules (`~/.config/codemux/update-cache.tsv`)

| Situation | Behaviour |
|---|---|
| Cache younger than 24 h | used as-is, no network |
| Cache older | background refresh, at most once per 6 h from the menu |
| Upstream check failed for a component | row marked `na`, retried at most once per hour |
| Cached "local" version ≠ installed version | row hidden (stale) and the cache is forced to re-check |
| Never installed yet | rows follow the saved component choice |

There is no `config` file: behaviour is fixed (notify + manual `codemux upgrade`)
and the knobs are environment variables (`CODEMUX_HOME`) and CLI options.

### The notice inside a session (not only in the menu)

A long session never returns to the menu, so the same cache is also read by
`plugins/update-notice.js`:

| Version | Hook | Effect |
|---|---|---|
| V2 | `ctx.session.hook("context", …)` | runs before every model call (agent loop) |
| V1 | `experimental.chat.system.transform` | same job through the V1 hook table |

- The cache is re-read at most once a minute and ignored when older than 48 h.
- The text is one line plus an instruction: mention it once, then say
  `codemux upgrade` is available — nothing downloads by itself.
- Missing file, unreadable TSV or any other error is swallowed (no notice, no
  crash, startup unaffected).

### Safety & behaviour

- The menu only **notifies**; nothing is downloaded or replaced without running
  `codemux upgrade` (or `upgrade --yes`).
- Every download is sha256-verified; the old payload is backed up
  (`~/.config/codemux/backup/<ts>-<tag>/`) and restored when verification fails.
- Offline/timeout → fails **silently**, the cache keeps the previous "latest"
  value, startup is unaffected.
- `opencode` stays `apt-mark hold` so apt does not overwrite the V1 payload.
- API calls to `api.github.com` use a token when available
  (`CODEMUX_GITHUB_TOKEN` > `GITHUB_TOKEN` > `GH_TOKEN` > `gh auth token`) to avoid
  the 60 requests/hour anonymous limit.

### Related commands

```
codemux update-check            # check now, print the version table
codemux update-check --json     # for scripts
codemux upgrade                 # show the summary → confirm → install
codemux upgrade --yes           # no questions
codemux upgrade --only v2       # a single component (apt,v1,v2,launcher)
```

Implementation: `lib/update.sh` (`releases/latest` redirect, cache
`~/.config/codemux/update-cache.tsv`, `CODEMUX_FAKE_TAG_*` /
`CODEMUX_FAKE_LOCAL_*` overrides for tests, token-aware API fallback),
`lib/maintenance.sh` (doctor, upgrade, uninstall), the update notice in the
launcher block (`_oc_update_notice`, at most one background check per 6 hours),
`tests/maintenance.sh` and the menu tests in `tests/launcher-memory.sh`.

---

## 12C. Free-model quota (`kuota`)

OpenCode exposes **no** usage endpoint for the free models (every `/usage` call
returns 404, and a direct API request answers `429 FreeUsageLimitError`). What is
available locally is the number of assistant messages — one answer = one request.
The `memory` module installs `~/.config/opencode/bin/kuota` (+ symlink in
`$PREFIX/bin`) which counts them per UTC day, because the free quota resets at
`00:00 UTC` = `07:00 WIB`.

| Command | Output |
|---|---|
| `kuota` | today: used / limit, bar, remaining, warning threshold, per-model counts |
| `kuota --week` | the last 7 days (`--days N` for another window) + average |
| `kuota --warn` | one line, printed only at/above the threshold (used by the menu) |
| `kuota --json` | `date`, `limit`, `used`, `remaining`, `percent`, `warn`, `by_model` |
| `kuota --limit N` / `--warn-at N` | daily limit (default 200) and threshold (default 80 %) |

Rules:

- Data comes from both databases (V2 `session_message`, V1 `message`); a missing
  database counts as 0. Reads are `mode=ro`, ~0.1 s on a phone.
- The menu prints `⚠ kuota 161/200 (81%) · run: kuota` in the same slot as the
  update notice, only when `kuota` exists and the threshold is reached.
- Exit code `0` below the limit, `1` at/above it (useful in scripts).
- The limit is an estimate of the free-tier daily cap, not a server-side truth:
  `KUOTA_LIMIT` exists so a device with a different allowance stays accurate.

---

## 13. Security & reliability

- Every download is `sha256`-verified (release tarball, self-update; payload
  checksums come from the upstream installer / npm registry sha512).
- No layered `curl | bash`: the bootstrap downloads a tarball and only falls back
  to `codeload` for `main` (documented in the output as "no sha256").
- No token is ever written by codemux; `gh` login is the user's own business.
  When a token *is* already available it is used only for GitHub API headers.
- `set -Eeuo pipefail` in `bin/codemux`; CI runs `shellcheck -S warning`,
  `bash -n`, `check --json` validation and `tests/smoke.sh` on every push.
- No `rm -rf` on a path containing `$HOME`, except the internal
  `~/.cache/codemux/src` path.
- Mode of new config files: `600` for state/log; downloads go through
  `.part` + checksum + atomic `mv`.
- Nothing is downloaded or replaced while an opencode session runs: the menu only
  notifies, and `upgrade`/`self-update` are explicit commands.

---

## 14. Non-functional targets

| Metric | Target |
|---|---|
| S3 time (everything present) | < 60 seconds |
| S1 time (bare → ready) | 10–25 minutes on 4G (downloads ±1.2–1.5 GB) |
| Minimum disk space checked | 3 GB free |
| Repo size (no binaries) | < 300 KB |
| Idempotency | run twice → the second run changes 0 files (checked with `find -newer`) |
| Network failure | clear message; `codemux install` (resume) does not re-download what is present |
| Session digest (8 sessions, V1+V2) | < 2 seconds, never blocks the prompt |
| Update check (background) | < 6 seconds, never blocks the menu |
| Update-check cache | 1× per 24 hours per component (menu retries at most 1×/6 h) |
| Tests | smoke 44 · launcher-memory 38 · maintenance 19 · resume 16 · release 7 · adapter 12 |

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
   When the menu opens (cache stale), Then `update available: …` + `run: codemux
   upgrade` appears; When running `codemux upgrade`, Then only installed payloads
   are updated + sha256 of every download matches + the version goes up. Given
   offline, Then the update check fails silently (startup is unaffected).
9. **S9 (component choice)** Given no saved choice and a TTY, When `install`,
   Then the arrow-key picker appears; ↑/↓ + Enter, `1`/`2`/`3` and `q` all behave
   as documented; `q` changes nothing and writes no `components` file. Given
   `--only v1` (or a non-TTY run), Then the choice is used without asking and the
   missing component stays untouched.
10. **S10 (menu install)** Given only one component is installed, When the menu
    opens, Then both rows are shown and the missing one says
    `not installed · Enter to install`; choosing it asks `Install it now? [y/N]`,
    `n` prints `not installed — nothing changed`, and `y` runs
    `codemux install --only <component>` and then starts it.
11. **S11 (quota)** Given `kuota` is installed and today's usage is below the
    threshold, When the menu opens, Then no quota line appears; Given usage is at
    or above 80 %, Then `⚠ kuota N/200 (P%) · run: kuota` is printed. Given
    `kuota` is not installed, Then the menu prints nothing about the quota.
12. **S12 (update notice in a session)** Given the codemux cache holds a row with
    status `update`, When a model call is prepared, Then the system instructions
    contain a single `[codemux] update available: …` line; Given the cache is
    older than 48 h, empty, or absent, Then nothing is injected and the session
    is unaffected. V1 uses `experimental.chat.system.transform`, V2 the
    `context` session hook — verified in both plugin entry points.

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
| `MEMORY.md` > 24,000 bytes (hard plugin limit, has happened) | `memory_save` fails | `check`/`doctor` warn at 90% and the model trims; codemux never deletes memory |
| `RECENT.md` grows | wasted context | the digest is limited to 8 sessions, each truncated to ~600 characters |
| False update notice / local version newer | pointless download | compare semver; `update-check --json` shows the version source |
| GitHub API limit (60/hour) | check fails | use the `releases/latest` redirect (no quota), API only as fallback |
| An update is offered while an opencode session runs | disruptive | only offered from the menu/CLI, never while the TUI is active |

---

## 17. Milestones

| # | Contents | Status |
|---|---|---|
| M1 | skeleton: `bin`, `lib/common`, `state`, `preflight`, `check` | ✅ `codemux check` works |
| M2 | env modules: deps, mirror, storage, toolset, glibc (+ resume/atomic §20) | ✅ Termux "tool-ready" |
| M3 | V1 & V2 adapters (call the existing repos) | ✅ `opencode`, `opencode-v2` work |
| M4 | launcher: banner + arrow menu, dotfiles, **V1+V2 memory** (§12A) | ✅ startup menu + memory |
| M5 | `doctor`, `upgrade`, `repair`, `uninstall`, **`update-check`** (§12B) | ✅ maintenance |
| M6 | CI: shellcheck, `bash -n`, `check --json`, smoke, release tarball | ✅ 1.0 ready |
| M7 | component picker (↑/↓), upgrade limited to installed payloads, menu install confirmation | ✅ **0.7.3** (§6A, §12, S9/S10) |
| M8 | update notice **inside** an opencode session (plugin reading the cache), `memory prune --dry-run`, optional `--lang id` | 🟡 notice ✅ **0.7.4** · prune & `--lang id` still planned |
| M9 | `kuota` (daily quota estimate + menu warning) and open items in `RECENT.md` | ✅ **0.7.4** (§12C, §12A) |

Release history: `0.6.4` update-cache fix · `0.6.5` `kuota` menu line · `0.6.6`
early dependency install · `0.7.0` component choice · `0.7.1` progress spinner ·
`0.7.2` token-authenticated GitHub downloads · `0.7.3` picker + installed-only
upgrade + menu install flow · `0.7.4` in-session update notice, `kuota`, open
items in `RECENT.md`, memory mechanism refresh on `upgrade`.

---

## 18. Decisions (decided — kept as a record)

| # | Question | Decision |
|---|---|---|
| D1 | Repo name | **`codemux`** (chosen) |
| D2 | Duplicate the V1/V2 logic? | **Adapter** — call the `opencode-termux` & `opencode-termux-v2` repos (chosen) |
| D3 | Include personal memory? | Templates only, never overwriting (**approved**) |
| D4 | Default apt mirror | current active mirror, repaired when broken, official fallback (**approved**) |
| D5 | Does "from scratch" Termux include Chromium/Playwright? | **Optional extras** (`tesseract chromium` via `x11-repo`, WARN on failure); skip everything with `--skip toolset` |
| D6 | Output language | English (**approved**; `--lang id` is M8) |
| D7 | Memory feature installed by default? | **Yes, ON by default** (`--skip memory` to skip) |
| D8 | Update behaviour | **Notify only** (`update available … run: codemux upgrade`); nothing downloads automatically |
| D9 | Update-check interval | **24 hours** cache, menu retries at most every 6 hours, `na` rows every hour |
| D10 | Update notice inside an opencode session | Not implemented (M8) |
| D11 | Component default | **Both** (`v1 v2`) when nothing is saved; the picker remembers the answer |
| D12 | Upgrade scope | **Only installed payloads** + apt + launcher; `--only` overrides |
| D13 | Update notice placement | Both: one line in the startup menu **and** one line in the session context through the plugin (0.7.4) |
| D14 | Quota source | Local databases (one assistant message = one request), 200/day default, `KUOTA_LIMIT` overrides — no server-side endpoint exists |

---

## 19. One command

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh | bash
```

Add `--yes` for a fully non-interactive run (keeps the saved/default components),
`--only v1|v2|both` to decide up front, or `--dry-run` to see the plan.

Release assets: `codemux.tar.gz` (+ `codemux.tar.gz.sha256`). The bootstrap
downloads both, verifies the sha256, extracts to `~/.cache/codemux/src/current`
(atomic: `current.new` → swap), then `exec bin/codemux install`. When no release
exists yet → `codeload …/refs/heads/main` fallback without sha.

Lightweight variant (skip the apt toolset — e.g. on a tiny disk):

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh \
  | bash -s -- --yes --skip toolset
```

Component-scoped variants (nothing else is touched):

```bash
… | bash -s -- --only v1     # V1 only   (10 modules)
… | bash -s -- --only v2     # V2 only   (10 modules)
… | bash -s -- --only both   # V1 + V2   (11 modules, default)
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

`state.tsv` (history) + `run.tsv` (current run):

```
# module    status    pid    boot        started   finished  note
deps        DONE      31976  be656e9e-…  08:00:19  08:03:08  curl tar sha256sum …
toolset     RUNNING   32011  be656e9e-…  08:03:09  -         apt pid 32011
```

`codemux status` shows: which step out of how many, the active pid, the last 10
log lines. If the process is dead, the row stays `RUNNING` but the pid is gone →
the next `install` marks it `INTERRUPTED` and continues from that step.

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

1. `codemux status` shows the interrupted step and the active pid.
2. `codemux install` with no arguments = **automatic resume** (it marks dead
   `RUNNING` rows `INTERRUPTED` and re-probes every module); `--fresh` starts over.
3. One-command emergency repair: `codemux repair` (dpkg configure, stale lock,
   missing shim, dead `RUNNING` rows).

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
