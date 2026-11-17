#!/usr/bin/env bash
# tests/launcher-memory.sh — test the launcher, dotfiles, and memory modules (M4).
# Full sandbox: dedicated HOME, PREFIX, CODEMUX_HOME. The system is NOT touched.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
# The wrapper version lives in lib/modules/memory.sh: derive it, so bumping the
# wrapper only has to happen in one place.
MEM_VER="$(sed -n 's/^CODEMUX_MEMORY_WRAPPER_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/modules/memory.sh")"
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
# 0. version markers: one number, two files
# =============================================================================
# Every managed block carries its version twice — a constant in lib/ and a line
# in the template. Bumping one and not the other makes the probe report
# "outdated" forever (install rewrites the block, the probe stays unhappy), so
# the pair is checked here instead of being trusted.
TPL_VER="$(sed -n 's/^# codemux:launcher version \([0-9]*\)$/\1/p' "$ROOT/templates/bashrc-block.sh" | head -n 1)"
LIB_VER="$(sed -n 's/^CODEMUX_LAUNCHER_BLOCK_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/modules/launcher.sh")"
if [ -n "$TPL_VER" ] && [ "$TPL_VER" = "$LIB_VER" ]; then
  ok "launcher block version: template $TPL_VER = module $LIB_VER"
else
  bad "launcher block version mismatch: template '${TPL_VER:-none}' vs module '${LIB_VER:-none}'"
fi
TPL_MENU_VER="$(sed -n 's/^CM_MENU_VERSION="\(.*\)"$/\1/p' "$ROOT/templates/menu.sh")"
LIB_MENU_VER="$(sed -n 's/^CODEMUX_MENU_SCRIPT_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/modules/launcher.sh")"
if [ -n "$TPL_MENU_VER" ] && [ "$TPL_MENU_VER" = "$LIB_MENU_VER" ]; then
  ok "menu script version: template $TPL_MENU_VER = module $LIB_MENU_VER"
else
  bad "menu script version mismatch: template '${TPL_MENU_VER:-none}' vs module '${LIB_MENU_VER:-none}'"
fi
# The wrapper body used to hard-code its own version line; it is printed from
# CODEMUX_MEMORY_WRAPPER_VERSION now, and that has to keep holding.
body_ver="$(bash -c '. "$1/lib/common.sh"; . "$1/lib/modules/memory.sh"; codemux_memory_wrapper_body' _ "$ROOT" 2>/dev/null |
  grep -c "^# codemux:memory version $MEM_VER$")"
if [ "${body_ver:-0}" -eq 1 ]; then
  ok "memory wrapper body carries version $MEM_VER"
else
  bad "memory wrapper body version marker ($body_ver occurrences of $MEM_VER)"
fi

# A lock directory without a pid file is debris (interrupted install, full disk).
# It must be discarded, not honoured: otherwise every later install refuses to
# start with "another process is running: none".
LOCK_SB="$SANDBOX_ROOT/lock"
mkdir -p "$LOCK_SB/home/.config/codemux/lock"
if env -i HOME="$LOCK_SB/home" PATH="$PATH" PREFIX="$LOCK_SB/prefix" CODEMUX_ROOT="$ROOT" \
  bash -c '. "$CODEMUX_ROOT/lib/common.sh"; . "$CODEMUX_ROOT/lib/state.sh"; codemux_lock_acquire' >/dev/null 2>&1; then
  ok "lock: a pid-less lock directory is discarded"
else
  bad "lock: a pid-less lock directory blocks every later install"
fi

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
if grep -q '_oc_tmux_enter()' "$rc_file" && ! grep -q '_oc_banner()' "$rc_file" &&
  [ -f "$SB/home/.config/codemux/menu.sh" ] &&
  grep -q 'CM_MENU_VERSION' "$SB/home/.config/codemux/menu.sh"; then
  ok "fresh: .bashrc auto-starts tmux, the menu is a separate script"
else
  bad "fresh: tmux auto-start missing or the menu is still in .bashrc"
fi
if grep -q '_oc_refresh_digest()' "$rc_file"; then ok "fresh: digest wrapper present"; else bad "fresh: digest wrapper missing"; fi

# The wrapper has to put the terminal back after EVERY agent run, not only a
# failed one: a clean /exit can leave raw termios, and the shell then looks
# frozen — keys arrive, nothing echoes (V1 → "Shell only" froze Termux). Gating
# the repair on a non-zero exit code is exactly what failed.
if grep -q "codemux:memory version $MEM_VER" "$rc_file" &&
  [ "$(grep -c 'codemux:memory begin' "$rc_file")" -eq 1 ]; then
  ok "fresh: wrapper is version $MEM_VER and written exactly once"
else
  bad "fresh: wrapper block is missing, duplicated or not version $MEM_VER"
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
pi_ver="$(HOME="$SB/home" bash -c 'eval "$(sed -n "/^_cm_ver()/,/^}/p" "$1")"; _cm_ver pi' \
  _ "$SB/home/.config/codemux/menu.sh" 2>/dev/null)"
if [ "$pi_ver" = "9.9.9" ]; then
  ok "fresh: _cm_ver pi reads the npx manifest (9.9.9)"
else
  bad "fresh: _cm_ver pi = '$pi_ver' (expected 9.9.9)"
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
st = {m["module"]: m["status"] for m in d["modules"]}
for k in ("launcher", "dotfiles", "memory"):
    assert st[k] == "OK", (k, st[k])
PY
then
  ok "fresh: check → launcher/dotfiles/memory OK"
else
  bad "fresh: check still not OK ($(python3 -c '
import json;d=json.load(open("'"$SB"'/check.json"));print({m["module"]:m["status"] for m in d["modules"]})' 2>/dev/null))"
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
if [ "$(grep -c "codemux:memory version $MEM_VER" "$legacy_rc")" -eq 1 ] &&
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
if [ "$(grep -c '_oc_tmux_enter()' "$rc3")" -eq 1 ] &&
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
# 5. the shell startup block is tiny; the whole menu lives in its own script
# =============================================================================
# ~/.bashrc is sourced in front of every prompt, so it must not carry the menu
# and must not start an agent to read a version. Everything moved to
# ~/.config/codemux/menu.sh, which tmux runs in every tab.
TPL="$ROOT/templates/bashrc-block.sh"
MENU="$ROOT/templates/menu.sh"
SB5="$(new_sandbox menu-items)"

