#!/usr/bin/env bash
# tests/launcher-memory.sh — test the launcher, dotfiles, and memory modules (M4).
# Full sandbox: dedicated HOME, PREFIX, CODEMUX_HOME. The system is NOT touched.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX_ROOT="$BASE/codemux-lm-$$"
rm -rf "$SANDBOX_ROOT"
mkdir -p "$SANDBOX_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- memory mechanism fixtures (replace the GitHub downloads) ----------------
FIXTURE="$SANDBOX_ROOT/fixture"
mkdir -p "$FIXTURE"
cat >"$FIXTURE/plugin.js" <<'EOS'
// memory.js (test fixture)
export default { id: "memory", setup() {} };
EOS
cat >"$FIXTURE/title.js" <<'EOS'
// session-title.js (test fixture)
export default { id: "session-title", async server() { return {} }, setup() {} };
EOS
cat >"$FIXTURE/notice.js" <<'EOS'
// update-notice.js (test fixture)
export default { id: "update-notice", setup() {}, async server() { return {} } };
EOS
cat >"$FIXTURE/digest.py" <<'EOS'
#!/usr/bin/env python3
import os
base = os.path.join(os.path.expanduser("~"), ".config", "opencode")
os.makedirs(base, exist_ok=True)
with open(os.path.join(base, "RECENT.md"), "w", encoding="utf-8") as fh:
    fh.write("# RECENT\n\n- created by the digest fixture\n")
EOS
chmod 700 "$FIXTURE/digest.py"
cat >"$FIXTURE/quota" <<'EOS'
#!/usr/bin/env python3
import sys
if "--warn" in sys.argv:
    print("\u26a0 quota 161/200 (81%) · run: quota")
    raise SystemExit(0)
print("quota fixture")
EOS
chmod 700 "$FIXTURE/quota"

new_sandbox() {
  local d="${SANDBOX_ROOT:?}/$1"
  rm -rf "$d"
  # The pi module resolves free-pi-cli on PATH. Give every sandbox an empty
  # prefix/bin as the first entry: without it the module looks at whatever the
  # host has, which differs between a developer machine (npx cache) and CI.
  mkdir -p "$d/home" "$d/state" "$d/prefix/bin"
  printf '%s' "$d"
}

run_cm() { # <sandbox> <command...>
  local sb="$1"
  shift
  env HOME="$sb/home" CODEMUX_HOME="$sb/state" PREFIX="$sb/prefix" TMPDIR="$BASE" \
    CODEMUX_ALLOW_NONANDROID=1 \
    CODEMUX_MEMORY_PLUGIN_URL="$FIXTURE/plugin.js" \
    CODEMUX_MEMORY_TITLE_URL="$FIXTURE/title.js" \
    CODEMUX_MEMORY_NOTICE_URL="$FIXTURE/notice.js" \
    CODEMUX_MEMORY_DIGEST_URL="$FIXTURE/digest.py" \
    CODEMUX_MEMORY_QUOTA_URL="$FIXTURE/quota" \
    bash "$ROOT/bin/codemux" "$@"
}

SKIP_ALL_BUT_M4="deps,mirror,storage,toolset,glibc,v1,v2"
SKIP_ONLY_LAUNCHER="deps,mirror,storage,toolset,glibc,v1,v2,dotfiles,memory"
# `--only pi` is a tail module: everything else is skipped to keep it focused.
SKIP_ONLY_PI="deps,mirror,storage,toolset,glibc,v1,v2,launcher,dotfiles,memory"

# =============================================================================
# 1. Fresh: every M4 module installed from scratch
# =============================================================================
SB="$(new_sandbox fresh)"
# A pre-0.7.6 install left a `kuota` script + symlink behind: they must go away.
mkdir -p "$SB/home/.config/opencode/bin"
printf '#!/bin/sh\necho old\n' >"$SB/home/.config/opencode/bin/kuota"
ln -sf "$SB/home/.config/opencode/bin/kuota" "$SB/prefix/bin/kuota"
run_cm "$SB" install --skip "$SKIP_ALL_BUT_M4" >"$SB/install.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "fresh: install finished (exit 0)"; else
  bad "fresh: install exit $rc"
  sed 's/^/     /' "$SB/install.log" | tail -20
fi

rc_file="$SB/home/.bashrc"
if bash -n "$rc_file" 2>/dev/null; then ok "fresh: .bashrc passes bash -n"; else bad "fresh: .bashrc is broken"; fi
if [ "$(grep -c 'codemux:launcher begin' "$rc_file")" -eq 1 ] &&
  [ "$(grep -c 'codemux:launcher end' "$rc_file")" -eq 1 ]; then
  ok "fresh: exactly one launcher marker pair"
else
  bad "fresh: launcher markers are not exactly one pair"
fi
if grep -q '_oc_banner()' "$rc_file" && grep -q '_oc_menu_loop()' "$rc_file"; then
  ok "fresh: banner + menu functions present"
else
  bad "fresh: banner/menu functions incomplete"
fi
if grep -q '_oc_refresh_digest()' "$rc_file"; then ok "fresh: digest wrapper present"; else bad "fresh: digest wrapper missing"; fi

# The wrapper has to put the terminal back after EVERY agent run, not only a
# failed one: a clean /exit can leave raw termios, and the shell then looks
# frozen — keys arrive, nothing echoes (V1 → "Shell only" froze Termux). Gating
# the repair on a non-zero exit code is exactly what failed.
if grep -q 'codemux:memory version 2' "$rc_file" &&
  [ "$(grep -c 'codemux:memory begin' "$rc_file")" -eq 1 ]; then
  ok "fresh: wrapper is version 2 and written exactly once"
else
  bad "fresh: wrapper block is missing, duplicated or still version 1"
fi
if grep -q '\[ "\$rc" -ne 0 \] && _oc_tty_repair' "$rc_file"; then
  bad "fresh: terminal repair is still gated on a failed exit code"
else
  ok "fresh: terminal repair runs after every agent run"
