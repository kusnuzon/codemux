#!/data/data/com.termux/files/usr/bin/bash
# tests/adapter.sh — test the V1/V2 adapters (download → run detached → verify).
# Full sandbox: dedicated PREFIX, HOME, CODEMUX_HOME; upstream is faked.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
BASH_BIN="$(command -v bash)"
SANDBOX="$BASE/codemux-adapter-$$"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/state" "$SANDBOX/prefix/bin" \
  "$SANDBOX/prefix/share" "$SANDBOX/upstream"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- fake upstream -----------------------------------------------------------
cat >"$SANDBOX/upstream/v1.sh" <<'EOS'
#!/usr/bin/env bash
sleep "${CM_TEST_SLEEP:-0}"
[ -n "${CM_TEST_FAIL:-}" ] && exit 3
mkdir -p "$PREFIX/share/opencode" "$PREFIX/bin"
printf '#!/usr/bin/env bash\necho 1.19.3\n' >"$PREFIX/share/opencode/opencode.real"
printf '#!/usr/bin/env bash\necho 1.19.3\n' >"$PREFIX/bin/opencode"
chmod 700 "$PREFIX/share/opencode/opencode.real" "$PREFIX/bin/opencode"
exit 0
EOS

cat >"$SANDBOX/upstream/v2.sh" <<'EOS'
#!/usr/bin/env bash
sleep "${CM_TEST_SLEEP:-0}"
[ -n "${CM_TEST_FAIL:-}" ] && exit 3
mkdir -p "$PREFIX/share/opencode-v2/lib/compat" "$PREFIX/bin"
printf '#!/usr/bin/env bash\necho 2.1.2\n' >"$PREFIX/share/opencode-v2/opencode.real"
chmod 700 "$PREFIX/share/opencode-v2/opencode.real"
printf '2.1.2\n' >"$PREFIX/share/opencode-v2/VERSION"
: >"$PREFIX/share/opencode-v2/lib/compat/libc.so"
printf '#!/usr/bin/env bash\necho 2.1.2\n' >"$PREFIX/bin/opencode-v2"
chmod 700 "$PREFIX/bin/opencode-v2"
exit 0
EOS

# fake system tools so the result is deterministic
cat >"$SANDBOX/bin/apt-mark" <<'EOS'
#!/usr/bin/env bash
echo opencode
EOS
cat >"$SANDBOX/bin/dpkg-query" <<'EOS'
#!/usr/bin/env bash
echo "deinstall ok config-files"
EOS
for f in "$SANDBOX/upstream/v1.sh" "$SANDBOX/upstream/v2.sh" \
  "$SANDBOX/bin/apt-mark" "$SANDBOX/bin/dpkg-query"; do
  sed -i "1s|.*|#!$BASH_BIN|" "$f"
  chmod 700 "$f"
done

