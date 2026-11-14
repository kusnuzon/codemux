#!/data/data/com.termux/files/usr/bin/bash
# tests/maintenance.sh — test update-check, doctor, upgrade, uninstall (M5).
# Full sandbox: dedicated HOME, PREFIX, CODEMUX_HOME. The system is NOT touched.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX_ROOT="$BASE/codemux-mt-$$"
rm -rf "$SANDBOX_ROOT"
mkdir -p "$SANDBOX_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

new_sandbox() {
  local name="$1" d="$SANDBOX_ROOT/$1"
  rm -rf "$d"
  mkdir -p "$d/home" "$d/state" "$d/prefix/bin" "$d/prefix/share"
  printf '%s' "$d"
}

run_cm() { # <sandbox> <command...>
  local sb="$1"
  shift
  env HOME="$sb/home" CODEMUX_HOME="$sb/state" PREFIX="$sb/prefix" TMPDIR="$BASE" \
    CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
    CODEMUX_FAKE_LOCAL_CODEMUX=0.4.0 CODEMUX_FAKE_LOCAL_V1=1.19.3 CODEMUX_FAKE_LOCAL_V2=2.1.2 \
    CODEMUX_FAKE_TAG_CODEMUX=v0.5.0 \
    CODEMUX_FAKE_TAG_OPENCODE_TERMUX=opencode-termux-1.20.0 \
    CODEMUX_FAKE_TAG_OPENCODE_TERMUX_V2=opencode-termux-v2-2.2.0 \
    bash "$ROOT/bin/codemux" "$@"
}

# =============================================================================
# 1. update-check: detects 3 new components + 24h cache
# =============================================================================
SB="$(new_sandbox update)"
printf 'v1 v2\n' >"$SB/state/components"
run_cm "$SB" update-check --json >"$SB/uc.json" 2>"$SB/uc.err"
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/uc.json"))
assert d["update"] == 3, d
st = {k["nama"]: k["status"] for k in d["komponen"]}
assert st["codemux"] == "update", st
assert st["opencode-v1"] == "update", st
assert st["opencode-v2"] == "update", st
PY
then
  ok "update-check: 3 new components detected"
else
  bad "update-check: wrong detection ($(cat "$SB/uc.err" | head -3))"
fi
[ -f "$SB/state/update-cache.tsv" ] && ok "update-check: cache written" || bad "update-check: cache missing"

# check: the updatecache module must be OK
run_cm "$SB" check --json >"$SB/check.json" 2>/dev/null || true
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/check.json"))
st = {m["modul"]: m["status"] for m in d["modul"]}
assert st["update-cache"] == "OK", st["update-cache"]
PY
then
  ok "check: update-cache OK after the check"
else
  bad "check: update-cache not OK yet"
fi

# same versions → no update
env HOME="$SB/home" CODEMUX_HOME="$SB/state" PREFIX="$SB/prefix" TMPDIR="$BASE" \
  CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
  CODEMUX_FAKE_LOCAL_CODEMUX=0.9.9 CODEMUX_FAKE_LOCAL_V1=1.20.0 CODEMUX_FAKE_LOCAL_V2=2.2.0 \
  CODEMUX_FAKE_TAG_CODEMUX=v0.9.9 \
  CODEMUX_FAKE_TAG_OPENCODE_TERMUX=opencode-termux-1.20.0 \
  CODEMUX_FAKE_TAG_OPENCODE_TERMUX_V2=opencode-termux-v2-2.2.0 \
  bash "$ROOT/bin/codemux" update-check --json >"$SB/uc2.json" 2>/dev/null
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/uc2.json"))
assert d["update"] == 0, d
PY
then
  ok "update-check: same versions → 0 updates"
else
  bad "update-check: wrongly reports an update"
fi