fi
if sed -n '/^opencode() {/,/^}/p' "$rc_file" | grep -q '_oc_tty_repair'; then
  ok "fresh: the opencode wrapper repairs the terminal"
else
  bad "fresh: the opencode wrapper never repairs the terminal"
fi

# The pi menu row shows the installed free-pi version. free-pi writes no
# VERSION file, so the number must come from the npx package manifest.
mkdir -p "$SB/home/.npm/_npx/deadbeef/node_modules/free-pi-cli"
printf '{\n  "name": "free-pi-cli",\n  "version": "9.9.9"\n}\n' \
  >"$SB/home/.npm/_npx/deadbeef/node_modules/free-pi-cli/package.json"
pi_ver="$(HOME="$SB/home" bash -c 'eval "$(sed -n "/^_oc_ver()/,/^}/p" "$1")"; _oc_ver pi' _ "$rc_file" 2>/dev/null)"
if [ "$pi_ver" = "9.9.9" ]; then
  ok "fresh: _oc_ver pi reads the npx manifest (9.9.9)"
else
  bad "fresh: _oc_ver pi = '$pi_ver' (expected 9.9.9)"
fi

[ -f "$SB/home/.bash_profile" ] && ok "fresh: .bash_profile created" || bad "fresh: .bash_profile missing"
[ -f "$SB/home/.hushlogin" ] && ok "fresh: .hushlogin created" || bad "fresh: .hushlogin missing"

cfg="$SB/home/.config/opencode/opencode.jsonc"
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$cfg"))
ins = d["instructions"]
assert any(p.endswith("MEMORY.md") for p in ins), ins
assert any(p.endswith("RECENT.md") for p in ins), ins
PY
then
  ok "fresh: opencode.jsonc valid + instructions complete"
else
  bad "fresh: opencode.jsonc invalid / entries missing"
fi

# The template itself stays in Indonesian (personal-data template, not translated).
if grep -q 'Memori lintas sesi' "$SB/home/.config/opencode/MEMORY.md" 2>/dev/null; then
  ok "fresh: MEMORY.md from the template"
else
  bad "fresh: MEMORY.md not created from the template"
fi
[ -f "$SB/home/.config/opencode/RECENT.md" ] && ok "fresh: RECENT.md created" || bad "fresh: RECENT.md missing"
[ -s "$SB/home/.config/opencode/plugins/memory.js" ] && ok "fresh: plugins/memory.js downloaded" || bad "fresh: plugins/memory.js missing"
[ -s "$SB/home/.config/opencode/plugins/session-title.js" ] && ok "fresh: plugins/session-title.js downloaded" || bad "fresh: plugins/session-title.js missing"
[ -x "$SB/home/.config/opencode/bin/session-digest.py" ] && ok "fresh: session-digest.py executable" || bad "fresh: session-digest.py not executable"
[ -s "$SB/home/.config/opencode/plugins/update-notice.js" ] && ok "fresh: plugins/update-notice.js downloaded" || bad "fresh: plugins/update-notice.js missing"
[ -x "$SB/home/.config/opencode/bin/quota" ] && ok "fresh: bin/quota executable" || bad "fresh: bin/quota not executable"
[ -L "$SB/prefix/bin/quota" ] && ok "fresh: quota on PATH (symlink)" || bad "fresh: quota symlink missing"
if [ ! -e "$SB/home/.config/opencode/bin/kuota" ] && [ ! -e "$SB/prefix/bin/kuota" ]; then
  ok "fresh: legacy kuota file + symlink dropped"
else
  bad "fresh: legacy kuota leftovers remain"
fi

# check: the three M4 modules must be OK
if run_cm "$SB" check --json >"$SB/check.json" 2>/dev/null; then :; fi
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/check.json"))
st = {m["modul"]: m["status"] for m in d["modul"]}
for k in ("launcher", "dotfiles", "memory"):
    assert st[k] == "OK", (k, st[k])
PY
then
  ok "fresh: check → launcher/dotfiles/memory OK"
else
  bad "fresh: check still not OK ($(python3 -c '
import json;d=json.load(open("'"$SB"'/check.json"));print({m["modul"]:m["status"] for m in d["modul"]})' 2>/dev/null))"
fi

if run_cm "$SB" memory >"$SB/memory.log" 2>&1 && grep -q 'cross-session memory' "$SB/memory.log" &&
  grep -q 'MEMORY.md' "$SB/memory.log"; then
  ok "fresh: codemux memory shows the status"
else
  bad "fresh: codemux memory failed"
fi

# idempotent: run install again, it must not duplicate anything
run_cm "$SB" install --skip "$SKIP_ALL_BUT_M4" >"$SB/install2.log" 2>&1
if [ "$(grep -c 'codemux:launcher begin' "$rc_file")" -eq 1 ] &&
  [ "$(grep -c '_oc_refresh_digest()' "$rc_file")" -eq 1 ] &&
  [ "$(grep -c 'RECENT.md' "$cfg")" -eq 1 ] && bash -n "$rc_file" 2>/dev/null; then
  ok "fresh: second install is idempotent (no duplicates)"
else
  bad "fresh: second install duplicated blocks/entries"
fi

# =============================================================================
# 1b. a markerless wrapper from opencode-termux is replaced, not doubled
# =============================================================================
SB1B="$(new_sandbox legacy-wrapper)"
cat >"$SB1B/home/.bashrc" <<'EOB'
# --- refresh the session summary before opencode starts (install.sh) ---
_oc_refresh_digest() { :; }
_oc_tty_repair() { :; }
opencode() { :; }
opencode-v2() { :; }
EOB
run_cm "$SB1B" install --skip "$SKIP_ALL_BUT_M4" >"$SB1B/install.log" 2>&1
legacy_rc="$SB1B/home/.bashrc"
if [ "$(grep -c '^# --- refresh the session summary' "$legacy_rc")" -eq 0 ]; then
  ok "legacy: the old markerless wrapper is dropped"