if ! grep -q '_oc_banner()' "$TPL" && ! grep -q '_oc_menu_loop()' "$TPL" &&
  grep -q '_oc_tmux_enter()' "$TPL" && grep -q 'tmux new-session -d -s main' "$TPL" &&
  grep -q 'exec tmux attach-session -t main' "$TPL"; then
  ok "block: .bashrc only auto-starts tmux, the menu is gone from it"
else
  bad "block: the menu is still in .bashrc or the tmux auto-start is missing"
fi
block_lines="$(wc -l <"$TPL")"
if [ "$block_lines" -le 60 ]; then
  ok "block: the startup block is $block_lines lines"
else
  bad "block: the startup block is $block_lines lines (target <= 60)"
fi
if grep -q 'default-command' "$TPL" && grep -q 'OPENCODE_NO_AUTO' "$TPL" &&
  grep -q 'TMUX' "$TPL"; then
  ok "block: new tabs reuse the menu (default-command) and startup can be skipped"
else
  bad "block: default-command / skip gate / tmux guard missing"
fi
# The block never starts an agent, so a version is never read on startup.
if ! grep -q 'opencode --version' "$TPL" && ! grep -q 'free-pi-cli --version' "$TPL"; then
  ok "block: no agent binary is started from .bashrc"
else
  bad "block: .bashrc still starts an agent"
fi
# The detached session must be created at the attaching terminal's size: a
# detached session defaults to 80x24, and attaching a differently sized
# Termux window then resizes the pane, which pushes the just-drawn menu into
# history (blank screen, no `Choice:` prompt) on first load.
if grep -q 'new-session -d -s main' "$TPL" &&
  grep -q -- '-x "${COLUMNS:-80}"' "$TPL" &&
  grep -q -- '-y "$(( ${LINES:-25} - 1 ))"' "$TPL"; then
  ok "block: the detached session is sized to the attaching terminal (status row spared)"
else
  bad "block: new-session is not sized (-x/-y-1) — first-load menu blanks on attach"
fi
# The commands the rest of the system relies on: pi/memory wrappers call
# _oc_tty_fix, and `menu` / `version` / `fixterm` stay available.
for fn in _oc_tty_fix fixterm menu version; do
  grep -q "^$fn() {" "$TPL" || fn_gap="$fn_gap $fn"
done
if [ -z "${fn_gap:-}" ] && grep -q -- '--repair' "$TPL" && grep -q -- '--versions' "$TPL"; then
  ok "block: _oc_tty_fix, fixterm, menu and version delegate to the script"
else
  bad "block: helper commands missing:${fn_gap:- --repair/--versions}"
fi

# --- the menu script itself --------------------------------------------------
if grep -q 'read -e -r -p "$prompt" choice' "$MENU" && ! grep -q 'read -rsn1' "$MENU"; then
  ok "menu: one typed line per answer, arrows handled by readline, prompt owned by readline"
else
  bad "menu: arrow keys would leak raw ESC[A bytes or the prompt is not readline-owned (need read -e -p)"
fi
if grep -q '█▀▀█' "$MENU" && grep -q 'Termux · Android arm64' "$MENU"; then
  ok "menu: banner kept (art + version line)"
else
  bad "menu: banner missing"
fi
if ! grep -q '\$(opencode --version' "$MENU" && ! grep -q 'timeout 8 opencode' "$MENU" &&
  grep -q 'share/opencode/VERSION' "$MENU" && grep -q 'dpkg-query' "$MENU"; then
  ok "menu: versions come from files, the agent binary is never started"
else
  bad "menu: the version probe still runs the agent binary"
fi
if grep -q 'MouseDown1Status' "$MENU" && grep -q 'kill-window' "$MENU"; then
  bad "menu: tab-strip mouse bindings came back"
else
  ok "menu: no tab-strip mouse bindings (tmux owns the strip)"
fi

# rows: always the same five, a missing agent marked
menu_keys() { # <sandbox> → keys of the menu rows
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"
      . "$1"
      _cm_items
      printf "%s" "${_CM_KEYS[*]}"
    ' _ "$MENU" "$sb/prefix/bin" 2>/dev/null
}
menu_descs() { # <sandbox> → descriptions of the menu rows
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"
      . "$1"
      _cm_items
      printf "%s" "${_CM_DESCS[*]}"
    ' _ "$MENU" "$sb/prefix/bin" 2>/dev/null
}
if [ "$(menu_keys "$SB5")" = "v1 v2 pi shell quit" ]; then
  ok "menu: five rows (v1 v2 pi shell quit)"
else
  bad "menu: rows are '$(menu_keys "$SB5")'"
fi
case "$(menu_descs "$SB5")" in
  *"not installed"*) ok "menu: a missing agent is marked not installed" ;;
  *) bad "menu: a missing agent is not marked" ;;
esac

# banner meta line: only installed agents are listed
meta="$(env HOME="$SB5/home" PREFIX="$SB5/prefix" NO_COLOR=1 \
  OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c 'command() { return 1; }; type() { return 1; }; . "$1"; _cm_colors; _cm_banner' \
  _ "$MENU" 2>/dev/null)"
case "$meta" in
  *"no agent yet"*) ok "menu: nothing installed → banner says no agent yet" ;;
  *) bad "menu: banner meta line is wrong → $(printf '%s' "$meta" | tr '\n' ' ')" ;;
esac
# with an agent installed the meta line shows its version, read from a file
printf '#!/bin/sh\n' >"$SB5/prefix/bin/opencode-v2"
chmod +x "$SB5/prefix/bin/opencode-v2"
mkdir -p "$SB5/prefix/share/opencode-v2"
printf '2.3.0' >"$SB5/prefix/share/opencode-v2/VERSION"
meta="$(env HOME="$SB5/home" PREFIX="$SB5/prefix" NO_COLOR=1 \
  OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c 'PATH="$2:$PATH"; . "$1"; _cm_colors; _cm_banner' \
  _ "$MENU" "$SB5/prefix/bin" 2>/dev/null)"
case "$meta" in
  *"v2 2.3.0"*) ok "menu: an installed agent is listed with its version" ;;
  *) bad "menu: installed agent missing from the banner → $(printf '%s' "$meta" | tr '\n' ' ')" ;;
esac

# --versions: three lines, read from files
out="$(env HOME="$SB5/home" PREFIX="$SB5/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" \
  bash "$MENU" --versions 2>/dev/null)"
