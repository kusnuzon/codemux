# codemux

Termux installer & maintainer: OpenCode **V1 + V2**, a startup menu/banner,
cross-session memory, a base toolset, and update checks — one command,
idempotent (safe to repeat), non-destructive.

> **Status: M6 (release 1.0).** Every PRD command works: `check`, `install`
> (resume-safe, 10–11 modules depending on the component choice), `status`,
> `repair`, `memory`, `update-check`, `doctor`, `upgrade`, `uninstall`,
> `self-update`, `version`, `help`. The full design lives in [PRD.md](PRD.md).

## One-command install

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh | bash
```

`install.sh` is small: check prerequisites → download the release tarball +
`sha256` → extract to `~/.cache/codemux/src/current` → run `codemux install`.
When no release exists yet it falls back to the `main` branch (no sha). Options
are passed through, e.g. `| bash -s -- --dry-run` or
`| bash -s -- --skip toolset`.

## Choose what to install (V1 only / V2 only / both)

```bash
# interactive: arrow-key picker (↑/↓ + Enter, or 1/2/3) — V1 / V2 / both
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh | bash

# non-interactive / already decided
… | bash -s -- --only v1     # OpenCode V1 only (V2 is never touched)
… | bash -s -- --only v2     # OpenCode V2 only
… | bash -s -- --only both   # V1 + V2 (default)
```

- `--components v1|v2|both` and `CODEMUX_COMPONENTS=v1` are aliases.
- The choice is saved in `~/.config/codemux/components` and reused by
  `install`, `check`, `upgrade` and `update-check`. Override it any time with
  `--only`.
- Every shared dependency (base tools, apt toolset, glibc runtime, memory files,
  launcher) is installed **first and in full**, whatever the choice is — a
  fresh Termux ends up complete either way.
- `check` shows an unselected component as `SKIP` (not as missing). The startup
  menu always lists both components: one that is not installed is marked
  "not installed", and choosing it asks for confirmation before
  `codemux install --only <component>` runs.

### Progress, so it never looks frozen

Every long step prints one line that keeps updating — a spinner, the step name,
the elapsed seconds, and (while downloading) the size so far:

```
[4/11] toolset    | installing (37s)
[6/11] v1         / waiting for the upstream V1 installer (1m 12s)
  ↓ downloading memory.js (7 KB)