else
  bad "legacy: the old markerless wrapper survived (two definitions)"
fi
if [ "$(grep -c 'codemux:memory version 2' "$legacy_rc")" -eq 1 ] &&
  bash -n "$legacy_rc" 2>/dev/null; then
  ok "legacy: exactly one current wrapper remains and .bashrc is valid"
else
  bad "legacy: wrapper count/validity is wrong after the rewrite"
fi

# =============================================================================
# 2. Personal data must not be overwritten; a config missing entries is completed
# =============================================================================
SB2="$(new_sandbox personal)"
mkdir -p "$SB2/home/.config/opencode"
printf '# MEMORY pribadi\n- PRIBADI-JANGAN-HILANG\n' >"$SB2/home/.config/opencode/MEMORY.md"
cat >"$SB2/home/.config/opencode/opencode.jsonc" <<EOS
{
  "\$schema": "https://opencode.ai/config.json",
  "instructions": [
    "$SB2/home/.config/opencode/MEMORY.md"
  ]
}
EOS
before="$(wc -c <"$SB2/home/.config/opencode/MEMORY.md")"

run_cm "$SB2" install --skip "$SKIP_ALL_BUT_M4" >"$SB2/install.log" 2>&1
rc=$?
after="$(wc -c <"$SB2/home/.config/opencode/MEMORY.md")"

if [ "$rc" -eq 0 ] && [ "$before" -eq "$after" ] &&
  grep -q 'PRIBADI-JANGAN-HILANG' "$SB2/home/.config/opencode/MEMORY.md"; then
  ok "personal: MEMORY.md not overwritten"
else
  bad "personal: MEMORY.md changed/overwritten (rc=$rc)"
fi

cfg2="$SB2/home/.config/opencode/opencode.jsonc"
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$cfg2"))
ins = d["instructions"]
assert len(ins) == 2, ins
assert ins[0].endswith("MEMORY.md") and ins[1].endswith("RECENT.md"), ins
PY
then
  ok "personal: config completed with RECENT.md, old entries kept"
else
  bad "personal: config not completed correctly"
fi

# =============================================================================
# 3. Adopting an old block without markers
# =============================================================================
SB3="$(new_sandbox legacy)"
cat >"$SB3/home/.bashrc" <<'EOS'
# old ~/.bashrc
export EDITOR="nano"

# --- banner + menu launcher (2026-10-22) ---
_oc_banner() { printf 'old banner\n'; }
_oc_launcher() { _oc_banner; }
if [ -z "${OPENCODE_NO_AUTO:-}" ]; then
  _oc_launcher
fi
EOS
run_cm "$SB3" install --skip "$SKIP_ONLY_LAUNCHER" >"$SB3/install.log" 2>&1
rc=$?
rc3="$SB3/home/.bashrc"

if [ "$rc" -eq 0 ]; then ok "legacy: launcher install finished"; else bad "legacy: install exit $rc"; fi
if ! grep -q '^# --- banner + menu launcher' "$rc3"; then
  ok "legacy: old block removed"
else
  bad "legacy: old block still present"
fi
if [ "$(grep -c '_oc_launcher()' "$rc3")" -eq 1 ] &&
  [ "$(grep -c 'codemux:launcher begin' "$rc3")" -eq 1 ] &&
  bash -n "$rc3" 2>/dev/null; then
  ok "legacy: single new block + valid"
else
  bad "legacy: adoption produced a duplicate/broken block"
fi
if grep -q 'export EDITOR="nano"' "$rc3"; then
  ok "legacy: non-launcher content preserved"
else
  bad "legacy: old content lost"
fi

# =============================================================================
# 4. Broken bashrc → restored, never left in a broken state
# =============================================================================
SB4="$(new_sandbox broken)"
printf 'if [ ; then\n' >"$SB4/home/.bashrc"
before_sum="$(cksum <"$SB4/home/.bashrc")"
run_cm "$SB4" install --skip "$SKIP_ONLY_LAUNCHER" >"$SB4/install.log" 2>&1 || true
if [ "$(cksum <"$SB4/home/.bashrc")" = "$before_sum" ]; then
  ok "broken: broken bashrc left unchanged (clean failure, not worse)"
else
  if bash -n "$SB4/home/.bashrc" 2>/dev/null && grep -q 'codemux:launcher begin' "$SB4/home/.bashrc"; then
    ok "broken: broken bashrc repaired into a valid one"
  else
    bad "broken: bashrc left in a broken state"
  fi
fi

# =============================================================================
# 5. menu flicker guard: cursor hidden + only 4 rows redrawn
# =============================================================================
TPL="$ROOT/templates/bashrc-block.sh"
# The version marker lives in the template header, the probe compares it against
# CODEMUX_LAUNCHER_BLOCK_VERSION: bumping only one of the two leaves `check` at
# WARN (and users never receive the new block).
if grep -qF "# codemux:launcher version $(sed -n 's/^CODEMUX_LAUNCHER_BLOCK_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/modules/launcher.sh")" "$TPL"; then
  ok "menu: template header version matches CODEMUX_LAUNCHER_BLOCK_VERSION"
else
  bad "menu: launcher block version in the template header is out of sync"
fi
if grep -qF '\033[?25l' "$TPL" && grep -qF '\033[?25h' "$TPL"; then
  ok "menu: cursor hidden & restored"
else
  bad "menu: cursor escapes (?25l/?25h) incomplete"
fi
# The menu cannot rely on the ~/.bashrc wrapper (a component may be a bare
# binary), so it repairs the terminal itself: once after a component returns and
# once before handing the shell back. A missing call leaves Termux frozen.
fix_sites="$(grep -c '_oc_tty_fix' "$TPL")"
if grep -q '^_oc_tty_fix() {' "$TPL" && [ "$fix_sites" -ge 4 ]; then
  ok "menu: terminal repaired after a component and before the shell"
else
  bad "menu: terminal repair helper missing or not on every exit path ($fix_sites sites)"