case "$out" in
  *"OpenCode V1:"*"OpenCode V2:"*"Free-pi (Pi):"*)
    ok "menu: --versions prints the three agents" ;;
  *) bad "menu: --versions output is '$(printf '%s' "$out" | tr '\n' '|')'" ;;
esac

# =============================================================================
# 5d. the menu never traps the caller (dead stdin, bad answer, missing agent)
# =============================================================================
SB5D="$(new_sandbox eof)"
mkdir -p "$SB5D/prefix/bin" "$SB5D/home"
# The menu answers with a typed number, so a dead stdin (what a full-screen agent
# can leave behind) must end it instead of looping. `timeout` is the assertion: a
# reader that spins on EOF burns the CPU and the suite would never finish.
menu_with() { # <stdin text> → "rc=<status>"
  local input="$1"
  printf '%b' "$input" | timeout 20 env -u TMUX -u TMUX_PANE -u XDG_CONFIG_HOME \
    HOME="$SB5D/home" PREFIX="$SB5D/prefix" \
    PATH="$SB5D/prefix/bin:$PATH" CODEMUX_ROOT="$ROOT" CODEMUX_HOME="$SB5D/state" \
    CODEMUX_ALLOW_NONANDROID=1 OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
    bin="$2/prefix/bin"
    # The host really has opencode/pi installed: hide them, so the "missing
    # agent" row is exercised instead of starting a real agent. `command -v`
    # AND `type -P` both need the override: the menu resolves agents through
    # `type -P` (a function in .bashrc must never count as an install), but a
    # binary the TEST puts into the sandbox prefix must stay reachable.
    command() {
      if [ "$1" = "-v" ]; then
        case "$2" in opencode | opencode-v2 | pi | free-pi-cli) return 1 ;; esac
      fi
      builtin command "$@"
    }
    type() {
      if [ "${1:-}" = "-P" ]; then
        case "${2:-}" in
          opencode | opencode-v2 | pi | free-pi-cli) [ -x "$bin/$2" ] || return 1 ;;
        esac
      fi
      builtin type "$@"
    }
    . "$1"
    _cm_menu_loop
    printf "menu rc=%s\n" "$?"
  ' _ "$MENU" "$SB5D" 2>/dev/null
}
out="$(menu_with '')"
case "$out" in
  *"menu rc=1"*)
    ok "menu: a dead stdin ends the menu instead of spinning" ;;
  *) bad "menu: a dead stdin hangs the menu → $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
out="$(menu_with '4\n')"
case "$out" in
  *"menu rc=0"*)
    ok "menu: typing 4 (Shell only) hands the pane back without exec-ing a shell" ;;
  *) bad "menu: typing a number did not run the row → $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
out="$(menu_with 'q\n')"
case "$out" in
  *"menu rc=1"*)
    ok "menu: typing q quits" ;;
  *) bad "menu: q does not quit → $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
out="$(menu_with '99\nx\n')"
case "$out" in
  *"type a number from 1 to"*)
    ok "menu: a bad answer is rejected without starting anything" ;;
  *) bad "menu: a bad answer was not rejected" ;;
esac
# A 25-digit number overflows `[`'s integer parse; it must get the same
# rejection notice as any other junk, not be swallowed silently. The trailing
# q must still quit, proving the loop did not derail.
out="$(menu_with '99999999999999999999999999\nq\n')"
case "$out" in
  *"type a number from 1 to"*"menu rc=1"*)
    ok "menu: an overflowing number is rejected like any other junk" ;;
  *) bad "menu: an overflowing number was swallowed silently" ;;
esac
# Ctrl+C must cancel the answer, not kill the tab. On a real tty a SIGINT
# kills a bash whose `read` has no trap armed (a fifo kill -INT does NOT
# reproduce this: bash defers the signal there), so drive the menu on a pty
# and send a real ^C, exactly like the terminal does.
intpy="$BASE/menu-int.py"
cat >"$intpy" <<'PYEOF'
import os, pty, re, select, sys, time, shutil
menu, home, prefix, state, root = sys.argv[1:6]
env = dict(os.environ)
for k in ("TMUX", "TMUX_PANE", "XDG_CONFIG_HOME"):
    env.pop(k, None)
env.update(HOME=home, PREFIX=prefix, CODEMUX_ROOT=root, CODEMUX_HOME=state,
           CODEMUX_ALLOW_NONANDROID="1", OPENCODE_NO_AUTO="1")
pid, fd = pty.fork()
if pid == 0:
    # menu path must be $1, never $0: menu.sh auto-runs when $0 equals its
    # own BASH_SOURCE, which would nest a second menu loop inside the test.
    os.execve(shutil.which("bash"), ["bash", "-c",
        'C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""; . "$1"; '
        '_cm_menu_loop; printf "\\nMENU-INT-EXIT rc=%s\\n" "$?"', "_", menu], env)
buf = b""

def clean():
    return re.sub(rb"\x1b\[[0-9;]*m", b"", buf)

def drain(secs):
    """Read the pty for up to `secs`; False once the child is gone."""
    global buf
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                return False
            if not d:
                return False
            buf += d
    return True

end = time.time() + 10
while time.time() < end:
    if not drain(0.3):
        break
    if b"Choice" in clean():
        break
else:
    print("NO-PROMPT")
    sys.exit(1)
buf = b""
os.write(fd, b"\x03")            # a real ^C: the tty line discipline sends SIGINT
time.sleep(0.6)
if os.waitpid(pid, os.WNOHANG)[0] != 0:
    print("DIED-ON-INT")
    sys.exit(2)
os.write(fd, b"q\r")             # pty Enter is \r; icrnl turns it into \n
deadline = time.time() + 10
while time.time() < deadline:
    # check the buffer BEFORE acting on EOF: the child prints MENU-INT-EXIT
    # and exits immediately, so the next drain often reports EOF first
    got = drain(0.3)
    if b"MENU-INT-EXIT" in buf:
        sys.exit(0 if b"rc=1" in buf else 4)
    if not got:
        break
print("NO-EXIT")
sys.exit(5)
PYEOF
intrc=0
timeout 30 python3 "$intpy" "$MENU" "$SB5D/home" "$SB5D/prefix" \
  "$SB5D/state" "$ROOT" >"$BASE/menu-int.out" 2>&1 || intrc=$?
case "$intrc" in
  0)
    ok "menu: Ctrl+C cancels the answer, the menu redraws and quits cleanly" ;;
  2)
    bad "menu: Ctrl+C killed the whole menu ($(cat "$BASE/menu-int.out"))" ;;
  *)
    bad "menu: Ctrl+C flow broken rc=$intrc ($(cat "$BASE/menu-int.out"))" ;;