# a briefly failing upstream check (network down) must not erase an update that
# is already known: the old result is reused, not overwritten with "na".
SB="$(new_sandbox offline)"
run_cm "$SB" update-check --quiet >/dev/null 2>&1
env HOME="$SB/home" CODEMUX_HOME="$SB/state" PREFIX="$SB/prefix" TMPDIR="$BASE" \
  CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
  CODEMUX_GITHUB_BASE=https://127.0.0.1:9 \
  CODEMUX_FAKE_LOCAL_CODEMUX=0.4.0 CODEMUX_FAKE_LOCAL_V1=1.19.3 CODEMUX_FAKE_LOCAL_V2=2.1.2 \
  bash "$ROOT/bin/codemux" update-check --quiet >/dev/null 2>&1
if [ "$(awk -F'\t' '$1=="opencode-v2"{print $4}' "$SB/state/update-cache.tsv")" = "update" ]; then
  ok "update-check: a network failure does not erase a known update"
else
  bad "update-check: the update vanished after a network failure ($(tr '\t' ' ' <"$SB/state/update-cache.tsv" | tr '\n' ';'))"
fi
if [ "$(awk -F'\t' '$1=="codemux"{print $4}' "$SB/state/update-cache.tsv")" = "update" ]; then
  ok "update-check: the codemux row also survives a network failure"
else
  bad "update-check: the codemux row became na after a network failure"
fi

# =============================================================================
# 2. upgrade --dry-run changes nothing
# =============================================================================
SB2="$(new_sandbox dry)"
run_cm "$SB2" upgrade --dry-run >"$SB2/out.log" 2>&1
if grep -q 'dry-run' "$SB2/out.log" && [ ! -f "$SB2/home/.bashrc" ]; then
  ok "upgrade --dry-run: plan only, no changes"
else
  bad "upgrade --dry-run changed the system"
fi

# 2b. upgrade follows what is installed, never pulls the missing component in
mkdir -p "$SB2/prefix/share/opencode" "$SB2/prefix/share/opencode-v2"
printf 'v1 payload\n' >"$SB2/prefix/share/opencode/opencode.real"
run_cm "$SB2" upgrade --dry-run >"$SB2/only-v1.log" 2>&1
if grep -qE '^  v1 ' "$SB2/only-v1.log" && ! grep -qE '^  v2 ' "$SB2/only-v1.log"; then
  ok "upgrade: only the installed component (V1) is planned"
else
  bad "upgrade: plan is not limited to installed components"
fi
rm -f "$SB2/prefix/share/opencode/opencode.real"
printf 'v2 payload\n' >"$SB2/prefix/share/opencode-v2/opencode.real"
run_cm "$SB2" upgrade --dry-run >"$SB2/only-v2.log" 2>&1
if grep -qE '^  v2 ' "$SB2/only-v2.log" && ! grep -qE '^  v1 ' "$SB2/only-v2.log"; then
  ok "upgrade: only the installed component (V2) is planned"
else
  bad "upgrade: plan is not limited to installed components"
fi
rm -f "$SB2/prefix/share/opencode-v2/opencode.real"
run_cm "$SB2" upgrade --dry-run >"$SB2/none.log" 2>&1
if ! grep -qE '^  v[12] ' "$SB2/none.log"; then
  ok "upgrade: nothing installed → no payload step is planned"
else
  bad "upgrade: plans a payload even though none is installed"
fi

# =============================================================================
# 3. upgrade --only launcher: adopts the old block + digest wrapper
# =============================================================================
SB3="$(new_sandbox up)"
cat >"$SB3/home/.bashrc" <<'EOS'
# old bashrc
export EDITOR="nano"

# --- banner + menu launcher (2026-10-22) ---
_oc_banner() { printf 'old\n'; }
_oc_launcher() { _oc_banner; }
if [ -z "${OPENCODE_NO_AUTO:-}" ]; then _oc_launcher; fi
EOS
run_cm "$SB3" upgrade --yes --only launcher >"$SB3/out.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c 'codemux:launcher begin' "$SB3/home/.bashrc")" -eq 1 ] &&
  grep -q '_oc_refresh_digest()' "$SB3/home/.bashrc" && bash -n "$SB3/home/.bashrc" 2>/dev/null; then
  ok "upgrade --only launcher: new block + wrapper, valid"
else
  bad "upgrade --only launcher failed (rc=$rc)"
  tail -5 "$SB3/out.log" | sed 's/^/     /'