fi
# A terminal that re-opens but answers EOF instantly must not be retried
# forever: that loop burns the CPU and freezes the phone.
if grep -q 'reopens' "$TPL"; then
  ok "menu: the key reader limits terminal re-opens (cannot spin)"
else
  bad "menu: the key reader can still spin on a dead terminal"
fi
if grep -qF '\033[%dA' "$TPL" && ! grep -qF '\033[7A' "$TPL" && ! grep -qF '\033[8A' "$TPL"; then
  ok "menu: redraws only the option rows (dynamic offset)"
else
  bad "menu: still rewrites the whole block with a fixed offset"
fi
if grep -q '_oc_redraw()' "$TPL" && grep -q '_OC_COUNT + 3' "$TPL"; then
  ok "menu: redraw offset follows the row count (_OC_COUNT + 3)"
else
  bad "menu: redraw offset is not derived from _OC_COUNT"
fi
# every component row is always offered; a missing one is marked "not installed"
menu_keys() { # <sandbox> → keys of the menu rows
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"   # only the sandbox bin: the real installed codemux must not leak in
      . "$1"
      _oc_items
      printf "%s" "${_OC_KEYS[*]}"
    ' _ "$TPL" "$sb/prefix/bin" 2>/dev/null
}
menu_descs() { # <sandbox> → descriptions of the menu rows
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"
      . "$1"
      _oc_items
      printf "%s\n" "${_OC_DESCS[@]}"
    ' _ "$TPL" "$sb/prefix/bin" 2>/dev/null
}
menu_names() { # <sandbox> → names of the menu rows
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"
      . "$1"
      _oc_items
      printf "%s\n" "${_OC_NAMES[@]}"
    ' _ "$TPL" "$sb/prefix/bin" 2>/dev/null
}
menu_guide() { # <sandbox> → the "Shell only" command guide
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" NO_COLOR=1 bash -c '
      PATH="$2"
      . "$1"
      _oc_colors
      _oc_guide
    ' _ "$TPL" "$sb/prefix/bin" 2>/dev/null
}
menu_version() { # <sandbox> → the `version` command output
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"
      . "$1"
      version
    ' _ "$TPL" "$sb/prefix/bin" 2>/dev/null
}
menu_meta() { # <sandbox> <key> → meta of one row
  local sb="$1" k="$2"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$3"
      . "$1"
      _oc_meta "$2"
    ' _ "$TPL" "$k" "$sb/prefix/bin" 2>/dev/null
}
menu_launch() { # <sandbox> <key> [TMUX] → run one row, output discarded
  local sb="$1" k="$2" tmuxval="${3:-}"
  env -u TMUX HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 \
    TMPDIR="$BASE" TMUX="$tmuxval" bash -c '
      PATH="$3"
      . "$1"
      _oc_colors
      _oc_launch_component "$2"
    ' _ "$TPL" "$k" "$sb/prefix/bin" >/dev/null 2>&1
}
SB5="$(new_sandbox menu-items)"
mkdir -p "$SB5/prefix/bin"
printf '#!/bin/sh\n' >"$SB5/prefix/bin/opencode-v2"
chmod +x "$SB5/prefix/bin/opencode-v2"
if [ "$(menu_keys "$SB5")" = "v1 v2 pi pitmux shell quit" ] &&
  menu_descs "$SB5" | sed -n '1p' | grep -q 'not installed'; then
  ok "menu: V2-only install still offers V1, marked not installed"
else
  bad "menu: V2-only rows are $(menu_keys "$SB5")"
fi
rm -f "$SB5/prefix/bin/opencode-v2"
printf '#!/bin/sh\n' >"$SB5/prefix/bin/opencode"
chmod +x "$SB5/prefix/bin/opencode"
if [ "$(menu_keys "$SB5")" = "v1 v2 pi pitmux shell quit" ] &&
  menu_descs "$SB5" | sed -n '2p' | grep -q 'not installed'; then
  ok "menu: V1-only install still offers V2, marked not installed"
else
  bad "menu: V1-only rows are $(menu_keys "$SB5")"
fi
printf '#!/bin/sh\n' >"$SB5/prefix/bin/opencode-v2"
printf '#!/bin/sh\n' >"$SB5/prefix/bin/pi"
chmod +x "$SB5/prefix/bin/opencode-v2" "$SB5/prefix/bin/pi"
if [ "$(menu_keys "$SB5")" = "v1 v2 pi pitmux shell quit" ] &&
  ! menu_descs "$SB5" | grep -q 'not installed'; then
  ok "menu: both installed → six rows, no install note"
else
  bad "menu: both rows are $(menu_keys "$SB5")"
fi
rm -f "$SB5/prefix/bin/opencode" "$SB5/prefix/bin/opencode-v2" "$SB5/prefix/bin/pi"
if [ "$(menu_keys "$SB5")" = "v1 v2 pi pitmux shell quit" ] &&
  [ "$(menu_descs "$SB5" | grep -c 'not installed')" -eq 4 ]; then
  ok "menu: nothing installed → V1/V2/Pi (and the tmux row) marked not installed"
else
  bad "menu: empty rows are $(menu_keys "$SB5")"
fi
if [ "$(menu_names "$SB5" | sed -n '3p')" = "Free-pi (Pi)" ]; then
  ok "menu: the free-pi row is labelled Free-pi (Pi)"
else
  bad "menu: free-pi row label is '$(menu_names "$SB5" | sed -n '3p')'"
fi
if [ "$(menu_names "$SB5" | sed -n '4p')" = "Free-pi (Pi) · tmux" ]; then
  ok "menu: the tmux row sits right below pi and is labelled Free-pi (Pi) · tmux"
else
  bad "menu: tmux row label is '$(menu_names "$SB5" | sed -n '4p')'"
fi
# The tmux row must install the `pi` component, not a `pitmux` one (there is no
# such component: `codemux install --only pitmux` would fail).
if [ "$(menu_meta "$SB5" pitmux)" = 'pi|Free-pi (Pi) · tmux|Pi' ]; then
  ok "menu: the tmux row reuses the pi binary and the pi component"
