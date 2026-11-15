#!/usr/bin/env bash
# tools/run-tests.sh — run the codemux suites and report one summary.
#
# Every suite builds its own sandbox under $TMPDIR, so they can run at the same
# time: in parallel the whole set takes about as long as the slowest suite
# (resume, ~75 s) instead of the sum of all of them (~2 min 50 s). Use
# --serial when a failure needs a clean log of its own.
#
#   bash tools/run-tests.sh              # all suites, in parallel
#   bash tools/run-tests.sh smoke resume # only these
#   bash tools/run-tests.sh -j1          # one at a time
#   bash tools/run-tests.sh -k           # keep the logs (default keeps failures only)
#
# Exit status is 0 only when every suite passed.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${CODEMUX_TEST_TMP:-${TMPDIR:-/tmp}}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi

ALL="smoke launcher-memory maintenance resume release adapter"
jobs=6
keep=0
serial=0
suites=()

while [ $# -gt 0 ]; do
  case "$1" in
    -j*) jobs="${1#-j}"; shift ;;
    -j) jobs="$2"; shift 2 ;;
    --serial) serial=1; shift ;;
    -k | --keep) keep=1; shift ;;
    -h | --help)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) suites+=("$1"); shift ;;
  esac
done
[ "${#suites[@]}" -eq 0 ] && read -r -a suites <<<"$ALL"
[ "$serial" -eq 1 ] && jobs=1

RUN="$BASE/codemux-tests-$$"
mkdir -p "$RUN"

start=$(date +%s)
pids=()
running=0
for s in "${suites[@]}"; do
  s="${s%.sh}"
  if [ ! -f "tests/$s.sh" ]; then
    printf 'no such suite: %s\n' "$s" >&2
    exit 2
  fi
  mkdir -p "$RUN/$(dirname "$s")"
  bash "tests/$s.sh" >"$RUN/$s.log" 2>&1 &
  pids+=("$!")
  running=$((running + 1))
  # Keep at most $jobs suites in flight; wait for the oldest when the cap is hit.
  if [ "$running" -ge "$jobs" ]; then
    wait "${pids[0]}" 2>/dev/null || true
    pids=("${pids[@]:1}")
    running=$((running - 1))
  fi
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
elapsed=$(( $(date +%s) - start ))

failed=0
for s in "${suites[@]}"; do
  line="$(grep -E '[0-9]+ passed · [0-9]+ failed' "$RUN/$s.log" 2>/dev/null | tail -1 || true)"
  if printf '%s' "$line" | grep -qE ' 0 failed'; then
    printf '%-16s %s\n' "$s" "${line# }"
    [ "$keep" -eq 1 ] || rm -f "$RUN/$s.log"
  else
    failed=$((failed + 1))
    printf '%-16s %s\n' "$s" "${line:-CRASHED (no summary)}"
    # The useful part of a failing suite is the FAIL line, not the tail.
    grep -E '^FAIL' "$RUN/$s.log" | sed 's/^/                 /' || true
  fi
done

printf '\n%s suites · %s failed · %ss · logs: %s\n' "${#suites[@]}" "$failed" "$elapsed" "$RUN"
[ "$failed" -eq 0 ] && rm -rf "$RUN"
[ "$failed" -eq 0 ]