esac
rm -f "$intpy" "$BASE/menu-int.out"
# a missing agent asks before anything is downloaded
out="$(menu_with '1\nn\n')"
case "$out" in
  *"is not installed"*"Install it now? [y/N]"*)
    ok "menu: choosing a missing agent asks before installing" ;;
  *) bad "menu: missing agent → $(printf '%s' "$out" | tr '\n' ' ' | tail -c 200)" ;;
esac
case "$out" in
  *"is not installed — codemux install --only v1"*)
    ok "menu: answering n keeps a notice inside the menu" ;;
  *) bad "menu: answering n left no notice → $(printf '%s' "$out" | tr '\n' ' ' | tail -c 200)" ;;
esac
# answering y installs only that component, then puts the saved component list
# back so the other agent does not turn into SKIP in `codemux check`. The stub
# really creates the binary: the menu verifies the agent exists before it may
# claim "installed" (an installer can exit 0 without producing anything).
stub="$SB5D/prefix/bin/codemux"
mkdir -p "$SB5D/prefix/bin" "$SB5D/state"
{
  printf '#!%s\n' "$(command -v bash)"
  printf 'printf "%%s\\n" "$*" >>%s\n' "$SB5D/install.args"
  printf '[ "$4" = v1 ] && printf "#!/bin/sh\\necho v1\\n" >"%s/prefix/bin/opencode" && chmod +x "%s/prefix/bin/opencode"\n' "$SB5D" "$SB5D"
  printf 'exit 0\n'
} >"$stub"
chmod +x "$stub"
printf 'v1 v2\n' >"$SB5D/state/components"
out="$(menu_with '1\ny\n')"
args="$(cat "$SB5D/install.args" 2>/dev/null)"
comps_after="$(cat "$SB5D/state/components" 2>/dev/null)"
if [ "$args" = "install --yes --only v1" ]; then
  ok "menu: answering y installs only the chosen component"
else
  bad "menu: installer called with '$args'"
fi
if [ "$comps_after" = "v1 v2" ]; then
  ok "menu: the install keeps the saved component list"
else
  bad "menu: component list after install = '$comps_after'"
fi
case "$out" in
  *"OpenCode V1 installed"*)
    ok "menu: a finished install is reported in the menu" ;;
  *) bad "menu: no install result → $(printf '%s' "$out" | tr '\n' ' ' | tail -c 200)" ;;
esac
# the launch record must end at the real outcome: a record stuck at MISSING
# made `codemux logs` report a failure forever after a successful install
mlogdir="$SB5D/home/.config/codemux/logs"
last_v1="$(grep ' OpenCode V1 ' "$mlogdir/menu.log" 2>/dev/null | tail -n 1)"
case "$last_v1" in
  *"rc=0"*" OK "*) ok "menu log: a successful install closes its record as OK, not MISSING" ;;
  *) bad "menu log: install record is wrong → $(tr '\n' '|' <"$mlogdir/menu.log" 2>/dev/null)" ;;
esac
if [ "$(ls -1 "$mlogdir"/menu-*.log 2>/dev/null | wc -l)" -eq 1 ] &&
  grep -q 'status:   MISSING' "$mlogdir"/menu-*.log 2>/dev/null; then
  ok "menu log: only the declined install keeps a detail file (MISSING)"
else
  bad "menu log: detail files after install = $(ls -1 "$mlogdir"/menu-*.log 2>/dev/null | tr '\n' ' ')"
fi
rm -f "$stub" "$SB5D/install.args" "$SB5D/state/components"
# quitting inside tmux must close the session, not leave a dead pane behind
if grep -q 'tmux kill-session' "$MENU" && grep -q 'kill-session -t "\$(tmux display-message' "$MENU"; then
  ok "menu: Quit closes the tmux session it runs in"
else
  bad "menu: Quit does not close its session"
fi

# The terminal reset stays: it is what unfreezes a pane after an agent exits.
tty_modes_missing=""
for mode in '\007' '\033\\' '\033[?2026l' '\033[?1049l' '\033[?1002l' \
  '\033[?2004l' '\033[r' '\033[?6l' '\033[?7h' '\033(B' '\033[!p' '\017'; do
  grep -qF "$mode" "$MENU" || tty_modes_missing="$tty_modes_missing $mode"
done
if [ -z "$tty_modes_missing" ]; then
  ok "menu: the pane reset keeps every mode it releases"
else
  bad "menu: pane reset is incomplete, missing:$tty_modes_missing"
fi
if grep -q '^_cm_tty_fix() {' "$MENU" &&
  grep -q '^  _cm_tty_fix$' "$MENU" && ! grep -q 'print.*\\033c' "$MENU"; then
  ok "menu: the pane is repaired after a component, without a full RIS"
else
  bad "menu: pane repair missing after a component (or RIS is back)"
fi

# =============================================================================
# 5e. every menu launch is logged; a failure keeps the whole story
# =============================================================================
# Master's rule: when a row misbehaves (a broken ad card, an agent that dies at
# once) the reason must be on disk, not guessed later. menu.log gets one line
# per launch; a failed launch also keeps a detail file.
SB5E="$(new_sandbox menu-log)"
mkdir -p "$SB5E/home" "$SB5E/logs"
printf '#!/bin/sh\necho "error: ad card failed to render"\nexit 3\n' >"$SB5E/prefix/bin/opencode"
printf '#!/bin/sh\nexit 0\n' >"$SB5E/prefix/bin/opencode-v2"
chmod +x "$SB5E/prefix/bin/opencode" "$SB5E/prefix/bin/opencode-v2"
menu_logged() { # <sandbox> <stdin text> → menu output
  local sb="$1" input="$2"
  printf '%b' "$input" | timeout 25 env -u TMUX -u TMUX_PANE \
    HOME="$sb/home" PREFIX="$sb/prefix" PATH="$sb/prefix/bin:$PATH" \
    CODEMUX_LOG_DIR="$sb/logs" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" \
    bash -c 'C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
    bin="$2/prefix/bin"
    command() {
      if [ "$1" = "-v" ]; then
        case "$2" in opencode | opencode-v2 | pi | free-pi-cli) return 1 ;; esac
      fi
      builtin command "$@"
    }
    type() {
      if [ "${1:-}" = "-P" ]; then
        case "${2:-}" in
          opencode | opencode-v2 | pi | free-pi-cli) [ -x "$bin/$2" ] || return 1 ;;
        esac
      fi
      builtin type "$@"
    }
    . "$1"
    _cm_menu_loop
    printf "menu rc=%s\n" "$?"' _ "$MENU" "$sb" 2>/dev/null
}
menu_logged "$SB5E" '1\nq\n' >"$SB5E/fail.out" 2>&1 || true
menu_logged "$SB5E" '2\nq\n' >"$SB5E/ok.out" 2>&1 || true
if [ -f "$SB5E/logs/menu.log" ] && [ "$(wc -l <"$SB5E/logs/menu.log")" -eq 2 ]; then
  ok "menu log: one line per launch (both rows recorded)"
