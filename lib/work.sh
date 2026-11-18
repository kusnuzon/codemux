#!/usr/bin/env bash
# work.sh — run agent commands in a tmux pane visible to Master, logged to ~/work.log
# usage: work.sh "<description>" -- <command...>
#        work.sh --console   (show the console now, without running a job)
#
# Display modes (KERJA_SPLIT):
#   unset      console (default): ONE persistent bottom pane — the "agent
#              console" — streams every command live. The pane follows the
#              window Master is looking at (join-pane) and is shared by every
#              job. Best for watching the work. The console closes itself
#              once the agent (pi runs as `node`) is gone from the session,
#              so it never lingers under the menu after Master quits; the
#              next job recreates it.
#   1          one-shot bottom split, closes KERJA_CLOSE_DELAY seconds after
#              the job finishes (the old behaviour; use for parallel jobs).
#   0          one-shot tab in the strip, same close delay.
# A full copy of every run lands in ~/work.log. The caller is released as
# soon as the run ends (event-driven tmux wait-for, no sleeping).
set -u

CONSOLE_ONLY=0
if [ "${1:-}" = "--console" ]; then
  CONSOLE_ONLY=1
  shift
else
  desc="${1:-}"
  shift 2>/dev/null || true
  [ "${1:-}" = "--" ] && shift
  if [ -z "$desc" ] || [ $# -eq 0 ]; then
    echo "usage: work.sh <desc> -- <cmd...> | work.sh --console" >&2
    exit 2
  fi
fi

LOG="$HOME/work.log"
TS="$(date '+%d %H:%M:%S')"
cmd="$*"
ch="work-done-$$"
tmp="${TMPDIR:-${PREFIX:-/tmp}}"
wID=""
cpid=""
cwin=""

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
  # --console without tmux has nothing to show; a plain run still logs.
  [ "$CONSOLE_ONLY" -eq 1 ] && exit 0
  printf '\n[%s] %s\n$ %s\n' "$TS" "$desc" "$cmd" >> "$LOG"
  bash -c "$cmd" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  printf '[%s] done rc=%s\n' "$(date '+%H:%M:%S')" "$rc" >> "$LOG"
  exit "$rc"
fi

# Nested call (a job running inside the console called work.sh again): the
# console runner is busy with THIS job and cannot read the fifo for the nested
# one, so dispatching would deadlock the whole chain — run directly, log only.
if [ -n "${WORK_NESTED:-}" ]; then
  [ "$CONSOLE_ONLY" -eq 1 ] && exit 0
  printf '\n[%s] %s\n$ %s\n' "$TS" "$desc" "$cmd" >> "$LOG"
  bash -c "$cmd" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  printf '[%s] done rc=%s\n' "$(date '+%H:%M:%S')" "$rc" >> "$LOG"
  exit "$rc"
fi

name="$(printf '%s' "$desc" | tr -cs 'A-Za-z0-9' '-' | cut -c1-14)"
[ -n "$name" ] || name=work

# Console state is PER SESSION: several sessions can each carry their own
# console (e.g. the agent session and a test session), and a single global
# pane file made one session's watchdog read another session's pane id.
RUNNER="$tmp/agent-console.runner.sh"
FIFO="$tmp/agent-console-$sess.fifo"
PANE_FILE="$tmp/agent-console-$sess.pane"
STATE="$tmp/agent-console-$sess.state"

# the pane Master was using before this job — focus always returns there, so
# typing never lands in the console pane. If focus is already stuck on the
# console (e.g. left over from an older run), fall back to the pane at the top
# of the window — main-horizontal keeps Master's pane there — or any pane that
# is not the console. The last good target is also remembered in a state file
# for the case where the active pane cannot be read at all.
opane="$(tmux display-message -p -t "$sess:" '#{pane_id}' 2>/dev/null)"
conpid="$(cat "$PANE_FILE" 2>/dev/null)"
if [ -n "$conpid" ] && [ "$opane" = "$conpid" ]; then
  opane="$(tmux list-panes -t "$sess:" -F '#{pane_at_top} #{pane_id}' 2>/dev/null \
    | grep '^1 ' | head -1 | cut -d' ' -f2)"
  if [ -z "$opane" ]; then
    opane="$(tmux list-panes -t "$sess:" -F '#{pane_id}' 2>/dev/null \
      | grep -vx "$conpid" | head -1)"
  fi
fi
[ -n "$opane" ] || opane="$(cat "$tmp/agent-master-$sess.pane" 2>/dev/null)"

restore_focus() {
  if [ -n "$opane" ] && tmux select-pane -t "$opane" 2>/dev/null; then
    # remember the last good target for the next run
    printf '%s' "$opane" > "$tmp/agent-master-$sess.pane"
  fi
  return 0
}

# --- the one runner for both display modes ------------------------------------
# Console mode (no --once): loops, reading job-file paths from the fifo. The
# fifo is reopened every iteration, so waiting for the next job blocks in the
# kernel instead of spinning the CPU. One-shot mode (--once <jobfile>): runs a
# single job, lingers KERJA_CLOSE_DELAY seconds, exits.
# Written to a temp file and moved into place: a running console keeps its old
# inode, so refreshing the runner never pulls the file out from under it (an
# in-place rewrite makes bash read fragments of the NEW file — a real bug we
# hit before).
cat > "$RUNNER.new.$$" <<'BODY'
#!/usr/bin/env bash
# agent work runner — shared by the persistent console and one-shot panes.
set -u
plain_log() { printf '%s\n' "$1" >> "$log"; }
state="${AGENT_CONSOLE_STATE:-}"
run_job() {
  # the job file sets: desc cmd log ts ch
  . "$1" || return 0
  local start rc dur cmdline
  [ -n "$state" ] && printf busy > "$state"
  start=$SECONDS
  printf '\033[38;2;159;184;208m◆ %s\033[0m \033[2m%s\033[0m\n' "$desc" "$ts"
  cmdline="\$ $cmd"
  plain_log "[$ts] $desc"
  plain_log "$cmdline"
  if [ "${#cmdline}" -gt 110 ]; then
    printf '\033[2m%s…\033[0m\n' "${cmdline:0:107}"
  else
    printf '\033[2m%s\033[0m\n' "$cmdline"
  fi
  WORK_NESTED=1 bash -c "$cmd" 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  dur=$((SECONDS - start))
  plain_log "[$(date '+%H:%M:%S')] done rc=$rc (${dur}s)"
  if [ "$rc" -eq 0 ]; then
    printf '\033[38;2;143;191;127m✔ done rc=%s · %ss\033[0m\n' "$rc" "$dur"
  else
    printf '\033[38;2;224;128;128m✖ done rc=%s · %ss\033[0m\n' "$rc" "$dur"
  fi
  rm -f "$1"
  [ -n "$state" ] && printf idle > "$state"
  tmux wait-for -S "$ch" 2>/dev/null
  return "$rc"
}
if [ "${1:-}" = "--once" ]; then
  run_job "$2"
  sleep "${KERJA_CLOSE_DELAY:-5}"
  exit 0
fi
fifo="${AGENT_CONSOLE_FIFO:?}"
# Auto-close watcher: the console follows the agent, and pi runs as `node`.
# When no pane in this session runs node anymore — Master quit free-pi — the
# console closes itself instead of lingering under the menu. The first check
# waits longer than the others so a slow agent start is not mistaken for an
# exit, and the busy flag keeps a running job from being killed mid-run.
self="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
# -t "$self" is REQUIRED: a bare display-message in a detached pane resolves
# against the server's CURRENT session/pane (Master's!), which made this
# watcher kill the wrong pane.
sess_name="$(tmux display-message -p -t "$self" '#{session_name}' 2>/dev/null)"
agent_alive() {
  [ -n "$sess_name" ] || return 1
  tmux list-panes -a -F '#{session_name} #{pane_current_command}' 2>/dev/null |
    grep -q "^$sess_name node\$"
}
(
  sleep "${KERJA_CONSOLE_GRACE:-10}"
  while :; do
    if [ "$(cat "$state" 2>/dev/null)" != busy ] && ! agent_alive; then
      sleep "${KERJA_CLOSE_DELAY:-5}"
      if [ "$(cat "$state" 2>/dev/null)" != busy ] && ! agent_alive; then
        tmux kill-pane -t "$self" 2>/dev/null
        exit 0
      fi
    fi
    sleep 5
  done
) &
while :; do
  if IFS= read -r job < "$fifo"; then
    [ -n "$job" ] && [ -f "$job" ] && run_job "$job"
  else
    # fifo removed or writer vanished: never spin on a failed open/read
    sleep 1
  fi
done
BODY
mv "$RUNNER.new.$$" "$RUNNER"

# --- job file (shared by every mode) ------------------------------------------
jobfile=""
if [ "$CONSOLE_ONLY" -eq 0 ]; then
  jobfile="$tmp/work-job.$$.sh"
  {
    printf 'desc=%q\n' "$desc"
    printf 'cmd=%q\n' "$cmd"
    printf 'log=%q\n' "$LOG"
    printf 'ts=%q\n' "$TS"
    printf 'ch=%q\n' "$ch"
  } > "$jobfile"

  touch "$LOG"
  start="$(wc -l < "$LOG")"
fi

# --- display helpers ------------------------------------------------------------
# A job that opens no pane is invisible to Master AND leaves no trace in the
# log, so every failure to display is recorded here.
display_failed() {
  printf '[%s] %s\n[work] job NOT displayed: no tmux split/tab could be opened\n' \
    "$(date '+%H:%M:%S')" "$desc" >> "$LOG"
  rm -f "$jobfile"
  exit 3
}

open_tab() {
  wID="$(tmux new-window -d -P -t "$sess:" -n "$name" bash "$RUNNER" --once "$jobfile" 2>/dev/null)" || return 1
  tmux set-option -t "$wID" automatic-rename off 2>/dev/null
  return 0
}

# retile — Master's pane stays the big top pane, work panes tile below it.
retile() {
  local wh bh
  wh="$(tmux display-message -p -t "$sess:" '#{window_height}' 2>/dev/null)"
  case "$wh" in ''|*[!0-9]*) wh=0 ;; esac
  bh=$(( wh / 6 )); [ "$bh" -lt 4 ] && bh=4
  tmux set-option -t "$sess:" main-pane-height "$(( wh - bh ))" 2>/dev/null
  tmux select-layout -t "$sess:" main-horizontal 2>/dev/null
}

