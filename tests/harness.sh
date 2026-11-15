#!/usr/bin/env bash
# tests/harness.sh — check that a test file makes no Termux-only assumption.
#
# The suites run on a plain GitHub runner as well as on Termux, and four
# assumptions silently broke CI before: a raw $PREFIX read under `set -u`, a
# Termux-only shebang inside a file the test writes, and hardcoded
# /data/data/com.termux paths. This file greps for those, and then runs one
# suite in a mock Termux layout to prove the suite works with PREFIX set.
#
# It does not run the whole matrix (ci.yml does that); it is the cheap gate
# that can also be run locally.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

SUITES="tests/smoke.sh tests/resume.sh tests/adapter.sh tests/launcher-memory.sh tests/maintenance.sh tests/release.sh"

# 1. a raw $PREFIX read under `set -u` kills a plain runner.
#    ${PREFIX:-} is fine, $PREFIX and ${PREFIX} are not. Comments are skipped
#    (they cannot fail), and adapter.sh is exempt: its upstream fakes run with
#    PREFIX set by run_install, so reading it there is intended.
bad_prefix=0
for f in $SUITES; do
  [ "$f" = "tests/adapter.sh" ] && continue
  # shellcheck disable=SC2016  # the pattern is literal, not expanded
  hits="$(awk '!/^[[:space:]]*#/ && /\$PREFIX([^_]|$)|\$\{PREFIX\}/ && !/PREFIX:-/ { printf "%d:%s\n", NR, $0 }' "$f")"
  if [ -n "$hits" ]; then
    bad "$f reads \$PREFIX unguarded:"
    printf '%s\n' "$hits" | sed 's/^/       /'
    bad_prefix=1
  fi
done
[ "$bad_prefix" -eq 0 ] && ok "no unguarded \$PREFIX in the suites"

# 2. no Termux-only absolute paths in files the suites create.
#    The suites must resolve bash with command -v instead.
bad_abs=0
for f in $SUITES; do
  hits="$(awk 'NR > 1 && /data\/data\/com\.termux/ { printf "%d:%s\n", NR, $0 }' "$f")"
  if [ -n "$hits" ]; then
    bad "$f hardcodes a Termux path:"
    printf '%s\n' "$hits" | sed 's/^/       /'
    bad_abs=1
  fi
done
[ "$bad_abs" -eq 0 ] && ok "no hardcoded Termux paths (shebang line excepted)"

# 3. every suite must be runnable with bash, whatever its shebang says.
bad_sb=0
for f in $SUITES; do
  first="$(head -n 1 "$f")"
  case "$first" in
    '#!/usr/bin/env bash' | '#!/bin/bash') ;;
    *) bad "$f has a non-portable shebang: $first"; bad_sb=1 ;;
  esac
done
[ "$bad_sb" -eq 0 ] && ok "portable shebangs"

# 4. smoke.sh must pass in a mock Termux layout: PREFIX set, no HOME surprises.
MOCK="$BASE/codemux-harness-$$"
rm -rf "$MOCK"
mkdir -p "$MOCK/prefix/bin" "$MOCK/prefix/tmp"
if PREFIX="$MOCK/prefix" TMPDIR="$MOCK" bash tests/smoke.sh >"$MOCK/smoke.log" 2>&1; then
  ok "smoke.sh with a mock Termux PREFIX ($(grep -oE '[0-9]+ passed' "$MOCK/smoke.log" | tail -1))"
else
  bad "smoke.sh with a mock Termux PREFIX"
  tail -n 15 "$MOCK/smoke.log" | sed 's/^/       /'
fi
rm -rf "$MOCK"

printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