else
  bad "menu log: expected 2 lines in menu.log, got $(wc -l <"$SB5E/logs/menu.log" 2>/dev/null || echo 0)"
fi
if grep -q 'FAILED' "$SB5E/logs/menu.log" && grep -q ' OK ' "$SB5E/logs/menu.log"; then
  ok "menu log: a broken row is marked FAILED, a clean row OK"
else
  bad "menu log: status column is wrong → $(tr '\n' '|' <"$SB5E/logs/menu.log" 2>/dev/null)"
fi
detail="$(ls -1 "$SB5E/logs"/menu-*.log 2>/dev/null | head -n 1)"
if [ -n "$detail" ] && grep -q 'rc:       3' "$detail" && grep -q 'status:   FAILED' "$detail"; then
  ok "menu log: the failed launch keeps a detail file with its exit code"
else
  bad "menu log: no usable detail file (found '${detail:-none}')"
fi
if [ "$(ls -1 "$SB5E/logs"/menu-*.log 2>/dev/null | wc -l)" -eq 1 ]; then
  ok "menu log: a clean launch deletes its detail file (no clutter)"
else
  bad "menu log: a clean launch left a detail file behind"
fi
case "$(cat "$SB5E/fail.out" 2>/dev/null)" in
  *"exited with 3"*)
    ok "menu log: the failure names the log on screen" ;;
  *) bad "menu log: the failure did not point at its log" ;;
esac
# The loop clears the screen on every answer, so the notice must live in the rows
# (otherwise it is wiped before anybody reads it).
notice="$(env HOME="$SB5E/home" PREFIX="$SB5E/prefix" TMPDIR="$BASE" bash -c '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
    . "$1"
    _CM_LASTLOG="/some/menu-1.log"
    _cm_items
    _cm_list
  ' _ "$MENU" 2>/dev/null)"
case "$notice" in
  *"last launch failed"*"codemux logs --last"*)
    ok "menu log: the rows carry the notice after a failure" ;;
  *) bad "menu log: no notice in the rows → $(printf '%s' "$notice" | tr '\n' '|' | tail -c 90)" ;;
esac
cap_line="$(awk '/^_cm_launch\(\) \{/{f=1} f && /_cm_capture_start/{print NR; exit}' "$MENU")"
fin_line="$(awk '/^_cm_launch\(\) \{/{f=1} f && /^  _cm_log_finish/{print NR; exit}' "$MENU")"
fix_line="$(awk '/^_cm_launch\(\) \{/{f=1} f && /^  _cm_tty_fix$/{print NR; exit}' "$MENU")"
if [ -n "$cap_line" ] && [ -n "$fin_line" ] && [ -n "$fix_line" ] &&
  [ "$cap_line" -lt "$fin_line" ] && [ "$fin_line" -lt "$fix_line" ]; then
  ok "menu log: the pane is read (and closed) before it is repaired"
else
  bad "menu log: order capture=$cap_line finish=$fin_line repair=$fix_line (capture<finish<repair required)"
fi
if grep -q 'pipe-pane' "$MENU" && grep -q '_cm_pane_tail' "$MENU"; then
  ok "menu log: pane output is copied with pipe-pane and made printable"
else
  bad "menu log: the pane stream is never captured"
fi
# The tail is read by a human later: escape sequences must be gone, the text kept.
printf '\033[!p\033[2J\033[H\033]0;title\007\033[?25lNo command opencode found\r\n' \
  >"$SB5E/raw.txt"
stripped="$(env HOME="$SB5E/home" PREFIX="$SB5E/prefix" TMPDIR="$BASE" bash -c '
    . "$1"
    _cm_pane_tail "$2" 120
  ' _ "$MENU" "$SB5E/raw.txt" 2>/dev/null)"
case "$stripped" in
  "No command opencode found")
    ok "menu log: the pane tail drops escape sequences and keeps the message" ;;
  *) bad "menu log: pane tail is '$(printf '%s' "$stripped" | tr '\n' '|' | tail -c 80)'" ;;
esac
# a row whose binary is missing is logged too: that is the other way a row fails
SB5F="$(new_sandbox menu-log-missing)"
mkdir -p "$SB5F/home" "$SB5F/logs"
menu_logged "$SB5F" '1\nq\n' >"$SB5F/out" 2>&1 || true
if grep -q 'rc=127' "$SB5F/logs/menu.log" 2>/dev/null &&
  grep -q 'status:   MISSING' "$SB5F/logs"/menu-*.log 2>/dev/null; then
  ok "menu log: choosing a missing agent is logged as MISSING"
else
  bad "menu log: a missing agent left no log"
fi
# reading it back: `codemux logs` — the audit entry point
dir_out="$(CODEMUX_LOG_DIR="$SB5E/logs" run_cm "$SB5E" logs --dir 2>/dev/null)"
if [ "$dir_out" = "$SB5E/logs" ]; then
  ok "logs command: --dir prints the log directory"
else
  bad "logs command: --dir printed '$dir_out'"
fi
last_out="$(CODEMUX_LOG_DIR="$SB5E/logs" run_cm "$SB5E" logs --last 2>/dev/null)"
case "$last_out" in
  *"rc:       3"*"pane tail"*) ok "logs command: --last shows the failed launch" ;;
  *"rc:       3"*) ok "logs command: --last shows the failed launch" ;;
  *) bad "logs command: --last printed '$(printf '%s' "$last_out" | tr '\n' '|' | tail -c 120)'" ;;
esac
sum_out="$(CODEMUX_LOG_DIR="$SB5E/logs" run_cm "$SB5E" logs 2>/dev/null)"
case "$sum_out" in
  *"newest failed launch"*) ok "logs command: the summary points at the newest failure" ;;
  *) bad "logs command: summary is '$(printf '%s' "$sum_out" | tr '\n' '|' | tail -c 120)'" ;;