else
  bad "menu: tmux row meta is '$(menu_meta "$SB5" pitmux)'"
fi
# --- menu: the tmux row launches pi through tmux, with sane fallbacks ---
SB6="$(new_sandbox menu-tmux)"
mkdir -p "$SB6/prefix/bin"
cat >"$SB6/prefix/bin/pi" <<EOF
#!/bin/sh
echo pi >>"$SB6/pi.calls"
EOF
cat >"$SB6/prefix/bin/tmux" <<EOF
#!/bin/sh
echo "\$*" >>"$SB6/tmux.calls"
case "\$1" in
  # Like a real server: the session is absent until the file exists.
  has-session) [ -e "$SB6/tmux.session" ] ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SB6/prefix/bin/pi" "$SB6/prefix/bin/tmux"
menu_launch "$SB6" pitmux
if grep -qx "new-session -d -s pi OPENCODE_NO_AUTO=1 bash -ic 'pi --continue || pi'" "$SB6/tmux.calls" 2>/dev/null &&
  [ "$(tail -n 1 "$SB6/tmux.calls")" = 'attach-session -t pi' ] &&
  [ ! -s "$SB6/pi.calls" ]; then
  ok "menu: the tmux row creates the pi session detached, then attaches (pi runs in that window)"
else
  bad "menu: tmux row ran '$(tr '\n' ';' <"$SB6/tmux.calls" 2>/dev/null)' (pi calls: $(cat "$SB6/pi.calls" 2>/dev/null))"
fi
# One tab = one tmux window, so the key moves must mirror OpenCode V2's
# session tabs (alt+down/ctrl+tab next, alt+up/shift+tab previous) while
# staying inert outside the `pi` session. tmux has no ctrl+shift+tab: it never
# decodes that chord from a plain terminal, so shift+tab is the reverse key.
if grep -qx 'set-option -t pi default-command OPENCODE_NO_AUTO=1 bash -ic pi' "$SB6/tmux.calls" &&
  grep -qx 'bind-key -T prefix c if-shell -F #{==:#{session_name},pi} new-window -t pi: -n pi new-window' "$SB6/tmux.calls" &&
  grep -qx 'rename-window -t pi:0 pi' "$SB6/tmux.calls" &&
  grep -qx 'bind-key -n C-Tab if-shell -F #{==:#{session_name},pi} next-window send-keys C-Tab' "$SB6/tmux.calls" &&
  grep -qx 'bind-key -n BTab if-shell -F #{==:#{session_name},pi} previous-window send-keys BTab' "$SB6/tmux.calls" &&
  grep -qx 'bind-key -n M-Down if-shell -F #{==:#{session_name},pi} next-window send-keys M-Down' "$SB6/tmux.calls" &&
  grep -qx 'bind-key -n M-Up if-shell -F #{==:#{session_name},pi} previous-window send-keys M-Up' "$SB6/tmux.calls"; then
  ok "menu: the tmux row maps alt+down/ctrl+tab and alt+up/shift+tab to next/previous tab (inside pi only)"
else
  bad "menu: tab keys are '$(grep 'bind-key' "$SB6/tmux.calls" 2>/dev/null | tr '\n' ';' | cut -c1-2000) / default-command '$(grep 'set-option' "$SB6/tmux.calls" 2>/dev/null)'"
fi
# Touch: one run-shell binding maps a tap on the 20-column tab strip to that
# tab - the name switches to it, the tab's own "x" asks before closing it - a
# swipe scrolls the page, and "+ new tab" on the right opens a new one. Only
# run-shell can read #{mouse_x}.
if grep -qx 'set-option -t pi status-right  + new tab ' "$SB6/tmux.calls" &&
  grep -qx 'set-option -t pi @tabstart 0' "$SB6/tmux.calls" &&
  grep -qx 'set-option -t pi status on' "$SB6/tmux.calls" &&
  grep -q '^set-option -t pi -u status-format' "$SB6/tmux.calls" &&
  grep -q '^bind-key -n MouseDown1Status run-shell -b .*x=#{mouse_x}' "$SB6/tmux.calls" &&
  grep -q 'codemux-tab-drag' "$SB6/tmux.calls" &&
  grep -q '@closepending' "$SB6/tmux.calls" &&
  grep -q 'kill-window -t' "$SB6/tmux.calls" &&
  grep -q 'select-window -t' "$SB6/tmux.calls" &&
  grep -q '^bind-key -n MouseDrag1Status run-shell -b ' "$SB6/tmux.calls" &&
  grep -q 'new-window -t .*-n pi' "$SB6/tmux.calls" &&
  grep -q '^bind-key -n MouseDown1StatusRight run-shell -b .*new-window -t .*@tabstart' "$SB6/tmux.calls"; then
  ok "menu: tap maps to its tab, 'x' turns that tab into keep/close, swipe scrolls, '+ new tab' opens and pages to the new tab"
else
  bad "menu: touch bindings are '$(grep -E 'status-right|MouseDown|MouseDrag|@tabstart' "$SB6/tmux.calls" 2>/dev/null | tr '\n' ';' | cut -c1-2000)"
fi
# A run-shell command that ends with a failing test makes tmux print the whole
# command in the message line ("'%s' returned %d"), which looked like a broken
# tab. Every touch binding must end with an explicit `exit 0`.
if grep -q "MouseDown1Status \"run-shell -b '.*; exit 0'\"" "$TPL" &&
  grep -q "MouseDown1StatusRight \"run-shell -b '.*; exit 0'\"" "$TPL" &&
  grep -q "MouseDrag1Status \"run-shell -b '.*; exit 0'\"" "$TPL"; then
  ok "menu: touch bindings end with exit 0 (a failing tail would print the script in tmux's message line)"
else
  bad "menu: touch binding tails are '$(grep -E 'MouseDown1Status|MouseDown1StatusRight|MouseDrag1Status' "$TPL" | rev | cut -c1-40 | rev | tr '\n' ';')"
