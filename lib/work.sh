#!/usr/bin/env bash
# work.sh — run agent commands in a tmux tab visible to Master, logged to ~/work.log
# usage: kerja.sh "<description>" -- <command...>
# A new tab appears in the strip (without stealing focus), output is live there,
# a full copy goes to ~/work.log. When done the tab stays open for a short
# auto-delay (KERJA_CLOSE_DELAY seconds, default 5) so Master can read the
# output, then closes itself. The caller is released as soon as the run ends.
# KERJA_SPLIT defaults to 1: the job opens as a BOTTOM SPLIT in the session's
# current window (top/bottom split screen; focus stays where it was). Parallel
# jobs tile evenly below Master's pane (select-layout main-horizontal).
# KERJA_SPLIT=0 falls back to a separate tab in the strip.
set -u

desc="${1:-}"
shift 2>/dev/null || true
[ "${1:-}" = "--" ] && shift
if [ -z "$desc" ] || [ $# -eq 0 ]; then
  echo "usage: kerja.sh <desc> -- <cmd...>" >&2
  exit 2
fi

LOG="$HOME/work.log"
TS="$(date '+%d %H:%M:%S')"
cmd="$*"
ch="work-done-$$"

# --- pick the tmux session ---
sess=""
if [ -n "${TMUX:-}" ]; then
  sess="$(tmux display-message -p '#{session_name}')"
elif tmux has-session -t pi 2>/dev/null; then
  sess=pi
elif tmux has-session -t main 2>/dev/null; then
  sess=main
fi

# --- no tmux: run directly, still logged ---
if [ -z "$sess" ]; then
  printf '\n[%s] %s\n$ %s\n' "$TS" "$desc" "$cmd" >> "$LOG"
  bash -c "$cmd" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  printf '[%s] done rc=%s\n' "$(date '+%H:%M:%S')" "$rc" >> "$LOG"
  exit "$rc"
fi

name="$(printf '%s' "$desc" | tr -cs 'A-Za-z0-9' '-' | cut -c1-14)"
[ -n "$name" ] || name=work

# --- runner: log + done signal ---
tmp="${TMPDIR:-${PREFIX:-/tmp}}"
tmp="$tmp/work-runner.$$.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'desc=%q\n' "$desc"
  printf 'cmd=%q\n' "$cmd"
  printf 'log=%q\n' "$LOG"
  printf 'ts=%q\n' "$TS"
  printf 'ch=%q\n' "$ch"
  printf 'delay=%q\n' "${KERJA_CLOSE_DELAY:-5}"
  cat <<'BODY'
printf '\n[%s] %s\n$ %s\n' "$ts" "$desc" "$cmd" | tee -a "$log"
bash -c "$cmd" 2>&1 | tee -a "$log"
rc=${PIPESTATUS[0]}
printf '[%s] done rc=%s\n' "$(date '+%H:%M:%S')" "$rc" | tee -a "$log"
tmux wait-for -S "$ch"
sleep "$delay"
exit "$rc"
BODY
} > "$tmp"

touch "$LOG"
start="$(wc -l < "$LOG")"

# -d: do not steal Master's focus; the tab/pane still shows up live
if [ "${KERJA_SPLIT:-1}" != "0" ]; then
  # bottom split in the session's current window (top/bottom split screen)
  wID="$(tmux split-window -d -v -P -t "$sess:" bash "$tmp" 2>/dev/null)" || {
    echo "kerja: failed to open tmux split pane" >&2
    rm -f "$tmp"
    exit 3
  }
  # Parallel jobs each get their own pane; main-horizontal keeps the active
  # (Master's) pane as the large top pane and tiles every work pane evenly
  # below it, instead of nesting ever-narrower halves.
  tmux select-layout -t "$sess:" main-horizontal 2>/dev/null
else
  wID="$(tmux new-window -d -P -t "$sess:" -n "$name" bash "$tmp" 2>/dev/null)" || {
    echo "kerja: failed to open tmux window" >&2
    rm -f "$tmp"
    exit 3
  }
  tmux set-option -t "$wID" automatic-rename off 2>/dev/null
fi

# wait for completion (event-driven, no sleep)
timeout "${KERJA_TIMEOUT:-1800}" tmux wait-for "$ch" 2>/dev/null || {
  echo "kerja: timed out waiting for completion (pane still open, log: $LOG)"
  exit 124
}
rm -f "$tmp"

# emit this run's slice of the log as output
tail -n +"$((start + 1))" "$LOG"