esac
default_dir="$(run_cm "$SB5E" logs --dir 2>/dev/null)"
# Same order the code uses: CODEMUX_LOG_DIR, then XDG_CONFIG_HOME, then HOME.
# CI runners set XDG_CONFIG_HOME, so hard-coding the HOME path breaks there.
want_default="${XDG_CONFIG_HOME:-$SB5E/home/.config}/codemux/logs"
if [ "$default_dir" = "$want_default" ]; then
  ok "logs command: the default directory sits next to the menu script"
else
  bad "logs command: default directory is '$default_dir' (want '$want_default')"
fi
xdg_out="$(XDG_CONFIG_HOME="$SB5E/xdg" run_cm "$SB5E" logs --dir 2>/dev/null)"
if [ "$xdg_out" = "$SB5E/xdg/codemux/logs" ]; then
  ok "logs command: XDG_CONFIG_HOME wins over HOME"
else
  bad "logs command: XDG default '$xdg_out'"
fi

# 5e-2. An answer that is not a row number must stay readable. The loop clears
# the screen before every answer, so a plain printf is wiped before it is seen:
# the hint has to travel through _CM_NOTICE, which _cm_list prints below the
# rows (verified on a real screen with tmux: a bare printf was invisible).
SB5G="$(new_sandbox menu-hint)"
mkdir -p "$SB5G/home" "$SB5G/logs"
if awk '/^_cm_menu_loop\(\) \{/{f=1} f && /_CM_NOTICE="type a number/{print; exit}' \
  "$MENU" | grep -q . &&
  ! awk '/^_cm_menu_loop\(\) \{/{f=1} f && /printf .*type a number/{print; exit}' \
    "$MENU" | grep -q .; then
  ok "menu: a wrong answer is reported in the rows, not printed and wiped"
else
  bad "menu: the invalid-input hint is printed before the redraw (invisible on screen)"
fi
# ... and the row printer really shows it.
hint_row="$(env HOME="$SB5G/home" PREFIX="$SB5G/prefix" TMPDIR="$BASE" bash -c '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
    . "$1"
    _CM_NOTICE="type a number from 1 to 5, or q"
    _cm_items
    _cm_list
  ' _ "$MENU" 2>/dev/null)"
case "$hint_row" in
  *"type a number from 1 to 5, or q"*)
    ok "menu: the hint is printed under the rows and survives the redraw" ;;
  *) bad "menu: no hint under the rows → $(printf '%s' "$hint_row" | tr '\n' '|' | tail -c 90)" ;;
esac

# 5e-3. A clean exit whose pane happens to mention an error is a WARN, not a
# failure: an agent pane is a conversation, so "error" appears in healthy runs
# (measured: a 32-minute free-pi session, rc=0, was logged FAILED).
SB5H="$(new_sandbox menu-warn)"
mkdir -p "$SB5H/home" "$SB5H/logs"
warn_out="$(env HOME="$SB5H/home" PREFIX="$SB5H/prefix" TMPDIR="$BASE" \
  CODEMUX_LOG_DIR="$SB5H/logs" bash -c '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
    . "$1"
    _CM_ROW=pi; _CM_NAME="Free-pi (Pi)"
    _cm_log_start pi "Free-pi (Pi)" /bin/true
    printf "the model said: there was an error earlier, fixed now\n" >"$_CM_RAW"
    _CM_PIPED=0; _CM_PIPE_OPEN=0
    _cm_log_finish 0 failed
    printf "lastlog=%s\n" "${_CM_LASTLOG:-none}"
  ' _ "$MENU" 2>&1)"
if grep -q 'pi .*rc=0 .* WARN ' "$SB5H/logs/menu.log" 2>/dev/null &&
  ! grep -q 'FAILED' "$SB5H/logs/menu.log" 2>/dev/null; then
  ok "menu log: a clean run is never FAILED just because its pane mentions an error"
else
  bad "menu log: warn path wrong → $(tr '\n' '|' <"$SB5H/logs/menu.log" 2>/dev/null | tail -c 90)"
fi
case "$warn_out" in
  *lastlog=none*) ok "menu log: a WARN keeps its detail file but does not nag the menu" ;;
  *) bad "menu log: a WARN nagged the menu → $warn_out" ;;
esac
# ... and that WARN record is not reported as the newest failure either.
warn_sum="$(CODEMUX_LOG_DIR="$SB5H/logs" run_cm "$SB5H" logs 2>/dev/null)"
case "$warn_sum" in
  *"newest failed launch"*) bad "logs command: a WARN record was reported as a failure" ;;
  *"no failed launch recorded"*) ok "logs command: a WARN record is not a failure" ;;
  *) bad "logs command: warning summary is '$(printf '%s' "$warn_sum" | tr '\n' '|' | tail -c 90)'" ;;
esac

# 5e-4. A tab killed mid-launch never writes its finish record. That leftover
# must be closed (INTERRUPTED) instead of looking like the newest failure
# forever, and a record that still says "running" must never be reported.
SB5I="$(new_sandbox menu-orphan)"
mkdir -p "$SB5I/home" "$SB5I/logs"
# 99999 is not a live pid here, so this record belongs to a killed tab.
printf 'codemux menu launch\nstatus:   running\nstarted:  2020-01-01T00:00:00+0700\nrow:      pi\nname:     Free-pi (Pi)\n---\n' \
  >"$SB5I/logs/menu-20200101-000000-99999-1.log"
orphan_sum="$(CODEMUX_LOG_DIR="$SB5I/logs" run_cm "$SB5I" logs 2>/dev/null)"
case "$orphan_sum" in
  *"newest failed launch"*) bad "logs command: an unfinished (running) record was reported as a failure" ;;
  *) ok "logs command: a record that is still running is not a failure" ;;
esac
env HOME="$SB5I/home" PREFIX="$SB5I/prefix" TMPDIR="$BASE" bash -c '
    . "$1"
    _cm_log_reap "$2"
  ' _ "$MENU" "$SB5I/logs" >/dev/null 2>&1
if grep -q 'status:   INTERRUPTED' "$SB5I/logs/menu-20200101-000000-99999-1.log" 2>/dev/null; then
  ok "menu log: a log left behind by a killed tab is closed as INTERRUPTED"
else
  bad "menu log: the orphan record was not finalised → $(tr '\n' '|' <"$SB5I/logs/menu-20200101-000000-99999-1.log" 2>/dev/null | tail -c 90)"