fi
# A second status line cost the strip a row, and setting only its index left
# index 0 empty, which made tmux draw an empty first line - every tab
# disappeared. The block keeps one status line and no session status-format.
if grep -q "set-option -t pi status on" "$TPL" &&
  grep -q "set-option -t pi -u status-format" "$TPL" &&
  ! grep -q "status-format\[1\]" "$TPL"; then
  ok "menu: one status line only (no session status-format that could blank the strip)"
else
  bad "menu: status-format handling is '$(grep -c 'status-format' "$TPL") line(s)'"
fi
# The swipe baseline is the press column, so a page turns once the finger has
# travelled 20 columns in total - short motion events must add up instead of
# each one replacing the baseline (which is why the strip used to be stuck).
if grep -qF 'h=\$(( (x - d) / 20 ))' "$TPL" &&
  grep -q 'h \* 20' "$TPL" &&
  ! grep -q 'd - x' "$TPL"; then
  ok "menu: swipe pages by accumulated distance (per-event baseline kept, not overwritten)"
else
  bad "menu: swipe maths is '$(grep -o 'h=\$(( (x - d) / 20 ))' "$TPL" | head -1)'"
fi
rm -f "$SB6/tmux.session"
: >"$SB6/tmux.calls"
menu_launch "$SB6" pitmux "$SB6/tmux-1,1,1"
if [ "$(cat "$SB6/pi.calls" 2>/dev/null)" = "pi" ] && [ ! -s "$SB6/tmux.calls" ]; then
  ok "menu: inside tmux the row runs pi in the current session (no nesting)"
else
  bad "menu: inside tmux the row ran tmux '$(cat "$SB6/tmux.calls" 2>/dev/null)' / pi '$(cat "$SB6/pi.calls" 2>/dev/null)'"
fi
: >"$SB6/tmux.calls"
: >"$SB6/pi.calls"
rm -f "$SB6/prefix/bin/tmux"
menu_launch "$SB6" pitmux
if [ "$(cat "$SB6/pi.calls" 2>/dev/null)" = "pi" ] && [ ! -s "$SB6/tmux.calls" ]; then
  ok "menu: without tmux the row still starts pi (warning, no failure)"
else
  bad "menu: without tmux the row did not fall back to pi"
fi
printf '#!/bin/sh\n' >"$SB5/prefix/bin/pi"
chmod +x "$SB5/prefix/bin/pi"
# Capture first: `menu_guide | grep -q` fails under `set -o pipefail` because grep
# exits early and the producer dies of SIGPIPE (141).
guide_pi="$(menu_guide "$SB5")"
if grep -q 'pi *run free-pi directly' <<<"$guide_pi"; then
  ok "menu: the Shell only guide lists the pi command"
else
  bad "menu: the Shell only guide hides pi (guide: $(tr '\n' '|' <<<"$guide_pi"))"
fi
if grep -q 'no agent was started' <<<"$guide_pi" &&
  ! grep -q 'opencode was not started' <<<"$guide_pi"; then
  ok "menu: the Shell only guide is not OpenCode-specific"
else
  bad "menu: the Shell only guide still says opencode was not started"
fi
version_out="$(menu_version "$SB5")"
if grep -q '^Pi (free-pi):' <<<"$version_out"; then
  ok "menu: version prints the free-pi version row"
else
  bad "menu: version hides free-pi ($(tr '\n' '|' <<<"$version_out"))"
fi
rm -f "$SB5/prefix/bin/pi"
if grep -q "_oc_cmd_row 'Ctrl+b ,'" "$TPL" && grep -q "'new tab in the pi session'" "$TPL"; then
  ok "menu: the Shell only guide shows the tab keys (new tab, rename tab)"
else
  bad "menu: the guide hides the tab keys"
fi
if ! grep -q 'run free-pi directly' <<<"$(menu_guide "$SB5")"; then
  ok "menu: no pi on PATH → no pi line in the guide"
else
  bad "menu: the guide offers pi although it is not installed"
fi
if grep -q '_oc_launch_component()' "$TPL" && grep -q 'Install it now?' "$TPL"; then
  ok "menu: choosing a missing component asks before installing"
else
  bad "menu: missing component has no install confirmation"
fi
if grep -q '_oc_rows()' "$TPL" && grep -q '033\[K' "$TPL"; then
  ok "menu: option rows cleared to the end (\\033[K)"
else
  bad "menu: option rows do not clear leftover characters"
fi
if grep -q '_oc_int' "$TPL" && grep -q 'cancel' "$TPL"; then
  ok "menu: Ctrl+C only cancels the key press"
else
  bad "menu: Ctrl+C not handled (cursor may be left hidden)"
fi

# quota warning line: shown only when `quota` reports one, empty otherwise
quota_line() { # <sandbox> → the notice line
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" PATH="$sb/prefix/bin" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" \
    "${BASH:-bash}" -c '
    ACC=""; DIM=""; R=""
    . "$1"
    _oc_quota_notice
  ' _ "$TPL" 2>/dev/null
}
if grep -q '_oc_quota_notice$' "$TPL" || grep -q '^      _oc_quota_notice' "$TPL"; then
  ok "menu: quota warning is rendered with the menu"
else
  bad "menu: quota warning is never called"
fi
if [ -z "$(quota_line "$SB5")" ]; then
  ok "menu: no quota installed → no quota line"
else
  bad "menu: quota line printed without quota"
fi
printf '#!/bin/sh\nexit 0\n' >"$SB5/prefix/bin/quota"
chmod +x "$SB5/prefix/bin/quota"
if [ -z "$(quota_line "$SB5")" ]; then
  ok "menu: quota below the threshold → silent"
else
  bad "menu: quota line printed below the threshold"