open_split() {
  wID="$(tmux split-window -d -v -P -t "$sess:" bash "$RUNNER" --once "$jobfile" 2>/dev/null)" || return 1
  retile
  return 0
}

# --- console (default mode) -----------------------------------------------------
console_alive() {
  local info line
  if [ -f "$PANE_FILE" ]; then
    cpid="$(cat "$PANE_FILE" 2>/dev/null)"
    if [ -n "$cpid" ]; then
      info="$(tmux display-message -p -t "$cpid" '#{pane_dead} #{session_name} #{window_id}' 2>/dev/null)" || info=""
      if [ -n "$info" ]; then
        set -- $info
        if [ "${1:-1}" = "0" ] && [ "${2:-}" = "$sess" ]; then
          cwin="${3:-}"
          return 0
        fi
      fi
    fi
  fi
  # The pane file is missing or stale, but the console may still be alive —
  # creating a second one is how duplicate consoles piled up. Adopt the live
  # pane carrying the @agent-console marker instead.
  line="$(tmux list-panes -t "$sess:" -F '#{pane_dead} #{pane_id} #{window_id} #{@agent-console}' 2>/dev/null \
    | grep '^0 ' | grep ' 1$' | head -1)"
  [ -n "$line" ] || return 1
  cpid="$(printf '%s' "$line" | cut -d' ' -f2)"
  cwin="$(printf '%s' "$line" | cut -d' ' -f3)"
  printf '%s' "$cpid" > "$PANE_FILE"
  return 0
}