fi
orphan_sum2="$(CODEMUX_LOG_DIR="$SB5I/logs" run_cm "$SB5I" logs 2>/dev/null)"
case "$orphan_sum2" in
  *"newest failed launch"*"menu-20200101-000000-99999-1.log"*)
    ok "logs command: the interrupted launch is now visible in the audit" ;;
  *) bad "logs command: the interrupted launch is missing → $(printf '%s' "$orphan_sum2" | tr '\n' '|' | tail -c 90)" ;;
esac

# 5e-6. A finished record keeps the header "running" from _cm_log_start and gets
# its verdict appended later, so the verdict is the LAST status line. Reading the
# first one hid every real failure behind "running" (found in this very run:
# the summary said "no failed launch recorded" while 10 FAILED lines existed).
SB5J="$(new_sandbox menu-verdict)"
mkdir -p "$SB5J/home" "$SB5J/logs"
printf 'codemux menu launch\nstatus:   running\nstarted:  2026-01-01T00:00:00+0700\nrow:      v1\nname:     OpenCode V1\n---\nrc:       3\nduration: 1s\nstatus:   FAILED\n' \
  >"$SB5J/logs/menu-20260101-000000-4242-1.log"
verdict_sum="$(CODEMUX_LOG_DIR="$SB5J/logs" run_cm "$SB5J" logs 2>/dev/null)"
case "$verdict_sum" in
  *"newest failed launch"*"menu-20260101-000000-4242-1.log"*)
    ok "logs command: the final verdict wins over the \"running\" header" ;;
  *) bad "logs command: a FAILED record was hidden behind its header → $(printf '%s' "$verdict_sum" | tr '\n' '|' | tail -c 90)" ;;
esac
# ... and the reap must never touch a record that already has a verdict.
env HOME="$SB5J/home" PREFIX="$SB5J/prefix" TMPDIR="$BASE" bash -c '
    . "$1"
    _cm_log_reap "$2"
  ' _ "$MENU" "$SB5J/logs" >/dev/null 2>&1
if ! grep -q 'INTERRUPTED' "$SB5J/logs/menu-20260101-000000-4242-1.log" 2>/dev/null &&
  grep -q 'status:   FAILED' "$SB5J/logs/menu-20260101-000000-4242-1.log" 2>/dev/null; then
  ok "menu log: reap leaves a finished record alone"
else
  bad "menu log: reap rewrote a finished record → $(tr '\n' '|' <"$SB5J/logs/menu-20260101-000000-4242-1.log" | tail -c 90)"
fi

# 5e-5. An option the command does not know must fail loudly, not print a
# summary and exit 0 (that hides a typo in a script or a wrapper).
CODEMUX_LOG_DIR="$SB5E/logs" run_cm "$SB5E" logs --bogus >"$SB5E/bogus.out" 2>&1
bogus_rc=$?
if [ "$bogus_rc" -eq 2 ] && grep -q 'unknown option for logs' "$SB5E/bogus.out"; then
  ok "logs command: an unknown option fails with rc=2 and a hint"
else
  bad "logs command: unknown option → rc=$bogus_rc, out='$(tr '\n' '|' <"$SB5E/bogus.out" | tail -c 90)'"
fi

# =============================================================================
# 5e-7. audit fixes (2026-11-17): the nag, the detection, the exit notice
# =============================================================================
# (a) a new launch clears the "last launch failed" nag: the newest launch is
#     the newest truth, so a later success must silence an older failure.
SB5K="$(new_sandbox menu-nag)"
mkdir -p "$SB5K/home" "$SB5K/logs"
nag="$(env HOME="$SB5K/home" PREFIX="$SB5K/prefix" TMPDIR="$BASE" \
  CODEMUX_LOG_DIR="$SB5K/logs" bash -c '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
    . "$1"
    _cm_log_start v1 "OpenCode V1" /bin/true
    _cm_log_finish 3 failed
    printf "after_fail=%s\n" "${_CM_LASTLOG:-none}"
    _cm_log_start v2 "OpenCode V2" /bin/true
    printf "after_new=%s\n" "${_CM_LASTLOG:-none}"
  ' _ "$MENU" 2>&1)"
case "$nag" in
  *"after_fail=$SB5K/logs"*"after_new=none"*)
    ok "menu log: a new launch clears the last-failure nag" ;;
  *) bad "menu log: nag state wrong → $(printf '%s' "$nag" | tr '\n' '|')" ;;
esac

# (b) a wrapper FUNCTION in .bashrc is not an install: the digest wrapper
#     defines opencode()/opencode-v2() and `command -v` finds a function even
#     when the payload is gone — the rows then claimed an agent was installed
#     and picking it died with "command not found" (rc=127) instead of
#     offering the install.
SB5L="$(new_sandbox menu-detect)"
mkdir -p "$SB5L/home/.config/codemux" "$SB5L/prefix/bin"
cp "$MENU" "$SB5L/home/.config/codemux/menu.sh"
cat >"$SB5L/home/.bashrc" <<'EOB'
_oc_refresh_digest() { :; }
_oc_tty_repair() { :; }
opencode() { command opencode "$@"; }
opencode-v2() { command opencode-v2 "$@"; }
EOB
descs="$(env -u TMUX -u TMUX_PANE HOME="$SB5L/home" PREFIX="$SB5L/prefix" \
  PATH="$SB5L/prefix/bin" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" "$(command -v bash)" -ic '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
    . "$HOME/.config/codemux/menu.sh"
    _cm_items
    printf "%s" "${_CM_DESCS[*]}"
  ' 2>/dev/null)"
case "$descs" in
  "not installed not installed not installed"*)
    ok "menu: a wrapper function in .bashrc is not an install (payload gone)" ;;
  *"? · stable"*|*"? · separate DB"*)
    bad "menu: bashrc functions fooled the detection → $descs" ;;
  *) bad "menu: unexpected rows with only functions present → $descs" ;;
esac

# (c) the exit message travels in the rows: the loop wipes the screen before
#     the next answer, so a printf after the launch is never readable.
if grep -qF '_CM_NOTICE="$name exited with $rc' "$MENU" &&
  ! grep -q 'printf .*exited with' "$MENU"; then
  ok "menu: the exit message rides in the rows, not in a wiped printf"
else
  bad "menu: the exit message is still printed outside the rows"
fi