export CODEMUX_ALLOW_NONANDROID=1
# The memory module still downloads from live api.github.com. Unauthenticated
# calls are capped at 60/hour, so forward the gh token before HOME is sandboxed.
if [ -z "${CODEMUX_GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  CODEMUX_GITHUB_TOKEN="$(gh auth token --hostname github.com 2>/dev/null || true)"
  export CODEMUX_GITHUB_TOKEN
fi
export HOME="$SANDBOX/home"
export CODEMUX_HOME="$SANDBOX/state"
export PREFIX="$SANDBOX/prefix"
export CODEMUX_UPSTREAM_V1="$SANDBOX/upstream/v1.sh"
export CODEMUX_UPSTREAM_V2="$SANDBOX/upstream/v2.sh"
export PATH="$SANDBOX/bin:$PREFIX/bin:$PATH"

CODEMUX="$ROOT/bin/codemux"
SKIP_ALL="deps,mirror,storage,toolset,glibc"

TEST_FAIL=""
run_install() { # <sleep>
  env CM_TEST_SLEEP="$1" CM_TEST_FAIL="$TEST_FAIL" bash "$CODEMUX" install \
    --skip "$SKIP_ALL" "${@:2}" >>"$SANDBOX/out.log" 2>&1
}
run_state() { awk -F'\t' -v m="$1" '!/^#/ && $1==m {s=$2} END{print s}' "$CODEMUX_HOME/run.tsv"; }

# =============================================================================
# 1. normal adapter: V1 + V2 installed through upstream
# =============================================================================
if run_install 0 --fresh; then ok "adapter install finished (exit 0)"; else bad "adapter install failed"; fi
if [ -x "$PREFIX/share/opencode/opencode.real" ]; then ok "V1 payload created upstream"; else bad "V1 payload missing"; fi
if [ -x "$PREFIX/share/opencode-v2/opencode.real" ]; then ok "V2 payload created upstream"; else bad "V2 payload missing"; fi
if [ "$(run_state v1)" = "DONE" ] && [ "$(run_state v2)" = "DONE" ]; then
  ok "run.tsv: v1 & v2 DONE"
else
  bad "run.tsv: v1=$(run_state v1) v2=$(run_state v2)"
fi
if [ -s "$CODEMUX_HOME/cache/v1-install.sh.sha256" ]; then ok "upstream script sha256 recorded"; else bad "sha256 not recorded"; fi

# =============================================================================
# 2. parent killed while the V1 adapter runs → resumes without intervention
# =============================================================================
rm -rf "$PREFIX/share/opencode" "$PREFIX/bin/opencode" "$PREFIX/share/opencode-v2" "$PREFIX/bin/opencode-v2"
rm -f "$CODEMUX_HOME/run/v1.rc" "$CODEMUX_HOME/run/v2.rc"
CM_TEST_SLEEP=8 bash "$CODEMUX" install --fresh --skip "$SKIP_ALL" >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 3
if [ "$(run_state v1)" = "RUNNING" ]; then ok "V1 adapter recorded as RUNNING"; else bad "adapter status $(run_state v1)"; fi
kill -9 "$parent" 2>/dev/null
if run_install 10; then ok "second run resumes the adapter"; else bad "second run failed"; fi
if [ "$(run_state v1)" = "DONE" ] && [ "$(run_state v2)" = "DONE" ]; then
  ok "both adapters DONE after recovery"
else
  bad "after recovery: v1=$(run_state v1) v2=$(run_state v2)"
fi

# =============================================================================
# 3. upstream fails → FAILED recorded, install does not crash (exit 1)
# =============================================================================
rm -rf "$PREFIX/share/opencode" "$PREFIX/bin/opencode" "$PREFIX/share/opencode-v2" "$PREFIX/bin/opencode-v2"
TEST_FAIL=1
run_install 0 --fresh
rc=$?
TEST_FAIL=""
if [ "$rc" -eq 1 ]; then ok "upstream failure → install exit 1 (no crash)"; else bad "upstream failure → rc=$rc"; fi
if [ "$(run_state v1)" = "FAILED" ]; then ok "run.tsv: v1 FAILED"; else bad "run.tsv: v1=$(run_state v1)"; fi
if [ "$(run_state v2)" = "FAILED" ]; then ok "run.tsv: v2 FAILED (still attempted)"; else bad "run.tsv: v2=$(run_state v2)"; fi

# =============================================================================
# 4. upstream script is not a shell script (HTML) → rejected before execution
# =============================================================================
printf '<html><body>rate limited</body></html>\n' >"$SANDBOX/upstream/bad.sh"
CODEMUX_UPSTREAM_V1="$SANDBOX/upstream/bad.sh" \
  CM_TEST_SLEEP=0 bash "$CODEMUX" install --skip "$SKIP_ALL" >>"$SANDBOX/out.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'failed to download upstream V1 install.sh' "$SANDBOX/out.log"; then
  ok "HTML/rate-limit rejected, not executed"
else
  bad "HTML not rejected (rc=$rc)"
fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf '\n--- last 25 log lines ---\n'
  tail -n 25 "$SANDBOX/out.log" 2>/dev/null
fi
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