console_ensure() {
  console_alive && return 0
  [ -p "$FIFO" ] || mkfifo "$FIFO" 2>/dev/null || return 1
  cpid="$(tmux split-window -d -v -P -e "AGENT_CONSOLE_FIFO=$FIFO" \
    -e "AGENT_CONSOLE_STATE=$STATE" \
    -t "$sess:" bash "$RUNNER" 2>/dev/null)" || cpid=""
  if [ -n "$cpid" ]; then
    retile
  else
    # no room for a split (window too short / too many panes): the console
    # becomes its own strip tab instead of not existing at all.
    cpid="$(tmux new-window -d -P -e "AGENT_CONSOLE_FIFO=$FIFO" \
      -e "AGENT_CONSOLE_STATE=$STATE" \
      -t "$sess:" -n console bash "$RUNNER" 2>/dev/null)" || return 1
    tmux set-option -t "$cpid" automatic-rename off 2>/dev/null
  fi
  # -P prints a positional address (main:0.2) that goes stale as soon as
  # panes are retiled — store the stable %N pane id instead.
  cpid="$(tmux display-message -p -t "$cpid" '#{pane_id}' 2>/dev/null)"
  [ -n "$cpid" ] || return 1
  tmux set-option -p -t "$cpid" @agent-console 1 2>/dev/null
  printf '%s' "$cpid" > "$PANE_FILE"
  return 0
}