# (d) the Quit row says what it does: it kills the tmux session, i.e. every
#     tab, not just the one it was typed in.
if grep -qF 'close every tab' "$MENU" && ! grep -qF 'close this tab' "$MENU"; then
  ok "menu: the Quit row promises what happens (every tab closes)"
else
  bad "menu: the Quit row still says 'close this tab'"
fi

# (e) an installer that exits 0 without producing the agent must not be
#     reported as "installed" — the pi module does exactly this while
#     free-pi-cli is missing (it can only suggest the first interactive start).
SB5M="$(new_sandbox menu-pi-honest)"
mkdir -p "$SB5M/home/.config/codemux" "$SB5M/logs" "$SB5M/prefix/bin"
cp "$MENU" "$SB5M/home/.config/codemux/menu.sh"
printf '#!/bin/sh\nexit 0\n' >"$SB5M/prefix/bin/codemux"
chmod +x "$SB5M/prefix/bin/codemux"
pi_out="$(printf '%b' '3\ny\n' | timeout 25 env -u TMUX -u TMUX_PANE \
  HOME="$SB5M/home" PREFIX="$SB5M/prefix" PATH="$SB5M/prefix/bin:$PATH" \
  CODEMUX_LOG_DIR="$SB5M/logs" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
  C1=""; C2=""; ACC=""; DIM=""; BOLD=""; R=""
  . "$1"
  _cm_menu_loop' _ "$SB5M/home/.config/codemux/menu.sh" 2>/dev/null)"
case "$pi_out" in
  *"Free-pi (Pi) needs a first start — npx -y free-pi-cli@latest"*)
    ok "menu: a do-nothing install of pi is not reported as installed" ;;
  *"Free-pi (Pi) installed"*)
    bad "menu: pi reported installed although nothing was installed" ;;
  *) bad "menu: pi install notice is '$(printf '%s' "$pi_out" | tr '\n' '|' | tail -c 120)'" ;;
esac
if grep -q 'status:   MISSING' "$SB5M/logs"/menu-*.log 2>/dev/null; then
  ok "menu log: the do-nothing pi install is recorded as MISSING"
else
  bad "menu log: the do-nothing pi install was not recorded as MISSING"
fi

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
# Now a valid .bashrc: the wrapper must appear exactly once, and the next run
# must not add a second block. The wrapper is a function (not an alias) so the
# terminal is repaired after pi exits: _oc_tty_fix has to be called from it.
printf 'echo keep\n' >"$SB5C/home/.bashrc"
PATH="$SB5C/prefix/bin:$PATH" run_cm "$SB5C" install --only pi --skip "$SKIP_ONLY_PI" >"$SB5C/out2.log" 2>&1 || true
if grep -q 'codemux:pi begin' "$SB5C/home/.bashrc" && grep -q '^pi() {' "$SB5C/home/.bashrc"; then
  ok "pi module: the wrapper is added once .bashrc is valid"
else
  bad "pi module: wrapper not added to a valid .bashrc"
fi
if grep -q '_oc_tty_fix' "$SB5C/home/.bashrc"; then
  ok "pi module: the wrapper repairs the terminal after pi exits"
else
  bad "pi module: wrapper does not call _oc_tty_fix"
fi
if grep -q 'version 2)' "$SB5C/home/.bashrc"; then
  ok "pi module: the wrapper block carries its version marker"
else
  bad "pi module: wrapper block has no version marker"
fi
PATH="$SB5C/prefix/bin:$PATH" run_cm "$SB5C" install --only pi --skip "$SKIP_ONLY_PI" >"$SB5C/out3.log" 2>&1 || true
if [ "$(grep -c 'codemux:pi begin' "$SB5C/home/.bashrc")" -eq 1 ]; then
  ok "pi module: idempotent (one wrapper block)"
else
  bad "pi module: the wrapper block was duplicated"
fi
# An older codemux wrote a bare `alias pi=`; that leaves the terminal broken
# after exit. The next install must turn it into the wrapper in place.
printf 'echo keep\n# codemux:pi begin  (managed by codemux)\nalias pi=/old/bin/free-pi-cli\n# codemux:pi end\n' \
  >"$SB5C/home/.bashrc"
PATH="$SB5C/prefix/bin:$PATH" run_cm "$SB5C" install --only pi --skip "$SKIP_ONLY_PI" >"$SB5C/out4.log" 2>&1 || true
if ! grep -q 'alias pi=' "$SB5C/home/.bashrc" && grep -q '^pi() {' "$SB5C/home/.bashrc"; then
  ok "pi module: an old alias block is rewritten as the wrapper"
else
  bad "pi module: old alias block was left in place"
fi
if [ "$(grep -c 'echo keep' "$SB5C/home/.bashrc")" -eq 1 ]; then
  ok "pi module: lines outside the block survive the rewrite"
else
  bad "pi module: rewrite damaged the rest of .bashrc"
fi

# =============================================================================
# 5d. `--only pi` must not forget the OpenCode choice
# =============================================================================
# pi is a tail module and always runs, so saving "pi" as the component list made
# `check` report the installed V1/V2 as SKIP — a wrapper-only install silently
# deselected the agents the user had picked.
SB5D="$(new_sandbox pi-components)"
printf 'v1\n' >"$SB5D/state/components"
printf '#!/bin/sh\n' >"$SB5D/prefix/bin/free-pi-cli"
chmod +x "$SB5D/prefix/bin/free-pi-cli"
PATH="$SB5D/prefix/bin:$PATH" run_cm "$SB5D" install --yes --only pi --skip "$SKIP_ONLY_PI" \
  >"$SB5D/out.log" 2>&1 || true
if [ "$(cat "$SB5D/state/components" 2>/dev/null)" = v1 ]; then
  ok "--only pi keeps the saved component choice (v1)"
else
  bad "--only pi overwrote the component choice ('$(cat "$SB5D/state/components" 2>/dev/null)')"
fi
# And an explicit V1/V2 choice is still saved.
printf 'v1\n' >"$SB5D/state/components"
PATH="$SB5D/prefix/bin:$PATH" run_cm "$SB5D" install --yes --only v2 --skip "$SKIP_ONLY_PI" \
  >"$SB5D/out2.log" 2>&1 || true
if [ "$(cat "$SB5D/state/components" 2>/dev/null)" = v2 ]; then
  ok "--only v2 still saves the component choice"
else
  bad "--only v2 did not save the choice ('$(cat "$SB5D/state/components" 2>/dev/null)')"
fi

rm -rf "$SANDBOX_ROOT"
printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
