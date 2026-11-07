#!/data/data/com.termux/files/usr/bin/bash
# tests/resume.sh — prove the install survives being killed midway.
# Sandbox: HOME, CODEMUX_HOME, fake apt-get & dpkg-query. The system is NOT touched.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# CI (ubuntu) has no Termux $PREFIX → use TMPDIR.
BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
BASH_BIN="$(command -v bash)"
SANDBOX="$BASE/codemux-test-$$"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/installed" "$SANDBOX/state"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- fake apt-get ------------------------------------------------------------
cat >"$SANDBOX/bin/apt-get" <<'EOS'
#!/usr/bin/env bash
# CM_TEST_SLEEP: process duration (so it can be shot dead)
# CM_TEST_FAIL : force a failure
sleep "${CM_TEST_SLEEP:-0}"
[ -n "${CM_TEST_FAIL:-}" ] && exit 100
for a in "$@"; do
  case "$a" in fakepkg*) : >"$CM_TEST_INSTALLED/$a" ;; esac
done
exit 0
EOS
sed -i "1s|.*|#!$BASH_BIN|" "$SANDBOX/bin/apt-get"
chmod 700 "$SANDBOX/bin/apt-get"

# --- fake dpkg-query ---------------------------------------------------------
cat >"$SANDBOX/bin/dpkg-query" <<'EOS'
#!/usr/bin/env bash
pkg="${!#}"
if [ -e "$CM_TEST_INSTALLED/$pkg" ]; then
  echo "install ok installed"
else
  echo "deinstall ok config-files"
fi
EOS
sed -i "1s|.*|#!$BASH_BIN|" "$SANDBOX/bin/dpkg-query"
chmod 700 "$SANDBOX/bin/dpkg-query"

export CODEMUX_ALLOW_NONANDROID=1
export CM_TEST_INSTALLED="$SANDBOX/installed"
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export CODEMUX_HOME="$SANDBOX/state"
export CODEMUX_APT_PACKAGES="fakepkg1 fakepkg2"
export CM_TEST_SLEEP=0

CODEXUX="$ROOT/bin/codemux"

TEST_FAIL=""
run_install() { # <sleep> [install options...]
  local sleep_s="$1"
  shift
  env CM_TEST_SLEEP="$sleep_s" CM_TEST_FAIL="$TEST_FAIL" bash "$CODEXUX" install "$@" \
    --skip deps,mirror,storage,glibc,v1,v2,launcher,dotfiles,memory,self >>"$SANDBOX/out.log" 2>&1
}

run_state() { awk -F'\t' -v m="$1" '!/^#/ && $1==m {s=$2} END{print s}' "$CODEMUX_HOME/run.tsv"; }

# =============================================================================
# 1. normal run: toolset installed through the fake apt
# =============================================================================
if run_install 0 --fresh; then ok "base install finished (exit 0)"; else bad "base install failed"; fi
if [ -e "$SANDBOX/installed/fakepkg1" ] && [ -e "$SANDBOX/installed/fakepkg2" ]; then
  ok "the fake apt was really called"
else
  bad "the fake apt was not called"
fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "run.tsv: toolset DONE"; else bad "run.tsv: toolset $(run_state toolset)"; fi

# =============================================================================
# 2. parent killed while apt runs → child survives → the next run waits for it
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2"
CM_TEST_SLEEP=8 bash "$CODEXUX" install --fresh \
  --skip deps,mirror,storage,glibc,v1,v2,launcher,dotfiles,memory,self >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 3

if [ "$(run_state toolset)" = "RUNNING" ]; then ok "step recorded as RUNNING before finishing"; else bad "initial status $(run_state toolset)"; fi
kill -9 "$parent" 2>/dev/null

# a stale lock must be dropped automatically, the second install may run
if run_install 10; then ok "second run resumes after the parent was killed"; else bad "second run failed"; fi
if [ -e "$SANDBOX/installed/fakepkg1" ]; then ok "the surviving child finished the work"; else bad "the child did not finish"; fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "second run closes the step as DONE"; else bad "final status $(run_state toolset)"; fi

# =============================================================================
# 3. parent + child killed → status INTERRUPTED → the next run starts over
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2" "$SANDBOX/state/run/toolset.rc"
CM_TEST_SLEEP=30 bash "$CODEXUX" install --fresh \
  --skip deps,mirror,storage,glibc,v1,v2,launcher,dotfiles,memory,self >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 3
child="$(cat "$SANDBOX/state/run/toolset.pid" 2>/dev/null || true)"
kill -9 "$parent" 2>/dev/null
[ -n "$child" ] && kill -9 "$child" 2>/dev/null

rep_out="$(bash "$CODEXUX" repair --dry-run 2>&1 || true)"
if printf '%s' "$rep_out" | grep -q 'mark interrupted'; then
  ok "repair detects the interrupted step"
else
  bad "repair did not detect the interrupted step"
  printf '%s\n' "$rep_out" | sed 's/^/     | /'
  awk -F'\t' '{print "     > "$1" "$2}' "$CODEMUX_HOME/run.tsv" 2>/dev/null
fi

if run_install 0; then ok "third run finishes the remaining work"; else bad "third run failed"; fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "status recovered to DONE"; else bad "final status $(run_state toolset)"; fi

# =============================================================================
# 4. an active lock rejects the second install (no two apt runs at once)
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2" "$SANDBOX/state/run/toolset.rc"
CM_TEST_SLEEP=6 bash "$CODEXUX" install --fresh \
  --skip deps,mirror,storage,glibc,v1,v2,launcher,dotfiles,memory,self >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 2
run_install 0 >/dev/null 2>&1
rc=$?
wait "$parent" 2>/dev/null
if [ "$rc" -eq 3 ]; then ok "second install rejected while one is running (exit 3)"; else bad "second install rc=$rc (should be 3)"; fi

# =============================================================================
# 5. apt fails → FAILED recorded, then the next run repairs it
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2"
TEST_FAIL=1
run_install 0 --fresh >/dev/null 2>&1
rc=$?
TEST_FAIL=""
if [ "$rc" -eq 1 ]; then ok "apt failure → install exit 1 (no crash)"; else bad "apt failure → rc=$rc"; fi
if [ "$(run_state toolset)" = "FAILED" ]; then ok "run.tsv: toolset FAILED"; else bad "run.tsv: $(run_state toolset)"; fi
if run_install 0; then ok "the next run repairs the failed step"; else bad "repair run failed"; fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "final status DONE after the repair"; else bad "final status $(run_state toolset)"; fi

# =============================================================================
# 6. atomic state writes: no .new files left behind
# =============================================================================
left="$(find "$CODEMUX_HOME" -name '*.new' -o -name '.codemux.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$left" = "0" ]; then ok "no temporary files left behind"; else bad "$left temporary files left behind"; fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf '\n--- last 20 log lines ---\n'
  tail -n 20 "$SANDBOX/out.log" 2>/dev/null
fi
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