```

`apt` installs, the V1/V2 adapters and every download are covered, both in
`codemux install`/`upgrade` and in the `curl … | bash` bootstrap. Set
`CODEMUX_PROGRESS=0` (or `CODEMUX_NO_PROGRESS=1`) to turn it off; when the
output is not a terminal (logs, CI, `| tee`) it is already silent.

## Usage (from the repo)

```bash
git clone https://github.com/kusnuzon/codemux
bash codemux/bin/codemux check              # status of each module, changes nothing
bash codemux/bin/codemux install --dry-run  # install plan, changes nothing
bash codemux/bin/codemux install            # install / continue what was interrupted
bash codemux/bin/codemux install --only v1  # V1 only (or v2 / both)
bash codemux/bin/codemux status             # progress, lock, last log
bash codemux/bin/codemux repair             # clean up leftovers from a killed process
bash codemux/bin/codemux check --json       # for scripts
bash codemux/bin/codemux memory             # cross-session memory status (read-only)
bash codemux/bin/codemux update-check       # compare local versions with upstream releases
bash codemux/bin/codemux doctor             # full diagnosis + repair suggestions
bash codemux/bin/codemux upgrade --dry-run  # upgrade plan (apt + selected V1/V2 + launcher)
bash codemux/bin/codemux uninstall --dry-run  # payload removal plan (memory stays)
```

Once installed (M2+), the command becomes `codemux` in `$PREFIX/bin`.

## What `codemux check` verifies

| Module | Contents |
|---|---|
| `preflight` | Android, aarch64, not root, disk ≥ 3 GB |
| `deps` | curl, tar, sha256sum, gzip, unzip, awk, sed, jq (+ curl repaired when broken) |
| `mirror` | active apt repo (warns when the mirror is slow) |
| `storage` | `termux-setup-storage` has run |
| `toolset` | 20 required apt packages (git, gh, python, nodejs, sqlite, …) + optional `tesseract chromium` (x11-repo) |
| `glibc` | loader + libc.so.6 for the OpenCode payloads |
| `opencode-v1` | V1 payload + `apt-mark hold` (`SKIP` when V1 was not selected) |
| `opencode-v2` | V2 payload + the `lib/compat` shim (`SKIP` when V2 was not selected) |
| `launcher` | banner/menu block in `~/.bashrc` (detects an old block) |
| `dotfiles` | `.bash_profile`, `.hushlogin` |
| `memory` | `MEMORY.md` (+ 24,000 byte limit), `RECENT.md`, memory + session-title plugins, instructions |
| `update-cache` | age of the upstream update-check cache |

`install` runs the modules in order: `deps -> mirror -> storage -> toolset ->
glibc -> v1 -> v2 -> launcher -> dotfiles -> memory`. `v1`/`v2` are included
only when selected (`--only v1`, `--only v2`, `--only both`); everything else
always runs. Use `--dry-run` to see the exact plan (10 or 11 rows).

All dependencies are installed up front (`deps` + `toolset`) so a fresh Termux
does not fail halfway. Two traps handled automatically:

- `apt-get install` without `update` → `E: Unable to locate package` (the
  package list is refreshed and the install retried once);
- the `glibc` package overwrites `libcurl` → `curl: cannot locate symbol
  "SSL_set_quic_tls_early_data_enabled"`. The `glibc` module reinstalls
  `curl libcurl openssl`, and every download has a `wget`/`python` fallback.

### Launcher & memory (M4)

- **launcher**: writes a marked `# codemux:launcher begin … end` block into
  `~/.bashrc` (banner, arrow menu, and the `menu`, `version`, `doctor`,
  `codemux`, `keluar`/`exit` commands). The menu always shows four rows
  (V1, V2, shell, quit): a component that is missing stays visible as
  "not installed" and choosing it asks "Install it now? [y/N]" before running
  `codemux install --only <component>`. Only the option rows are redrawn on
  arrow keys, so the screen does not flicker. An old block without markers is
  **adopted**: it is cut only when its structure is recognised (an
  `_oc_launcher` call, last line `fi`); the rest of `~/.bashrc` is untouched.
  `.bashrc` is backed up, the new block is tested with `bash -n`, and on failure
  the backup is restored.
- **dotfiles**: `.bash_profile` (loads `.bashrc`) and `.hushlogin`.
- **memory**: `MEMORY.md`, `AGENTS.md`, `RECENT.md`, `plugins/memory.js`,
  `plugins/session-title.js`, `bin/session-digest.py`, and the `instructions`
  entries in `opencode.jsonc`.
  **Existing memory files are never overwritten**; `instructions` is only
  appended when an entry is missing; the `_oc_refresh_digest` wrapper goes into
  a `# codemux:memory begin … end` block (only when absent). The plugin/digest
  mechanism is downloaded from the upstream repo, not copied into this repo.

## OpenCode V1 & V2 adapters

codemux does not copy OpenCode code. For `v1` and `v2` it:

1. downloads `install.sh` from the upstream repo through the **GitHub API**
   (`Accept: application/vnd.github.raw`) — not `raw.githubusercontent.com`,
   which often serves a stale cache on mobile networks;
2. rejects downloads that are not shell scripts (e.g. an error/rate-limit page);
3. records the script's sha256, runs it **detached from the shell** (`setsid`),
   then verifies the result: payload, launcher, `apt-mark hold` (V1), and the
   `lib/compat` shim (V2);
4. on failure the step is recorded as `FAILED` and `codemux install` can be
   repeated — there is never a half-finished state.

## Maintenance (M5)

- **`update-check`** — compares local versions (codemux, V1, V2, apt packages)
  with upstream releases through the `/releases/latest` redirect (no API
  quota). The result is stored in `~/.config/codemux/update-cache.tsv` (24
  hours); the startup menu reads it and runs a background check when the cache
  is stale. If the network fails briefly, the "latest" value from the old cache
  is reused (not overwritten with `na`), and the menu retries at most once an
  hour later.
- **`doctor`** — `check` + additional checks: `bash -n ~/.bashrc`, the digest
  wrapper, `MEMORY.md` size, bionic `LD_PRELOAD`, free disk, lock, cache age.
