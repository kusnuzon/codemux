# 🚀 codemux — Termux Setup in One Command

Installs and maintains **OpenCode V1 + V2** on Termux: startup menu, cross-session
memory, base toolset, Android storage, and update checks. Idempotent — safe to
run again and again.

> 📜 Full design: [PRD.md](PRD.md)

## ✨ What you get

- 🤖 **OpenCode V1 and/or V2** — you choose, nothing extra is pulled in
- 🎛️ **Startup menu** — arrow keys, opens the component you pick
- 🧠 **Cross-session memory** — `MEMORY.md` + `RECENT.md` loaded every session
- 🧰 **Base toolset** — git, gh, python, nodejs, sqlite, jq, shellcheck, htop, ...
- 📂 **Android storage** — runs `termux-setup-storage` when it is still missing
- 🔄 **Update check** — sees new codemux/V1/V2/apt releases before you ask
- 🛡️ **Resume-safe** — killed midway? run it again, it continues

## 📦 Prerequisites

Termux on Android, **aarch64**, **not root**. That's it — dependencies are
installed automatically.

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
  ❯ 1) OpenCode V1 only — stable, legacy DB
    2) OpenCode V2 only — new, separate DB
    3) Both — V1 + V2 (default)
```

- ↑/↓ (or `j`/`k`) move · `Enter` run · `1`-`3` pick directly · `q` cancel
- The answer is saved in `~/.config/codemux/components` and reused later
- Skipping the picker (CI, `curl | bash`): saved choice, default `v1 v2`

Non-interactive:

```bash
… | bash -s -- --only v1     # V1 only (V2 is never touched)
… | bash -s -- --only v2     # V2 only
… | bash -s -- --only both   # V1 + V2 (default)
```

## ⌨️ Startup menu

Every new Termux session opens a menu — nothing is hidden:

```
❯ 1 OpenCode V1    1.19.5 · stable · legacy DB
  2 OpenCode V2    not installed · Enter to install
  3 Shell only     no opencode
  4 Quit           close Termux
```

Choosing a component that is not installed asks `Install it now? [y/N]` first.
Answer `n` and nothing changes. Skip the menu with `OPENCODE_NO_AUTO=1 bash`.

## 🧠 Memory that survives sessions

`MEMORY.md` (facts, decisions, paths) and `RECENT.md` (last sessions) are loaded
into every new session automatically — no "what were we doing?" anymore. The
memory plugin also refreshes `RECENT.md` whenever a fact is saved.

## 🔧 Everyday commands

| Command | What it does |
|---|---|
| `codemux check` | 📋 status of every module |
| `codemux install` | ⚙️ install / resume / refresh (`--dry-run`, `--skip`) |
| `codemux upgrade` | ⬆️ apt + only the payloads that are installed + launcher |
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
- `upgrade --only apt,v1,launcher` — explicit, `--dry-run` to preview.
- Update results are cached 24 h and shown as one line in the startup menu.

## 🆘 When something looks broken

| Symptom | Fix |
|---|---|
| Install stopped halfway | `codemux install` (resumes) |
| "another install is running" | `codemux repair` (drops a stale lock) |
| `curl: cannot locate symbol SSL_...` | `codemux repair` (heals libcurl) |
| V2 won't start | `codemux repair` (reinstalls the compat shim) |
| Menu shows "outdated launcher block" | `codemux install` (refreshes `~/.bashrc`) |

## 📁 Layout

```
bin/codemux        entry point
lib/*.sh           commands (install, check, upgrade, update, ...)
lib/modules/       one file per module (deps, glibc, v1, v2, launcher, memory, ...)
templates/         bashrc block, memory files
tests/             smoke, launcher-memory, maintenance, resume, release, adapter
install.sh         bootstrap (tarball + sha256)
```

## ⚠️ Notes

- Repo has **mechanism only** — personal memory contents are never pushed.
- If cloned to `/storage/emulated/0` (FUSE), files cannot be executed directly →
  run `bash bin/codemux …`.
- `raw.githubusercontent.com` may serve stale files on mobile networks → release
  downloads use a tarball + `sha256`.
- `uninstall` never deletes `MEMORY.md`, `AGENTS.md`, projects, or backups.

## 📜 License

[MIT](LICENSE)
