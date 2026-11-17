#!/usr/bin/env bash
# tools/run-tests.sh — run the codemux suites and report one summary.
#
# Every suite builds its own sandbox under $TMPDIR, so they can run at the same
# time: in parallel the whole set takes about as long as the slowest suite
# (resume, ~75 s) instead of the sum of all of them (~2 min 50 s). Use
# --serial when a failure needs a clean log of its own.
#
# Each suite is reported as soon as it finishes, so a live terminal (or
# tools/tests-tmux.sh) shows progress instead of staying silent until the end.
# Suites get /dev/null on stdin: a test that reaches for a terminal must not
# block on the tty of whatever session started the run.
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

ALL="smoke launcher-memory maintenance resume release adapter tmuxconf tabctl sync-files skills"
jobs=6
keep=0
serial=0
suites=()

while [ $# -gt 0 ]; do
  case "$1" in
    -j) jobs="$2"; shift 2 ;;
    -j*) jobs="${1#-j}"; shift ;;
    --serial) serial=1; shift ;;
    -k | --keep) keep=1; shift ;;
    -h | --help)
      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) suites+=("$1"); shift ;;
  esac
done
[ "${#suites[@]}" -eq 0 ] && read -r -a suites <<<"$ALL"
[ "$serial" -eq 1 ] && jobs=1

names=()
for s in "${suites[@]}"; do
  s="${s%.sh}"
  if [ ! -f "tests/$s.sh" ]; then
    printf 'no such suite: %s\n' "$s" >&2
    exit 2
  fi
  names+=("$s")
done

RUN="$BASE/codemux-tests-$$"
mkdir -p "$RUN"

failed=0
reported=0

report() { # <suite>
  local s="$1" line
  line="$(grep -E '[0-9]+ passed · [0-9]+ failed' "$RUN/$s.log" 2>/dev/null | tail -1 || true)"
  reported=$((reported + 1))
  if printf '%s' "$line" | grep -qE ' 0 failed'; then
    printf '%-16s %s\n' "$s" "${line# }"
    [ "$keep" -eq 1 ] || rm -f "$RUN/$s.log"
  else
    failed=$((failed + 1))
    printf '%-16s %s\n' "$s" "${line:-CRASHED (no summary)}"
    # The useful part of a failing suite is the FAIL line, not the tail.
    grep -E '^FAIL' "$RUN/$s.log" | sed 's/^/                 /' || true
  fi
}

# `wait -n -p` (bash 5.1+) lets a finished suite be reported while the others
# are still running. Older shells fall back to reporting everything at the end.
live=0
if [ "${BASH_VERSINFO[0]}" -gt 5 ] ||
  { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
  live=1
fi

start=$(date +%s)
if [ "$live" -eq 1 ]; then
  pids=()
  declare -A owner=()
  idx=0
  while [ "$idx" -lt "${#names[@]}" ] || [ "${#pids[@]}" -gt 0 ]; do
    while [ "$idx" -lt "${#names[@]}" ] && [ "${#pids[@]}" -lt "$jobs" ]; do
      s="${names[$idx]}"
      bash "tests/$s.sh" </dev/null >"$RUN/$s.log" 2>&1 &
      pids+=("$!")
      owner[$!]="$s"
      idx=$((idx + 1))
    done
    [ "${#pids[@]}" -eq 0 ] && break
    done_pid=""
    wait -n -p done_pid 2>/dev/null || true
    if [ -z "$done_pid" ] || [ -z "${owner[$done_pid]:-}" ]; then
      # `wait` returned without a usable pid; stop and let the tail below
      # report whatever already has a log.
      break
    fi
    report "${owner[$done_pid]}"
    unset 'owner[$done_pid]'
    rest=()
    for p in "${pids[@]}"; do [ "$p" = "$done_pid" ] || rest+=("$p"); done
    if [ "${#rest[@]}" -gt 0 ]; then pids=("${rest[@]}"); else pids=(); fi
  done
else
  pids=()
  running=0
  for s in "${names[@]}"; do
    mkdir -p "$RUN/$(dirname "$s")"
    bash "tests/$s.sh" </dev/null >"$RUN/$s.log" 2>&1 &
    pids+=("$!")
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
      running=$((running - 1))
    fi
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
  for s in "${names[@]}"; do report "$s"; done
fi
elapsed=$(( $(date +%s) - start ))

printf '\n%s suites · %s failed · %ss · logs: %s\n' "${#names[@]}" "$failed" "$elapsed" "$RUN"
[ "$failed" -eq 0 ] && rm -rf "$RUN"
[ "$failed" -eq 0 ]
