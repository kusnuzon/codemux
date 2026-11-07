# shellcheck shell=bash
# lib/state.sh — module state, install progress (run.tsv), lock, log.
# All writes go through a temp file + mv (atomic).

CODEMUX_STATE_HEADER='# ts	module	status	version	note'

codemux_state_init() {
  mkdir -p "$CODEMUX_HOME" "$CODEMUX_HOME/logs" "$CODEMUX_HOME/backup" "$CODEMUX_HOME/run" 2>/dev/null || return 1
  [ -f "$CODEMUX_HOME/state.tsv" ] || printf '%s\n' "$CODEMUX_STATE_HEADER" >"$CODEMUX_HOME/state.tsv"
}

# codemux_state_set <module> <status> <version> <note...>
codemux_state_set() {
  local mod="$1" status="$2" ver="${3:--}" note="${4:-}"
  [ -f "$CODEMUX_HOME/state.tsv" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M')" "$mod" "$status" "$ver" \
    "$(printf '%s' "$note" | tr '\t\n' '  ')" >>"$CODEMUX_HOME/state.tsv"
}

codemux_state_get() {
  [ -f "$CODEMUX_HOME/state.tsv" ] || return 0
  awk -F'\t' -v m="$1" '!/^#/ && $2==m {s=$3} END{print s}' "$CODEMUX_HOME/state.tsv"
}

# --- boot identity (detects a device reboot while a process is dead) ---------
codemux_boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id
  else
    local up
    up="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
    echo $(( $(date +%s) - up ))
  fi
}

# --- run.tsv: installation progress -----------------------------------------
# module  status  pid  boot  started  finished  note
codemux_run_file() { printf '%s/run.tsv' "$CODEMUX_HOME"; }

codemux_run_reset() {
  local f m
  f="$(codemux_run_file)"
  mkdir -p "$CODEMUX_HOME" || return 1
  {
    printf '# module\tstatus\tpid\tboot\tstarted\tfinished\tnote\n'
    for m in "$@"; do
      printf '%s\tPENDING\t-\t-\t-\t-\t-\n' "$m"
    done
  } >"$f.new" && mv -f "$f.new" "$f"
}

codemux_run_get() {
  local f
  f="$(codemux_run_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v m="$1" '!/^#/ && $1==m {print $2}' "$f"
}

# codemux_run_set <module> <status> [note]
codemux_run_set() {
  local m="$1" st="$2" note="${3:-}" f tmp boot now
  f="$(codemux_run_file)"
  [ -f "$f" ] || return 0
  boot="$(codemux_boot_id)"
  now="$(date '+%H:%M:%S')"
  tmp="$f.new"
  awk -F'\t' -v OFS='\t' -v m="$m" -v st="$st" \
    -v note="$(printf '%s' "$note" | tr '\t\n' '  ')" \
    -v pid="$$" -v boot="$boot" -v now="$now" '
    /^#/ { print; next }
    $1 == m {
      $2 = st; $3 = pid; $4 = boot
      if ($5 == "-") $5 = now
      if (st == "DONE" || st == "FAILED" || st == "SKIP" || st == "INTERRUPTED") $6 = now
      $7 = note
      print; next
    }
    { print }' "$f" >"$tmp" && mv -f "$tmp" "$f"
}

# Mark RUNNING steps whose process is already gone as INTERRUPTED.
codemux_run_reconcile() {
  local f boot m st pid pboot _rest
  f="$(codemux_run_file)"
  [ -f "$f" ] || return 0
  boot="$(codemux_boot_id)"
  while IFS=$'\t' read -r m st pid pboot _rest; do
    case "$m" in '' | \#*) continue ;; esac
    [ "$st" = "RUNNING" ] || continue
    if [ "$pboot" != "$boot" ] || ! kill -0 "$pid" 2>/dev/null; then
      if [ "$pboot" != "$boot" ]; then
        codemux_run_set "$m" INTERRUPTED "interrupted (device reboot)"
      else
        codemux_run_set "$m" INTERRUPTED "interrupted (pid $pid died)"
      fi
    fi
  done <"$f"
  return 0
}

codemux_run_summary() {
  local f
  f="$(codemux_run_file)"
  [ -f "$f" ] || return 1
  awk -F'\t' '!/^#/ {n++; c[$2]++} END {
    printf "  %d steps:", n
    for (s in c) printf " %s=%d", s, c[s]
    printf "\n"
  }' "$f"
}

# --- lock: prevent two parallel installs, discard a stale lock ---------------
# 0 = lock acquired · 1 = genuinely busy · 2 = cannot write
codemux_lock_acquire() {
  local dir="$CODEMUX_HOME/lock" pid="" boot cboot=""
  mkdir -p "$CODEMUX_HOME" 2>/dev/null || return 2
  boot="$(codemux_boot_id)"
  if [ -f "$dir/pid" ]; then
    pid="$(cat "$dir/pid" 2>/dev/null || echo 0)"
    cboot="$(cat "$dir/boot" 2>/dev/null || echo -)"
    if [ "$cboot" = "$boot" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    rm -rf "$dir" 2>/dev/null || true
  fi
  mkdir "$dir" 2>/dev/null || return 1
  printf '%s\n' "$$" >"$dir/pid"
  printf '%s\n' "$boot" >"$dir/boot"
  return 0
}

codemux_lock_release() { rm -rf "$CODEMUX_HOME/lock" 2>/dev/null || true; }

codemux_lock_info() {
  local dir="$CODEMUX_HOME/lock" pid boot
  [ -f "$dir/pid" ] || { printf 'none\n'; return 0; }
  pid="$(cat "$dir/pid" 2>/dev/null || echo 0)"
  boot="$(cat "$dir/boot" 2>/dev/null || echo -)"
  if [ "$boot" = "$(codemux_boot_id)" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'active (pid %s)\n' "$pid"
  else
    printf 'stale (pid %s, will be discarded automatically)\n' "$pid"
  fi
}

# --- per-run log -------------------------------------------------------------
codemux_log_start() {
  mkdir -p "$CODEMUX_HOME/logs" 2>/dev/null || return 0
  CODEMUX_LOG="$CODEMUX_HOME/logs/$(date '+%Y%m%d-%H%M%S').log"
  : >"$CODEMUX_LOG"
  chmod 600 "$CODEMUX_LOG" 2>/dev/null || true
  printf '%s v%s · %s · pid %s\n' "$CODEMUX_NAME" "$CODEMUX_VERSION" "$(date)" "$$" >>"$CODEMUX_LOG"
}

codemux_log_latest() {
  ls -1t "$CODEMUX_HOME"/logs/*.log 2>/dev/null | head -n 1 || true
  return 0
}
