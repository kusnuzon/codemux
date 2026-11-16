# 🚀 codemux — Termux Setup in One Command

Installs and maintains **OpenCode V2 (default) or V1** on Termux: startup menu, cross-session
memory, base toolset, Android storage, and update checks. Idempotent — safe to
run again and again.

> 📜 Full design: [PRD.md](PRD.md)

## ✨ What you get

- 🤖 **OpenCode V2 by default, V1 optional** — you choose, nothing extra is pulled in
- 🎛️ **Startup menu** — arrow keys, opens the component you pick
- 🧠 **Cross-session memory** — `MEMORY.md` + `RECENT.md` (with the open items)
  loaded every session
- 🧰 **Base toolset** — git, gh, python, sqlite, jq, htop, ...
- 📂 **Android storage** — runs `termux-setup-storage` when it is still missing
- 🔄 **Update check** — sees new codemux/V1/V2/apt releases before you ask, and
  reminds you once inside a session
- 📊 **Progress bar** — every install step and every download shows a percentage
  (bar + bytes/total), so a slow mobile connection never looks frozen
- ⛽ **`quota`** — estimates the remaining free-model quota from the local DBs
- 🛡️ **Resume-safe** — killed midway? run it again, it continues

## 📦 Prerequisites

Termux on Android, **aarch64**, **not root**. That's it — dependencies are
installed automatically. Disk: V2-only is the smallest footprint; adding V1
also pulls `clang`/LLVM (~500 MB) because its package compiles the wrapper.

## ⚡ 1-Click Install

Copy-paste one line into Termux and press Enter:

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh | bash
```

The bootstrap downloads the latest release tarball, verifies its `sha256`,
extracts it to `~/.cache/codemux/src/current`, then runs `codemux install`.

## 🎛️ Pick the components

First install shows an arrow-key picker:

```
Which OpenCode should be installed?
  ❯ 1) OpenCode V2 only — new, separate DB (default)
    2) OpenCode V1 only — stable, legacy DB
    3) Both — V1 + V2 (more disk)
```

- ↑/↓ (or `j`/`k`) move · `Enter` run · `1`-`3` pick directly · `q` cancel
- The answer is saved in `~/.config/codemux/components` and reused later
- Skipping the picker (CI, `curl | bash`): saved choice, default `v2`

Non-interactive:

```bash
… | bash -s -- --only v2     # V2 only (default, least disk)
… | bash -s -- --only v1     # V1 only (V2 is never touched)
… | bash -s -- --only both   # V1 + V2 (more disk)
```

V1 is installed from the **TermuxVoid** APT repo: its `opencode` package downloads
the official payload, verifies the sha256, and compiles the glibc wrapper that is
known to work on Termux. That pulls `clang`/LLVM (~500 MB) as a build dependency.

## ⌨️ Startup menu

Every new Termux session opens a menu — nothing is hidden:

```
❯ 1 OpenCode V1            1.19.5 · stable · legacy DB
  2 OpenCode V2            not installed · Enter to install
  3 Free-pi (Pi)           0.6.22 · free-pi agent
  4 Free-pi (Pi) · tmux    0.6.22 · inside tmux
  5 Shell only             no agent
  6 Quit                   close Termux
