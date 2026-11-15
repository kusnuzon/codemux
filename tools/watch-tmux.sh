#!/usr/bin/env bash
# tools/watch-tmux.sh — run any long command in tmux and wait for it without sleeping.
#
# Waiting for a build, a CI run or an install by polling with `sleep` is blind:
# it wastes time when the job ends early and hides output when it fails. This
# runs the command in a tmux window, tee's the output to a log, and blocks on a
# tmux channel that the command signals when it is done. Same wall time as
# running it in the foreground, but the run is watchable from another terminal.
#
#   bash tools/watch-tmux.sh -n ci -- gh run watch 12345 --exit-status
#   bash tools/watch-tmux.sh -n install -- codemux upgrade --yes
#   bash tools/watch-tmux.sh -n tests -- bash tools/run-tests.sh
#
# Options: -n NAME (session/log name, default "watch"), -q (quiet, print nothing).
# Exit status is the command's own. While it runs, another terminal can watch:
#   tmux attach -t codemux-<name>
# The session is closed as soon as the command exits; the log stays.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${CODEMUX_TEST_TMP:-${TMPDIR:-/tmp}}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi

NAME="watch"
quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n)
      NAME="$2"
      shift 2 ;;
    -q | --quiet) quiet=1; shift ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --)
      shift
      break ;;
    *)
      printf 'unknown option: %s (put the command after --)\n' "$1" >&2
      exit 2 ;;
  esac
done
[ "$#" -gt 0 ] || { printf 'nothing to run — usage: watch-tmux.sh -n NAME -- cmd args...\n' >&2; exit 2; }

command -v tmux >/dev/null 2>&1 || { printf 'tmux is missing\n' >&2; exit 1; }

LOG="$BASE/$NAME.log"
RC="$BASE/$NAME.rc"
CHANNEL="$NAME-finished"
SESSION="codemux-$NAME"

tmux kill-session -t "$SESSION" 2>/dev/null || true
rm -f "$LOG" "$RC"

inner="set -o pipefail; cd $(printf '%q' "$ROOT") &&"
for a in "$@"; do inner+=" $(printf '%q' "$a")"; done
inner+=" </dev/null 2>&1 | tee $(printf '%q' "$LOG")"
inner+="; rc=\$?; printf '%s\\n' \"\$rc\" > $(printf '%q' "$RC")"
inner+="; tmux wait-for -S $(printf '%q' "$CHANNEL") 2>/dev/null || true; exec sleep infinity"

tmux new-session -d -s "$SESSION" -x 120 -y 40 "$inner"
[ "$quiet" -eq 0 ] && printf 'running in %s — watch: tmux attach -t %s\n' "$SESSION" "$SESSION" >&2

tmux wait-for "$CHANNEL"

rc=1
[ -f "$RC" ] && rc="$(cat "$RC")"
# One run per name: leave nothing behind once the answer is known.
tmux kill-session -t "$SESSION" 2>/dev/null || true
if [ "$quiet" -eq 0 ]; then
  printf '\n' >&2
  cat "$LOG" 2>/dev/null || true
  printf '\n— %s exited %s · log: %s\n' "$NAME" "$rc" "$LOG" >&2
fi
exit "$rc"
