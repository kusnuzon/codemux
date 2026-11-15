#!/usr/bin/env bash
# tools/tests-tmux.sh — run the suites inside tmux so the progress is watchable.
#
# pi cannot show a long command's output while it runs, and a plain log file
# stays silent until the run ends. A detached tmux session fixes both: the run
# happens in a real terminal the user can attach to, and every suite appears as
# it finishes. The wrapper returns immediately, so nobody waits on a blind log.
#
#   bash tools/tests-tmux.sh                 # all suites, session codemux-tests
#   bash tools/tests-tmux.sh smoke resume    # only these suites
#   bash tools/tests-tmux.sh --attach        # start, then attach (needs a tty)
#   bash tools/tests-tmux.sh --status        # 0 pass · 1 fail · 2 running · 3 no run
#   bash tools/tests-tmux.sh --kill          # stop the session
#
# Extra flags after the suites (for example -j1, -k) go to run-tests.sh.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${CODEMUX_TEST_TMP:-${TMPDIR:-/tmp}}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi

NAME="${CODEMUX_TEST_SESSION:-codemux-tests}"
LOG="$BASE/$NAME.log"
STATUS="$BASE/$NAME.status"
PANE_SIZE="120x40"

attach=0
args=()

status_text() {
  if [ -f "$STATUS" ]; then
    case "$(cat "$STATUS" 2>/dev/null)" in
      0) printf 'passed\n' ;;
      *) printf 'failed\n' ;;
    esac
  elif tmux has-session -t "$NAME" 2>/dev/null; then
    printf 'running\n'
  else
    printf 'no run\n'
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -a | --attach) attach=1; shift ;;
    --status)
      printf '%s\n' "$(status_text)"
      case "$(status_text)" in
        passed) exit 0 ;;
        failed) exit 1 ;;
        running) exit 2 ;;
        *) exit 3 ;;
      esac
      ;;
    --kill)
      tmux kill-session -t "$NAME" 2>/dev/null || true
      printf 'stopped %s\n' "$NAME"
      exit 0
      ;;
    -h | --help)
      sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) args+=("$1"); shift ;;
  esac
done

if ! command -v tmux >/dev/null 2>&1; then
  printf 'tmux is missing — installing it is part of the codemux toolset (pkg install tmux)\n' >&2
  exit 1
fi

# One run per session name: an old session would hide the new output.
tmux kill-session -t "$NAME" 2>/dev/null || true
rm -f "$LOG" "$STATUS"

# Build the inner command with %q so suite names and flags survive the extra
# shell layer tmux adds. pipefail makes the recorded status the suite's own,
# not tee's.
inner="set -o pipefail; cd $(printf '%q' "$ROOT") && bash tools/run-tests.sh"
for a in "${args[@]}"; do inner+=" $(printf '%q' "$a")"; done
inner+=" 2>&1 | tee $(printf '%q' "$LOG"); rc=\$?; printf '%s\\n' \"\$rc\" > $(printf '%q' "$STATUS")"
inner+="; printf '\\n— run finished (status %s). Ctrl-b d to detach.\\n' \"\$rc\"; exec sleep infinity"

tmux new-session -d -s "$NAME" -x "${PANE_SIZE%x*}" -y "${PANE_SIZE#*x}" "$inner"

printf 'running in tmux session "%s"\n' "$NAME"
printf '  watch live : tmux attach -t %s\n' "$NAME"
printf '  log file   : %s\n' "$LOG"
printf '  ask status : bash tools/tests-tmux.sh --status\n'

if [ "$attach" -eq 1 ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    exec tmux attach -t "$NAME"
  fi
  printf 'not a terminal — attach from a real one: tmux attach -t %s\n' "$NAME"
fi