fi
grep -q 'export EDITOR="nano"' "$SB3/home/.bashrc" &&
  ok "upgrade: other bashrc content preserved" || bad "upgrade: bashrc content lost"
# The update cache is rewritten after the upgrade (otherwise the menu keeps
# suggesting an upgrade that just finished).
if [ -f "$SB3/state/update-cache.tsv" ] &&
  [ "$(awk -F'\t' '$1=="opencode-v2"{print $2}' "$SB3/state/update-cache.tsv")" = "2.1.2" ]; then
  ok "upgrade: update cache refreshed (latest local version)"
else
  bad "upgrade: update cache still holds the old version"
fi

# =============================================================================
# 4. uninstall: payload removed, memory & personal bashrc kept
# =============================================================================
SB4="$(new_sandbox un)"
mkdir -p "$SB4/prefix/share/opencode" "$SB4/prefix/share/opencode-v2"
printf 'v1 payload\n' >"$SB4/prefix/share/opencode/opencode.real"
printf 'v2 payload\n' >"$SB4/prefix/share/opencode-v2/opencode.real"
printf 'launcher v1\n' >"$SB4/prefix/bin/opencode"
printf 'launcher v2\n' >"$SB4/prefix/bin/opencode-v2"
mkdir -p "$SB4/home/.config/opencode"
printf -- '- MEMORY-PRIBADI\n' >"$SB4/home/.config/opencode/MEMORY.md"
cat >"$SB4/home/.bashrc" <<'EOS'
export EDITOR="nano"
# codemux:launcher begin  (managed by codemux)
_oc_banner() { :; }
# codemux:launcher end
# codemux:memory begin  (managed by codemux)
_oc_refresh_digest() { :; }
# codemux:memory end
alias ll='ls -l'
EOS
mod_before="$(cksum <"$SB4/home/.config/opencode/MEMORY.md")"
run_cm "$SB4" uninstall --yes >"$SB4/out.log" 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then ok "uninstall: finished (exit 0)"; else
  bad "uninstall: exit $rc"; tail -6 "$SB4/out.log" | sed 's/^/     /'
fi
if [ ! -e "$SB4/prefix/share/opencode" ] && [ ! -e "$SB4/prefix/share/opencode-v2" ] &&
  [ ! -e "$SB4/prefix/bin/opencode" ] && [ ! -e "$SB4/prefix/bin/opencode-v2" ]; then
  ok "uninstall: V1/V2 payloads removed from PREFIX"
else
  bad "uninstall: payloads still present"
fi
bak_dir="$(ls -d "$SB4/state"/backup/*-uninstall 2>/dev/null | head -1)"
if [ -n "$bak_dir" ] && [ -f "$bak_dir/share-opencode/opencode.real" ]; then
  ok "uninstall: payload stored in a backup (can be restored)"
else
  bad "uninstall: payload was not backed up"
fi
if ! grep -q 'codemux:launcher' "$SB4/home/.bashrc" &&
  ! grep -q 'codemux:memory' "$SB4/home/.bashrc" &&
  grep -q 'export EDITOR' "$SB4/home/.bashrc" &&
  grep -q "alias ll" "$SB4/home/.bashrc" && bash -n "$SB4/home/.bashrc" 2>/dev/null; then
  ok "uninstall: codemux blocks removed, personal content intact"
else
  bad "uninstall: .bashrc is not as expected"
fi
if [ "$(cksum <"$SB4/home/.config/opencode/MEMORY.md")" = "$mod_before" ]; then
  ok "uninstall: MEMORY.md untouched"
else
  bad "uninstall: MEMORY.md changed"
fi

# =============================================================================
# 5. doctor does not crash & prints the extra section
# =============================================================================
SB5="$(new_sandbox doc)"
run_cm "$SB5" doctor >"$SB5/out.log" 2>&1 || true
if grep -q 'Additional checks' "$SB5/out.log" && grep -q 'LD_PRELOAD' "$SB5/out.log"; then
  ok "doctor: the additional checks section is shown"
else
  bad "doctor: output incomplete"
fi

rm -rf "$SANDBOX_ROOT"
printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