- **`upgrade`** — `apt-get update && apt-get upgrade` (opencode stays held),
  V1/V2 payloads through the upstream `upgrade.sh` (fallback: the adapter), then
  the launcher block + digest wrapper are re-synced. `--only apt,v1,v2,launcher`,
  `--dry-run`, `--yes`; uses the same lock as `install`.
- **`uninstall`** — moves the V1/V2 payloads to
  `~/.config/codemux/backup/<ts>-uninstall/`, removes the
  `# codemux:launcher` / `# codemux:memory` blocks from `~/.bashrc` (tested with
  `bash -n`, on failure left untouched). It does **not** delete `MEMORY.md`,
  `AGENTS.md`, projects, or backups. `--purge` deletes `~/.config/codemux`.

`check` exit codes: `0` everything ready · `1` something missing · `2`
prerequisite failed.
`install` exit codes: `0` finished · `1` some step failed · `2` prerequisite
failed · `3` another install is running.

## Surviving being killed midway

`install` never relies on "one clean run":

- the `RUNNING` state is written **before** the step; a kill shows exactly where
  it stopped;
- downloads/file writes use a temp file + `mv` (atomic), plus sha256;
- long processes (apt, big downloads) run `setsid` + pidfile + log, so a dying
  shell or opencode does **not** kill them;
- the lock holds a pid + boot-id: a stale lock (dead process / device reboot) is
  dropped automatically;
- `codemux install` with no arguments = **resume**, not start over;
- `codemux repair` fixes stale locks, half-finished dpkg, and a missing V2 shim.

Tested by `tests/resume.sh` (16 scenarios: SIGKILL of the parent, SIGKILL of
parent+child, apt failure, active lock, leftover temp files).

## Layout

```
bin/codemux        entry point
lib/common.sh      colors, logging, utils, detection
lib/state.sh       state TSV, run.tsv (progress), pid+boot-id lock, log
lib/exec.sh        detached spawn, wait, atomic write, backup
lib/adapter.sh     download + validate the upstream install.sh
lib/check.sh       check runner (read-only)
lib/install.sh     install (resume) + status
lib/repair.sh      repair (stale lock, dpkg, V2 shim)
lib/update.sh      update-check + 24h cache
lib/maintenance.sh doctor, upgrade, uninstall
lib/selfupdate.sh  self-update (tarball + sha256, backup, code swap)
install.sh         one-command bootstrap (download release → install)
lib/modules/*.sh   probe + apply + verify per module
tests/smoke.sh     quick test (syntax, help, json, shellcheck)
tests/resume.sh    16 "kill it midway" scenarios
tests/adapter.sh   12 adapter scenarios for V1/V2 (fake upstream)
tests/launcher-memory.sh  29 launcher/dotfiles/memory scenarios (sandbox HOME)
tests/maintenance.sh      14 update-check/doctor/upgrade/uninstall scenarios
tests/release.sh          7 bootstrap + self-update scenarios
templates/         bashrc block + memory templates + opencode.jsonc editor
versions.env       pinned versions + package lists
PRD.md             full design (goals, mechanisms, milestones)
```

## Roadmap

- **M1** skeleton + `check` ✅
- **M2** `install` (deps, mirror, storage, toolset, glibc) + resume ✅
- **M3** OpenCode V1 + V2 adapters [done]
- **M4** launcher + cross-session memory ✅
- **M5** `doctor`, `upgrade`, `repair`, `uninstall`, update checks ✅
- **M6** CI + release tarball + one-command installer ✅

## Notes

- This repo contains **mechanism only**; personal memory contents are never pushed.
- Requires Termux aarch64 (Android), not root.
- If the repo is cloned to `/storage/emulated/0` (FUSE), files there **cannot be
  executed directly** (`Permission denied`) → run `bash bin/codemux …`.
  After installing to `$PREFIX/bin`, `codemux` runs normally.
- `raw.githubusercontent.com` can serve a stale cache on mobile networks —
  release downloads use a tarball + sha256 verification.
- `codemux self-update` replaces `bin/`, `lib/`, `templates/`, `VERSION`,
  `versions.env`; the old code is backed up to
  `~/.config/codemux/backup/<ts>-selfupdate/`. Memory, projects, and state are
  untouched.
- `codemux upgrade` refreshes the `update-check` cache when it finishes, and the
  startup menu hides cache rows whose local version no longer matches the
  installed payload — so "update available" does not reappear for a version that
  was just installed.