fi
# The fake interpreter must be a path that exists on this machine: $PREFIX is
# unset on a plain CI runner, so resolve bash instead of assuming its layout.
printf '#!%s\nprintf "warn 161/200\\n"\n' "$(command -v bash)" >"$SB5/prefix/bin/quota"
chmod +x "$SB5/prefix/bin/quota"
case "$(quota_line "$SB5")" in
  *"161/200"*) ok "menu: quota warning is shown when the limit is near" ;;
  *) bad "menu: quota warning not shown" ;;
esac
rm -f "$SB5/prefix/bin/quota"

# =============================================================================
# 5b. one install confirmation for every row (V1, V2, Pi) + the bashrc entry
# =============================================================================
# The dialog must exist once and be used by every installable row: a row that
# installs without asking is a bug that only shows up when a user presses Enter
# on something they did not expect to install.
if grep -q '_oc_confirm_install()' "$TPL" && [ "$(grep -c '_oc_confirm_install "' "$TPL")" -eq 1 ]; then
  ok "menu: a single install confirmation shared by all rows"
else
  bad "menu: install confirmation is not shared (or duplicated)"
fi
if grep -qF 'Install it now? [y/N]' "$TPL" && grep -qF 'not installed — nothing changed.' "$TPL"; then
  ok "menu: the dialog offers [y/N] and reports 'nothing changed' on no"
else
  bad "menu: install dialog wording missing"
fi
for k in v1 v2 pi; do
  if _meta="$(env OPENCODE_NO_AUTO=1 bash -c '. "$1"; _oc_meta "$2"' _ "$TPL" "$k" 2>/dev/null)" &&
    [ -n "$_meta" ]; then
    ok "menu: row $k goes through the install path (${_meta%%|*})"
  else
    bad "menu: row $k has no install metadata"
  fi
done
# Enter on a missing row: "n" must change nothing and must not call codemux
ask_no() { # <key> → every line printed while answering "n"
  local sb="$1" key="$2"
  # The sandbox bin comes first but the real PATH stays behind it: `env bash` is
  # at $PREFIX/bin/bash on Termux and at /bin/bash on a plain runner, so a PATH
  # holding only the sandbox would not even find the interpreter.
  #
  # Set CODEMUX_ROOT too, not just its value: the block short-circuits on
  # `command -v codemux` first, and a real codemux on the host PATH would then
  # run a real install here instead of the sandbox one.
  env HOME="$sb/home" PREFIX="$sb/prefix" PATH="$sb/prefix/bin:$PATH" \
    CODEMUX_ROOT="$ROOT" CODEMUX_HOME="$sb/state" CODEMUX_ALLOW_NONANDROID=1 \
    OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      C1=""; C2=""; ACC=""; DIM=""; BOLD=""; HL=""; R=""
      _oc_cursor_show() { :; }
      _oc_cursor_hide() { :; }
      # Force the "missing" path for every row: a real opencode/pi on the host
      # PATH would otherwise be launched instead of asking the question.
      command() { [ "$1" = -v ] && return 1; builtin command "$@"; }
      . "$1"
      printf "n\n" | _oc_launch_component "$2"
      printf "rc=%s\n" "$?"
    ' _ "$TPL" "$key" 2>/dev/null
}
SB5B="$(new_sandbox confirm)"
mkdir -p "$SB5B/prefix/bin" "$SB5B/home"
for k in v1 v2 pi; do
  out="$(ask_no "$SB5B" "$k")"
  case "$out" in
    *"is not installed yet"*"rc=1"*)
      ok "menu: $k missing + answer n → nothing installed" ;;
    *) bad "menu: $k missing + answer n → $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
done
if grep -q 'bashrc) ' "$TPL" || grep -q '_oc_bashrc()' "$TPL"; then
  ok "menu: ~/.bashrc is reachable from the menu"
else
  bad "menu: no ~/.bashrc entry in the menu"
fi
if grep -qE "^      \[bB\]\)" "$TPL"; then
  ok "menu: b opens the ~/.bashrc options"
else
  bad "menu: no key hint for ~/.bashrc"
fi

# =============================================================================
# 5d. a dead stdin never traps the menu (the /quit bug)
# =============================================================================
# A full-screen agent can hand back a terminal that answers nothing, so `read`
# fails instantly and forever. The menu used to spin on that EOF and never came
# back. It must give up and return instead.
SB5D="$(new_sandbox eof)"
mkdir -p "$SB5D/prefix/bin" "$SB5D/home"
# The EOF path only happens when there is no terminal to re-open: _oc_read_key
# does `exec 0</dev/tty`, so a run inside tmux or any real terminal blocks on a
# key press forever. setsid drops the controlling terminal, which is what a
# full-screen agent leaves behind.
EOF_SETSID=()
command -v setsid >/dev/null 2>&1 && EOF_SETSID=(setsid)
# `timeout` is the real assertion here: a spinning reader burns the CPU forever
# and the suite would never finish. 20 s is far beyond the ~1 s the EOF path
# needs (five failed reads plus the re-open attempts).
out="$(timeout 20 env HOME="$SB5D/home" PREFIX="$SB5D/prefix" PATH="$SB5D/prefix/bin:$PATH" \
  CODEMUX_ROOT="$ROOT" CODEMUX_HOME="$SB5D/state" CODEMUX_ALLOW_NONANDROID=1 \
  OPENCODE_NO_AUTO=1 TMPDIR="$BASE" "${EOF_SETSID[@]}" bash -c '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; HL=""; R=""
    _oc_cursor_show() { :; }
    _oc_cursor_hide() { :; }
    . "$1"
    _oc_items
    _oc_read_key
    printf "first=%s\n" "$KEY"
    _oc_menu_loop
    printf "menu rc=%s\n" "$?"
  ' _ "$TPL" 2>/dev/null </dev/null)"
case "$out" in
  *"first=eof"*"menu rc="*)
    ok "menu: a dead stdin ends the menu instead of spinning" ;;
  *) bad "menu: a dead stdin hangs the menu → $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# =============================================================================
