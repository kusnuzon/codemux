#!/usr/bin/env bash
# tests/sync-files.sh — tools/sync-opencode-files.sh against sandbox repos.
#
# The canonical copies live in opencode-shared/ and must match the copies in
# the V1 and V2 repos. This suite pins the tool contract itself: sync copies,
# --check detects drift/missing files without changing anything, a failed check
# never writes, and an unknown option is rejected.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TOOL="$ROOT/tools/sync-opencode-files.sh"

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX_ROOT="$BASE/codemux-syncfiles-$$"
rm -rf "$SANDBOX_ROOT"
trap 'rm -rf "$SANDBOX_ROOT"' EXIT
mkdir -p "$SANDBOX_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# A tiny canonical tree: two files is enough to exercise every path.
CANON="$SANDBOX_ROOT/canonical"
mkdir -p "$CANON/plugins"
printf 'one\n' >"$CANON/plugins/a.js"
printf 'two\n' >"$CANON/plugins/b.py"

mkrepo() {
  mkdir -p "$1/plugins"
  cp "$CANON/plugins/a.js" "$CANON/plugins/b.py" "$1/plugins/"
}

run() { SYNC_FILES_SRC="$CANON" bash "$TOOL" "$@"; }

# =============================================================================
# 1. sync copies the canonical files into an empty repo
# =============================================================================
repo1="$SANDBOX_ROOT/r1"
mkdir -p "$repo1/plugins"
out="$(run "$repo1")"
if [ -s "$repo1/plugins/a.js" ] && [ "$(cat "$repo1/plugins/a.js")" = "one" ]; then
  ok "sync copies the canonical files"
else
  bad "sync did not copy the canonical files: $out"
fi

# =============================================================================
# 2. --check passes on identical repos, for one and for two repos at once
# =============================================================================
if run --check "$repo1" >/dev/null 2>&1; then
  ok "check passes on an identical repo"
else
  bad "check failed on an identical repo"
fi
repo2="$SANDBOX_ROOT/r2"
mkrepo "$repo2"
if run --check "$repo1" "$repo2" >/dev/null 2>&1; then
  ok "check passes on two identical repos"
else
  bad "check failed on two identical repos"
fi

# =============================================================================
# 3. --check detects drift, names the file, exits 1 — and writes nothing
# =============================================================================
printf 'drifted\n' >"$repo1/plugins/a.js"
out="$(run --check "$repo1" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'DRIFT r1 plugins/a.js'; then
  ok "drift is detected and reported"
else
  bad "drift not reported (rc=$rc): $out"
fi
if [ "$(cat "$repo1/plugins/a.js")" = "drifted" ]; then
  ok "check never modifies the repo"
else
  bad "check modified a drifted file"
fi

# =============================================================================
# 4. sync repairs the drift
# =============================================================================
out="$(run "$repo1")"
if [ "$(cat "$repo1/plugins/a.js")" = "one" ] && run --check "$repo1" >/dev/null 2>&1; then
  ok "sync repairs drift"
else
  bad "sync did not repair drift: $out"
fi

# =============================================================================
# 5. a file missing in the repo is a failure, not a silent skip
# =============================================================================
rm "$repo2/plugins/b.py"
out="$(run --check "$repo2" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL r2: file missing: plugins/b.py'; then
  ok "missing repo file is reported"
else
  bad "missing repo file not reported (rc=$rc): $out"
fi

# =============================================================================
# 6. an empty canonical tree is a failure, not a wipe of both repos
# =============================================================================
empty="$SANDBOX_ROOT/empty"
mkdir -p "$empty/plugins"
out="$(SYNC_FILES_SRC="$empty" bash "$TOOL" --check "$repo1" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'canonical directory is empty'; then
  ok "empty canonical tree is rejected"
else
  bad "empty canonical tree not rejected (rc=$rc): $out"
fi

# =============================================================================
# 7. a repo directory that does not exist is a failure
# =============================================================================
if run --check "$SANDBOX_ROOT/nope" >/dev/null 2>&1; then
  bad "missing repo directory accepted"
else
  ok "missing repo directory is rejected"
fi

# =============================================================================
# 8. an unknown option is rejected
# =============================================================================
if run --bogus >/dev/null 2>&1; then
  bad "unknown option accepted"
else
  ok "unknown option is rejected"
fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
