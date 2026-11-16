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
if [ "$(grep -c '_oc_menu_loop()' "$rc3")" -eq 1 ] &&
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
# 5. the launcher block is small, fast and key-free
# =============================================================================
# The block is sourced by every interactive shell, so it must not start an agent
# to read a version and must not read single keys. Both were real bugs: the
# version probe ran `opencode --version` (1.2 s before every prompt) and the
# key reader could spin on a terminal a TUI handed back in raw mode.
TPL="$ROOT/templates/bashrc-block.sh"
SB5="$(new_sandbox menu-items)"
if ! grep -q 'timeout 8 opencode' "$TPL" && ! grep -q '\$(opencode --version' "$TPL" &&
  grep -q 'share/opencode/VERSION' "$TPL" && grep -q 'dpkg-query' "$TPL"; then
  ok "menu: versions come from files, the agent binary is never started"
else
  bad "menu: the version probe still runs the agent binary"
fi
if ! grep -q 'read -rsn1' "$TPL" && ! grep -q '_oc_read_key' "$TPL" &&
  grep -q 'IFS= read -r choice' "$TPL"; then
  ok "menu: one typed line per answer (no single-key reader)"
else
  bad "menu: a single-key reader is still present"
fi
# The banner stays: ASCII art plus one meta line with the installed agents.
if grep -q '█▀▀█' "$TPL" && grep -q 'Termux · Android arm64' "$TPL"; then
  ok "menu: banner kept (art + version line)"
else
  bad "menu: banner missing"
fi
# Dropped on purpose: the tmux tab-strip bindings, the quota/update notices and
# the install dialog. Their absence is what keeps the block small.
if ! grep -q 'MouseDown1Status' "$TPL" && ! grep -q '_oc_pi_tmux_tabs' "$TPL" &&
  ! grep -q '_oc_quota_notice' "$TPL" && ! grep -q '_oc_update_notice' "$TPL" &&
  ! grep -q 'Install it now?' "$TPL"; then
  ok "menu: no tab-strip bindings, notices or install dialog left"
else
  bad "menu: a dropped feature is still in the block"
fi
# Small enough to read on one screen.
lines="$(wc -l <"$TPL")"
if [ "$lines" -le 220 ]; then
  ok "menu: the block is $lines lines"
else
  bad "menu: the block is still $lines lines (target ≤ 220)"
fi
# The terminal repair stays: it is what unfreezes Termux after an agent exits.
tty_modes_missing=""
for mode in '\007' '\033\\' '\033[?2026l' '\033[?1049l' '\033[?1002l' \
  '\033[?2004l' '\033['r '\033[?6l' '\033[?7h' '\033(B' '\033[!p'; do
  grep -qF "$mode" "$TPL" || tty_modes_missing="$tty_modes_missing $mode"
done
if [ -z "$tty_modes_missing" ]; then
  ok "menu: the terminal reset keeps every mode it releases"
else
  bad "menu: terminal reset is incomplete, missing:$tty_modes_missing"
fi
fix_sites="$(grep -c '_oc_tty_fix' "$TPL")"
if grep -q '^_oc_tty_fix() {' "$TPL" && [ "$fix_sites" -ge 3 ] && grep -q '^  _oc_tty_fix$' "$TPL"; then
  ok "menu: terminal repaired after a component and before the shell"
else
  bad "menu: terminal repair missing on an exit path ($fix_sites sites)"
fi

# rows: always the same five, a missing agent marked
menu_keys() { # <sandbox> → keys of the menu rows
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"
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
      printf "%s" "${_OC_DESCS[*]}"
    ' _ "$TPL" "$sb/prefix/bin" 2>/dev/null
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
  OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c 'command() { return 1; }; . "$1"; _oc_colors; _oc_banner' \
  _ "$TPL" 2>/dev/null)"
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
  OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c 'PATH="$2:$PATH"; . "$1"; _oc_colors; _oc_banner' \
  _ "$TPL" "$SB5/prefix/bin" 2>/dev/null)"
case "$meta" in
  *"v2 2.3.0"*) ok "menu: an installed agent is listed with its version" ;;
  *) bad "menu: installed agent missing from the banner → $(printf '%s' "$meta" | tr '\n' ' ')" ;;
esac

# version(): three lines, read from files
out="$(env HOME="$SB5/home" PREFIX="$SB5/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" \
  bash -c 'PATH="$2:$PATH"; . "$1"; version' _ "$TPL" "$SB5/prefix/bin" 2>/dev/null)"
case "$out" in
  *"OpenCode V1:"*"OpenCode V2:"*"Free-pi (Pi):"*)
    ok "menu: version prints the three agents" ;;
  *) bad "menu: version output is '$(printf '%s' "$out" | tr '\n' '|')'" ;;
esac

# a missing agent is reported, never installed from the menu
out="$(printf '1\n' | timeout 20 env HOME="$SB5/home" PREFIX="$SB5/prefix" \
  OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c 'PATH="$2"; . "$1"; _oc_menu_loop; printf "rc=%s\n" "$?"' \
  _ "$TPL" "$SB5/prefix/bin" 2>/dev/null)"
case "$out" in
  *"is not installed"*"run: codemux install"*"rc=1"*)
    ok "menu: choosing a missing agent explains the install command" ;;
  *) bad "menu: missing agent → $(printf '%s' "$out" | tr '\n' ' ' | tail -c 200)" ;;
esac
if grep -q 'OPENCODE_NO_AUTO' "$TPL" && grep -q 'OPENCODE_AUTO_LAUNCHED' "$TPL"; then
  ok "menu: auto-launch can be skipped (OPENCODE_NO_AUTO=1)"
else
  bad "menu: no gate around the auto-launch"
fi
# =============================================================================
# 5d. a dead stdin never traps the menu (the /quit bug)
# =============================================================================
# A full-screen agent can hand back a terminal that answers nothing, so `read`
# fails instantly and forever. The menu used to spin on that EOF and never came
# back. It must give up and return instead.
SB5D="$(new_sandbox eof)"
mkdir -p "$SB5D/prefix/bin" "$SB5D/home"
# The menu answers with a typed number, so a dead stdin (what a full-screen agent
# leaves behind) must end it instead of looping. `timeout` is the assertion: a
# reader that spins on EOF burns the CPU and the suite would never finish.
menu_with() { # <stdin text> → "rc=<status>" (stdin is fed with printf)
  local input="$1"
  printf '%b' "$input" | timeout 20 env HOME="$SB5D/home" PREFIX="$SB5D/prefix" \
    PATH="$SB5D/prefix/bin:$PATH" CODEMUX_ROOT="$ROOT" CODEMUX_HOME="$SB5D/state" \
    CODEMUX_ALLOW_NONANDROID=1 OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
    C1=""; C2=""; ACC=""; DIM=""; BOLD=""; HL=""; R=""
    _oc_cursor_show() { :; }
    _oc_cursor_hide() { :; }
    _oc_tty_fix() { :; }
    . "$1"
    _oc_menu_loop
    printf "menu rc=%s\n" "$?"
  ' _ "$TPL" 2>/dev/null
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
    ok "menu: typing 4 (Shell only) returns to the shell" ;;
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

rm -rf "$SANDBOX_ROOT"
printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
