#!/data/data/com.termux/files/usr/bin/bash
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
cat >"$FIXTURE/digest.py" <<'EOS'
#!/usr/bin/env python3
import os
base = os.path.join(os.path.expanduser("~"), ".config", "opencode")
os.makedirs(base, exist_ok=True)
with open(os.path.join(base, "RECENT.md"), "w", encoding="utf-8") as fh:
    fh.write("# RECENT\n\n- created by the digest fixture\n")
EOS
chmod 700 "$FIXTURE/digest.py"

new_sandbox() {
  local name="$1" d="$SANDBOX_ROOT/$1"
  rm -rf "$d"
  mkdir -p "$d/home" "$d/state" "$d/prefix"
  printf '%s' "$d"
}

run_cm() { # <sandbox> <command...>
  local sb="$1"
  shift
  env HOME="$sb/home" CODEMUX_HOME="$sb/state" PREFIX="$sb/prefix" TMPDIR="$BASE" \
    CODEMUX_ALLOW_NONANDROID=1 \
    CODEMUX_MEMORY_PLUGIN_URL="$FIXTURE/plugin.js" \
    CODEMUX_MEMORY_TITLE_URL="$FIXTURE/title.js" \
    CODEMUX_MEMORY_DIGEST_URL="$FIXTURE/digest.py" \
    bash "$ROOT/bin/codemux" "$@"
}

SKIP_ALL_BUT_M4="deps,mirror,storage,toolset,glibc,v1,v2"
SKIP_ONLY_LAUNCHER="deps,mirror,storage,toolset,glibc,v1,v2,dotfiles,memory"

# =============================================================================
# 1. Fresh: every M4 module installed from scratch
# =============================================================================
SB="$(new_sandbox fresh)"
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
if grep -qF '\033[?25l' "$TPL" && grep -qF '\033[?25h' "$TPL"; then
  ok "menu: cursor hidden & restored"
else
  bad "menu: cursor escapes (?25l/?25h) incomplete"
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
# the menu only offers the components that are actually installed
menu_keys() { # <sandbox> → keys of the menu rows
  local sb="$1"
  env HOME="$sb/home" PREFIX="$sb/prefix" OPENCODE_NO_AUTO=1 TMPDIR="$BASE" bash -c '
      PATH="$2"   # only the sandbox bin: the real installed codemux must not leak in
      . "$1"
      _oc_items
      printf "%s" "${_OC_KEYS[*]}"
    ' _ "$TPL" "$sb/prefix/bin" 2>/dev/null
}
SB5="$(new_sandbox menu-items)"
mkdir -p "$SB5/prefix/bin"
printf '#!/bin/sh\n' >"$SB5/prefix/bin/opencode-v2"
chmod +x "$SB5/prefix/bin/opencode-v2"
if [ "$(menu_keys "$SB5")" = "v2 shell quit" ]; then
  ok "menu: V2-only install hides the V1 row"
else
  bad "menu: V2-only install still offers V1 ($(menu_keys "$SB5"))"
fi
rm -f "$SB5/prefix/bin/opencode-v2"
printf '#!/bin/sh\n' >"$SB5/prefix/bin/opencode"
chmod +x "$SB5/prefix/bin/opencode"
if [ "$(menu_keys "$SB5")" = "v1 shell quit" ]; then
  ok "menu: V1-only install hides the V2 row"
else
  bad "menu: V1-only install still offers V2 ($(menu_keys "$SB5"))"
fi
printf '#!/bin/sh\n' >"$SB5/prefix/bin/opencode-v2"
chmod +x "$SB5/prefix/bin/opencode-v2"
if [ "$(menu_keys "$SB5")" = "v1 v2 shell quit" ]; then
  ok "menu: both components installed → four rows"
else
  bad "menu: both components installed → rows are $(menu_keys "$SB5")"
fi
rm -f "$SB5/prefix/bin/opencode" "$SB5/prefix/bin/opencode-v2"
if [ "$(menu_keys "$SB5")" = "shell quit" ]; then
  ok "menu: nothing installed → only shell/quit"
else
  bad "menu: nothing installed → rows are $(menu_keys "$SB5")"
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
cat >"$SB6/prefix/bin/codemux" <<'EOS'
#!/data/data/com.termux/files/usr/bin/bash
: >"$HOME/retry-marker"
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