# 5c. the pi module never touches a broken .bashrc
# =============================================================================
SB5C="$(new_sandbox pi-module)"
# A broken file must stay broken through the whole run, and the pi module has to
# leave it alone. The launcher module (skipped below) is the one that repairs
# .bashrc, so nothing in this sandbox can make the file valid again.
printf 'if [ ; then\n' >"$SB5C/home/.bashrc"
# The module looks for free-pi-cli, not for the upstream `pi` bin, so the fake
# has to be named exactly that. It also has to be on PATH: run_cm sets PREFIX
# but not PATH, so without this a CI runner (no npx cache) would resolve
# nothing and the module would take the "not installed" path instead.
printf '#!/bin/sh\n' >"$SB5C/prefix/bin/free-pi-cli"
chmod +x "$SB5C/prefix/bin/free-pi-cli"
run_cm "$SB5C" install --only pi --skip "$SKIP_ONLY_PI" >"$SB5C/out.log" 2>&1 || true
if ! grep -q 'codemux:pi begin' "$SB5C/home/.bashrc"; then
  ok "pi module: a broken .bashrc is left alone"
else
  bad "pi module: appended to an already broken .bashrc"
fi
# Now a valid .bashrc: the alias must appear exactly once, and the next run
# must not add a second block.
printf 'echo keep\n' >"$SB5C/home/.bashrc"
PATH="$SB5C/prefix/bin:$PATH" run_cm "$SB5C" install --only pi --skip "$SKIP_ONLY_PI" >"$SB5C/out2.log" 2>&1 || true
if grep -q 'codemux:pi begin' "$SB5C/home/.bashrc" && grep -q 'alias pi=' "$SB5C/home/.bashrc"; then
  ok "pi module: the alias is added once .bashrc is valid"
else
  bad "pi module: alias not added to a valid .bashrc"
fi
PATH="$SB5C/prefix/bin:$PATH" run_cm "$SB5C" install --only pi --skip "$SKIP_ONLY_PI" >"$SB5C/out3.log" 2>&1 || true
if [ "$(grep -c 'codemux:pi begin' "$SB5C/home/.bashrc")" -eq 1 ]; then
  ok "pi module: idempotent (one alias block)"
else
  bad "pi module: the alias block was duplicated"
fi

# =============================================================================
# 6. update notice: stale cache rows are hidden
# =============================================================================
SB6="$(new_sandbox notice)"
mkdir -p "$SB6/home/.config/codemux" "$SB6/prefix/share/opencode" "$SB6/prefix/share/opencode-v2"
printf '1.19.5' >"$SB6/prefix/share/opencode/VERSION"
printf '2.2.3' >"$SB6/prefix/share/opencode-v2/VERSION"
: >"$SB6/home/.config/codemux/.update-check.stamp" # do not re-check over the network

notice() { # <cache content> → print the notice line
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" PATH="$sb/prefix/bin:$PATH" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
    ACC=""; DIM=""; R=""
    eval "$(cat "$1")"
    _oc_update_notice
  ' _ "$TPL" 2>/dev/null
}

# cache says 2.2.2 → 2.2.3 while 2.2.3 is installed (the state right after an upgrade)
printf 'codemux\t0.6.1\t0.6.1\tok\nopencode-v1\t1.19.5\t1.19.5\tok\nopencode-v2\t2.2.2\t2.2.3\tupdate\n' \
  >"$SB6/home/.config/codemux/update-cache.tsv"
out="$(notice "$SB6")"
if [ -z "$out" ]; then
  ok "notice: stale cache (version already installed) is not shown"
else
  bad "notice: still suggests an update that already finished"
fi

# a genuinely new release → must be shown
printf 'opencode-v2\t2.2.3\t2.2.4\tupdate\n' >"$SB6/home/.config/codemux/update-cache.tsv"
out="$(notice "$SB6")"
case "$out" in
  *"opencode-v2 2.2.4"*) ok "notice: a real update is still shown" ;;
  *) bad "notice: a real update got hidden too" ;;
esac

# no installed VERSION (not detected) → hide nothing
rm -f "$SB6/prefix/share/opencode-v2/VERSION"
out="$(notice "$SB6")"
case "$out" in
  *"opencode-v2 2.2.4"*) ok "notice: undetected version → the row is still shown" ;;
  *) bad "notice: row vanished when the version was undetected" ;;
esac

# an upstream check once failed (status na) → do not lock for 24h, retry within ≤1h
mkdir -p "$SB6/prefix/bin"
cat >"$SB6/prefix/bin/codemux" <<EOS
#!$(command -v bash)
: >"\$HOME/retry-marker"
EOS
chmod 700 "$SB6/prefix/bin/codemux"
printf 'codemux\t0.6.3\t-\tna\nopencode-v1\t1.19.5\t-\tna\nopencode-v2\t2.2.3\t-\tna\n' \
  >"$SB6/home/.config/codemux/update-cache.tsv"
touch -t "$(date -d '2 hours ago' +%Y%m%d%H%M)" "$SB6/home/.config/codemux/.update-check.stamp"
rm -f "$SB6/home/retry-marker"
notice "$SB6" >/dev/null
sleep 0.3
[ -f "$SB6/home/retry-marker" ] &&
  ok "notice: a 'na' result triggers a re-check within 1h" ||
  bad "notice: a 'na' result is not re-checked"

# conversely: a complete result (no na) still waits 24 hours
printf 'codemux\t0.6.3\t0.6.3\tok\nopencode-v2\t2.2.3\t2.2.5\tupdate\n' \
  >"$SB6/home/.config/codemux/update-cache.tsv"
touch -t "$(date -d '2 hours ago' +%Y%m%d%H%M)" "$SB6/home/.config/codemux/.update-check.stamp"
rm -f "$SB6/home/retry-marker"
notice "$SB6" >/dev/null
sleep 0.3
[ ! -f "$SB6/home/retry-marker" ] &&
  ok "notice: a complete cache does not trigger excessive re-checks" ||
  bad "notice: a complete cache re-checks too soon"

rm -rf "$SANDBOX_ROOT"
printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
