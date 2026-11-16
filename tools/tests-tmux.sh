#!/usr/bin/env bash
# tools/tests-tmux.sh — run the suites in one tmux window each, all at once.
#
# Every suite gets its own window, so all of them run in parallel (total time is
# the slowest suite, not the sum) and each window shows that suite's own output
# live. The `summary` window waits for the others and prints one line per suite.
# The wrapper returns immediately: nobody has to sit in front of a silent log.
#
#   bash tools/tests-tmux.sh                 # all suites, session codemux-tests
#   bash tools/tests-tmux.sh smoke resume    # only these suites
#   bash tools/tests-tmux.sh --attach        # start, then attach (needs a tty)
#   bash tools/tests-tmux.sh --wait          # block until done, exit with the result
#   bash tools/tests-tmux.sh --status        # 0 pass · 1 fail · 2 running · 3 no run
#   bash tools/tests-tmux.sh --kill          # stop the session
#
# Switching windows: Ctrl-b n (next), Ctrl-b p (previous), Ctrl-b 0..9 directly.
# For a single pane with the same summary, use tools/run-tests.sh instead.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${CODEMUX_TEST_TMP:-${TMPDIR:-/tmp}}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi

NAME="${CODEMUX_TEST_SESSION:-codemux-tests}"
STATUS="$BASE/$NAME.status"
ALL="smoke launcher-memory maintenance resume release adapter tmuxconf tabctl"

attach=0
wait_mode=0
suites=()
while [ $# -gt 0 ]; do
  case "$1" in
    -a | --attach) attach=1; shift ;;
    -w | --wait) wait_mode=1; shift ;;
    --status)
      if [ -f "$STATUS" ]; then
        if [ "$(cat "$STATUS" 2>/dev/null)" = 0 ]; then printf 'passed\n'; exit 0; fi
        printf 'failed\n'
        exit 1
      fi
      if tmux has-session -t "$NAME" 2>/dev/null; then printf 'running\n'; exit 2; fi
      printf 'no run\n'
      exit 3
      ;;
    --kill)
      tmux kill-session -t "$NAME" 2>/dev/null || true
      printf 'stopped %s\n' "$NAME"
      exit 0
      ;;
    -h | --help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) suites+=("$1"); shift ;;
  esac
done
[ "${#suites[@]}" -eq 0 ] && read -r -a suites <<<"$ALL"

names=()
for s in "${suites[@]}"; do
  s="${s%.sh}"
  if [ ! -f "tests/$s.sh" ]; then
    printf 'no such suite: %s\n' "$s" >&2
    exit 2
  fi
  names+=("$s")
done

if ! command -v tmux >/dev/null 2>&1; then
  printf 'tmux is missing — it is part of the codemux toolset (pkg install tmux)\n' >&2
  exit 1
fi

# One run per session name: leftovers would hide the new output.
tmux kill-session -t "$NAME" 2>/dev/null || true
rm -f "$STATUS"

CHANNEL="$NAME-finished"
RUN="$BASE/$NAME.d"
rm -rf "$RUN"
mkdir -p "$RUN"
printf '%s\n' "${#names[@]}" >"$RUN/total"
date +%s >"$RUN/start"

# The summary window waits for every suite to drop its .rc file, then reports.
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -u\nRUN=%q\nSTATUS=%q\nCHANNEL=%q\n' "$RUN" "$STATUS" "$CHANNEL"
  printf 'names=('
  for s in "${names[@]}"; do printf ' %q' "$s"; done
  printf ' )\n'
  cat <<'EOS'
total=${#names[@]}
while :; do
  n=0
  for s in "${names[@]}"; do [ -f "$RUN/$s.rc" ] && n=$((n + 1)); done
  [ "$n" -ge "$total" ] && break
  sleep 1
done
failed=0
for s in "${names[@]}"; do
  line="$(grep -E '[0-9]+ passed · [0-9]+ failed' "$RUN/$s.log" 2>/dev/null | tail -1 || true)"
  if printf '%s' "$line" | grep -qE ' 0 failed'; then
    printf '%-16s %s\n' "$s" "${line# }"
  else
    failed=$((failed + 1))
    printf '%-16s %s\n' "$s" "${line:-CRASHED (no summary)}"
    grep -E '^FAIL' "$RUN/$s.log" | sed 's/^/                 /' || true
  fi
done
elapsed=$(( $(date +%s) - $(cat "$RUN/start" 2>/dev/null || echo 0) ))
printf '\n%s suites · %s failed · %ss · logs: %s\n' "$total" "$failed" "$elapsed" "$RUN"
if [ "$failed" -eq 0 ]; then printf '0\n' >"$STATUS"; else printf '1\n' >"$STATUS"; fi
tmux wait-for -S "$CHANNEL" 2>/dev/null || true
printf '\n— finished. Ctrl-b n/p to switch windows, Ctrl-b d to detach.\n'
exec sleep infinity
EOS
} >"$RUN/summary.sh"
chmod +x "$RUN/summary.sh"

tmux new-session -d -s "$NAME" -n summary -x 120 -y 40 "bash $(printf '%q' "$RUN/summary.sh")"

for s in "${names[@]}"; do
  # pipefail so the .rc holds the suite's status, not tee's.
  inner="set -o pipefail; cd $(printf '%q' "$ROOT")"
  inner+=" && bash $(printf '%q' "tests/$s.sh") </dev/null 2>&1 | tee $(printf '%q' "$RUN/$s.log")"
  inner+="; printf '%s\\n' \"\$?\" > $(printf '%q' "$RUN/$s.rc"); exec sleep infinity"
  tmux new-window -d -t "$NAME" -n "$s" "$inner"
done

printf 'running %s suite(s) in tmux session "%s" — one window each, in parallel\n' \
  "${#names[@]}" "$NAME"
printf '  watch live : tmux attach -t %s\n' "$NAME"
printf '  summary    : tmux attach -t %s:%s\n' "$NAME" summary
printf '  log files  : %s\n' "$RUN"
printf '  ask status : bash tools/tests-tmux.sh --status\n'

# --wait blocks on a tmux channel the summary window signals, so a caller never
# polls with sleeps. A finished run answers immediately from the status file.
if [ "$wait_mode" -eq 1 ]; then
  if [ ! -f "$STATUS" ]; then
    tmux wait-for "$CHANNEL"
  fi
  tmux capture-pane -p -t "$NAME:summary" 2>/dev/null | grep -v '^$' | grep -v '^— finished' || true
  if [ "$(cat "$STATUS" 2>/dev/null)" = 0 ]; then exit 0; fi
  exit 1
fi

if [ "$attach" -eq 1 ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    exec tmux attach -t "$NAME"
  fi
  printf 'not a terminal — attach from a real one: tmux attach -t %s\n' "$NAME"
fi