```

The tmux row turns the closest free-pi equivalent of OpenCode's session tabs
into tmux: **one tab = one tmux window** inside a single session named `pi`.
The move keys copy OpenCode V2 (`session.tab.next` / `session.tab.previous`):

| key | action |
| --- | --- |
| `Alt+↓` · `Ctrl+Tab` | next tab |
| `Alt+↑` · `Shift+Tab` | previous tab |
| `Ctrl+b c` | new tab (a second free-pi, not a shell) |
| `Ctrl+b ,` | rename the tab by hand (the automatic title then leaves it alone) |
| `Ctrl+b d` | detach (every pi keeps running) |

Tabs are also **tappable**: the strip sits on the top status bar, every tab is
padded to one finger-sized width, and the right corner holds two buttons —
` x ` closes the current tab (never the last one) and ` + new tab ` opens a new
one. Tapping a tab name switches to it, so a phone needs no keyboard at all.

A tab is a tmux window named after the prompt you sent (an extension renames it
on the first message, without calling a model). The session is created with
`pi --continue`, so opening the row resumes the last conversation instead of
starting over; a fresh tab (`Ctrl+b c`, ` + new tab `) is a clean session.

`Ctrl+Tab` needs a terminal that reports modified keys (extended keys); `Alt+↑/↓`
works everywhere, which is why it is listed first. Those keys only act inside the
`pi` session and are passed through everywhere else, so other tmux sessions keep
their defaults. Choosing the row again attaches the running session;
`tmux kill-session -t pi` ends all tabs. Without tmux the row warns and starts
plain `pi` instead; inside tmux it never nests a second session.

Choosing a component that is not installed asks `Install it now? [y/N]` first —
one dialog shared by every row (V1, V2, Pi). Answer `n` and nothing changes.
`b` opens the `~/.bashrc` options. Skip the menu with `OPENCODE_NO_AUTO=1 bash`.

`--only pi` adds the `pi` row and its `pi` wrapper without touching the OpenCode
choice; `codemux check` shows it as its own row.

## 🧠 Memory that survives sessions

`MEMORY.md` (facts, decisions, paths) and `RECENT.md` (last sessions **plus the
open items** — questions waiting for an answer, explicit next steps) are loaded
into every new session automatically — no "what were we doing?" anymore. The
memory plugin also refreshes `RECENT.md` whenever a fact is saved.

When codemux has a cached update, the plugins add one short line to the session
context, so long sessions are told about it without opening the menu.

## ⛽ Free-model quota

`quota` counts the assistant messages in the local databases (one message = one
request; the free quota resets at 00:00 UTC = 07:00 WIB):

```bash
quota                 # today, with a breakdown per model
quota --week          # the last 7 days
quota --warn          # one line, only when the warning threshold is reached
quota --json          # for scripts
```

The daily limit defaults to 200 (`QUOTA_LIMIT`, `--limit`) and the menu prints a
warning line once you are close to it.

> The command was called `kuota` before 0.7.6. `codemux install` / `codemux
> upgrade` remove the old file and symlink, so `quota` is the only name left.

## 🎨 tmux theme

`codemux install` writes a managed block into `~/.tmux.conf`: a dark status bar
(tmux 3.8 otherwise ships green on black) plus `extended-keys on` with the `csi-u`
format, which is what the pi TUI needs for Shift+Enter and friends:

```tmux
# --- codemux:tmux begin (managed; edits inside this block are overwritten) ---
set -g extended-keys on
set -g extended-keys-format csi-u
set -g status-style "bg=#101010,fg=#c0c0c0"
...
# --- codemux:tmux end ---
```

Only that region is touched: your own settings outside the markers stay as they
are, and the previous file is kept as `~/.tmux.conf.bak-tmuxconf-<timestamp>`.
Applying it needs no restart — `tmux source-file ~/.tmux.conf` updates every
running session.

## 🔧 Everyday commands

| Command | What it does |
|---|---|
| `codemux check` | 📋 status of every module |
| `codemux status` | 🧾 lock, state file, last install progress |
| `codemux install` | ⚙️ install / resume / refresh (`--dry-run`, `--skip`) |
| `codemux upgrade` | ⬆️ apt + installed payloads + launcher + memory mechanism |
| `codemux update-check` | 🔍 compare local vs upstream versions |
| `codemux doctor` | 🩺 deeper checks (bashrc, wrapper, memory size, disk) |
| `codemux repair` | 🧯 fix stale lock, half-done dpkg, missing V2 shim |
| `codemux memory` | 🧠 memory status / size |
| `codemux self-update` | 📦 replace the codemux code (old version backed up) |
| `codemux uninstall` | 🗑️ remove payloads (your memory/projects stay) |

## ⬆️ Keeping it fresh

```bash
codemux update-check    # what is new?
codemux upgrade         # apt + installed payloads + launcher
```

- `upgrade` without `--only` touches **only what is installed** — a V1-only
  device never gets V2 pushed in.
- `upgrade --only apt,v1,launcher,memory` — explicit, `--dry-run` to preview.
- Inside V2, `/update` also works: it fetches the official payload and the
  launcher adopts it on the next start.
- The `memory` step refreshes the mechanism files (plugins, digest, `quota`) and
  keeps `MEMORY.md` untouched.
- Update results are cached 24 h and shown as one line in the startup menu.

## 🆘 When something looks broken

| Symptom | Fix |
|---|---|
| Install stopped halfway | `codemux install` (resumes) |
| "another install is running" | `codemux repair` (drops a stale lock) |
| `curl: cannot locate symbol SSL_...` | `codemux repair` (heals libcurl) |
| V2 won't start | `codemux repair` (reinstalls the compat shim) |
| Menu shows "outdated launcher block" | `codemux install` (refreshes `~/.bashrc`) |

## 🧪 Tests

Everything runs without touching the system: each suite builds its own sandbox
(`HOME`, `PREFIX`, `CODEMUX_HOME`) and fakes the network.

```bash
bash tools/tests-tmux.sh  # one tmux window per suite, all at once, watch live
bash tools/run-tests.sh   # every suite in parallel (~85 s), one line per suite
bash tools/run-tests.sh smoke resume   # only these, -j1 for a serial run
bash tests/harness.sh     # cheap gate: portability + one suite in a mock Termux
```

`tools/tests-tmux.sh` gives every suite its own tmux window and starts them all
at once, then returns immediately — the run costs the slowest suite, not the sum,
and no window stays silent while it waits. A `summary` window collects the lines:

```bash
tmux attach -t codemux-tests              # watch all of them
tmux attach -t codemux-tests:summary      # one line per suite, as they end
bash tools/tests-tmux.sh --status         # 0 pass, 1 fail, 2 running, 3 no run
bash tools/tests-tmux.sh --kill           # stop the session
```

Inside the session `Ctrl-b n` / `Ctrl-b p` move between windows, `Ctrl-b <n>` jumps
to one, `Ctrl-b d` detaches and leaves the run going. `--wait` blocks until the run
finishes and exits with its result, so a script never has to poll with `sleep`.

Shorter and longer waits get the same treatment from `tools/watch-tmux.sh`: it
runs any command in a tmux window, keeps the output, and blocks on a tmux
channel instead of sleeping. Use it for CI, upgrades or anything slow:

```bash
bash tools/watch-tmux.sh -n ci -- gh run watch 12345 --exit-status
echo $?    # the command's own status, no polling
```

The suites, if you want to run one by hand:

```bash
bash tests/smoke.sh       # syntax, help, check --json, progress bar, dry runs
bash tests/resume.sh      # install killed midway, then resumed
bash tests/adapter.sh     # V1/V2 adapters: download → run detached → verify
bash tests/launcher-memory.sh  # menu, memory merge, update notice, quota line
bash tests/maintenance.sh # update-check, doctor, upgrade, uninstall
bash tests/release.sh     # bootstrap tarball + self-update
bash tests/tmuxconf.sh    # managed ~/.tmux.conf block: fresh, stale, blocked
```

Each suite waits for a state with `wait_state` (a 0.1 s poll) rather than a fixed
`sleep 3`, so running them side by side does not make them flaky.

**Run `tests/harness.sh` before pushing.** It catches the class of bug that only
shows up on a plain runner: a raw `$PREFIX` read under `set -u`, a hardcoded
`/data/data/com.termux` path, or a non-portable shebang.

The CI runs every suite **twice** — once with a mock Termux `PREFIX` and once
with it unset — plus `shellcheck`, `bash -n`, and a drift check on the shared
progress bar. Locally you can copy the second layout with:

```bash
env -u PREFIX TMPDIR="$PREFIX/tmp" bash tests/smoke.sh
```

Two blocks are shared with the two `opencode-termux*` repos: the ASCII progress
bar (`lib/progress-bar.sh`) and the tmux config (`lib/tmux-config.sh`). Run
`bash tools/sync-progress-bar.sh` / `bash tools/sync-tmux-config.sh` to copy
them into the siblings; `--check` reports drift and is what CI runs. Edit the
source block, never a copy.

## 📁 Layout

```
bin/codemux        entry point
lib/*.sh           commands (install, check, upgrade, update, ...)
lib/modules/       one file per module (deps, glibc, v1, v2, launcher, memory, ...)
lib/progress-bar.sh  the ASCII progress bar, shared with the opencode-termux repos
lib/tmux-config.sh   the managed ~/.tmux.conf block, shared the same way
tools/             sync-progress-bar.sh, sync-tmux-config.sh (copy, or --check for drift)
templates/         bashrc block, memory files
tests/             harness, smoke, launcher-memory, maintenance, resume, release, adapter, tmuxconf
install.sh         bootstrap (tarball + sha256)
```

## ⚠️ Notes

- Repo has **mechanism only** — personal memory contents are never pushed.
- If cloned to `/storage/emulated/0` (FUSE), files cannot be executed directly →
  run `bash bin/codemux …`.
- `raw.githubusercontent.com` may serve stale files on mobile networks → release
  downloads use a tarball + `sha256`.
- The memory mechanism files (plugins, `quota`, digest) are fetched from
  `raw.githubusercontent.com`, not the GitHub API: the API allows only 60
  anonymous requests per hour, and five files per install used to run it dry.
- `uninstall` never deletes `MEMORY.md`, `AGENTS.md`, projects, or backups.

## 📜 License

[MIT](LICENSE)