console_follow() {
  # move the console into the window Master is looking at right now, so the
  # stream is always on screen.
  local cur
  cur="$(tmux display-message -p -t "$sess:" '#{window_id}' 2>/dev/null)"
  if [ -n "$cur" ] && [ -n "$cwin" ] && [ "$cwin" != "$cur" ]; then
    tmux join-pane -s "$cpid" -t "$sess:" >/dev/null 2>&1
  fi
  retile
}

# --- dispatch ---------------------------------------------------------------------
mode="${KERJA_SPLIT:-}"
if [ "$CONSOLE_ONLY" -eq 1 ]; then
  # Show the console right now, without running a job — the launcher calls
  # this before starting the agent so the pane is visible from second one.
  if console_ensure; then
    console_follow
    tmux select-pane -t "$cpid" -P 'fg=#c8ccd0,bg=#11100E' 2>/dev/null
    restore_focus
  fi
  exit 0
fi
if [ -z "$mode" ]; then
  if console_ensure; then
    console_follow
    tmux select-pane -t "$cpid" -P 'fg=#c8ccd0,bg=#11100E' 2>/dev/null
    restore_focus
    printf '%s\n' "$jobfile" > "$FIFO"
  else
    open_tab || display_failed
  fi
elif [ "$mode" = "1" ]; then
  open_split || open_tab || display_failed
  restore_focus
else
  open_tab || display_failed
  restore_focus
fi

# soften one-shot panes too: gentle gray on the warm near-black theme
[ -n "$wID" ] && tmux select-pane -t "$wID" -P 'fg=#c8ccd0,bg=#11100E' 2>/dev/null

# wait for completion (event-driven). Watchdog: if the pane running the job
# dies mid-job (e.g. a job killed its own console), the done signal never
# comes — detect that and report instead of hanging until KERJA_TIMEOUT.
pane_gone() {
  if [ -z "$mode" ]; then
    console_alive && return 1
    return 0
  fi
  if [ -n "$wID" ]; then
    [ "$(tmux display-message -p -t "$wID" '#{pane_dead}' 2>/dev/null)" = "0" ] && return 1
    return 0
  fi
  return 1
}
deadline=$(( $(date +%s) + ${KERJA_TIMEOUT:-1800} ))
while :; do
  if timeout 2 tmux wait-for "$ch" 2>/dev/null; then break; fi
  if pane_gone; then
    printf '[%s] [work] display pane died mid-job — done signal lost, run interrupted\n' \
      "$(date '+%H:%M:%S')" >> "$LOG"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "work: timed out waiting for completion (log: $LOG)"
    exit 124
  fi
done
rm -f "$jobfile"

# give the keyboard back to Master's pane
restore_focus

# emit this run's slice of the log as output
tail -n +"$((start + 1))" "$LOG"
