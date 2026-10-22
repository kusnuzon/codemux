# shellcheck shell=bash
# lib/state.sh — state TSV, lock, dan log (tanpa dependensi jq/python).

codemux_state_init() {
  mkdir -p "$CODEMUX_HOME" "$CODEMUX_HOME/logs" "$CODEMUX_HOME/backup" 2>/dev/null || return 1
  local f="$CODEMUX_HOME/state.tsv"
  [ -f "$f" ] || printf '# ts\tmodul\tstatus\tversi\tcatatan\n' >"$f"
}

# codemux_state_set <modul> <status> <versi> <catatan...>
codemux_state_set() {
  local mod="$1" status="$2" ver="${3:--}" note="${4:-}"
  [ -f "$CODEMUX_HOME/state.tsv" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M')" "$mod" "$status" "$ver" \
    "$(printf '%s' "$note" | tr '\t\n' '  ')" >>"$CODEMUX_HOME/state.tsv"
}

# codemux_state_get <modul> -> status terakhir (kosong kalau belum ada)
codemux_state_get() {
  [ -f "$CODEMUX_HOME/state.tsv" ] || return 0
  awk -F'\t' -v m="$1" '!/^#/ && $2==m {s=$3} END{print s}' "$CODEMUX_HOME/state.tsv"
}

# Lock sederhana (mkdir atomik). Mengembalikan 1 kalau sudah ada proses lain.
codemux_lock() {
  mkdir -p "$CODEMUX_HOME" 2>/dev/null
  if ! mkdir "$CODEMUX_HOME/lock" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$$" >"$CODEMUX_HOME/lock/pid"
  return 0
}

codemux_unlock() {
  rm -f "$CODEMUX_HOME/lock/pid" 2>/dev/null || true
  rmdir "$CODEMUX_HOME/lock" 2>/dev/null || true
}

# Log per-run: codemux_log_start -> menyimpan path ke CODEMUX_LOG
codemux_log_start() {
  mkdir -p "$CODEMUX_HOME/logs" 2>/dev/null || return 0
  CODEMUX_LOG="$CODEMUX_HOME/logs/$(date '+%Y%m%d-%H%M%S').log"
  : >"$CODEMUX_LOG"
  chmod 600 "$CODEMUX_LOG" 2>/dev/null || true
  printf '%s v%s · %s\n' "$CODEMUX_NAME" "$CODEMUX_VERSION" "$(date)" >>"$CODEMUX_LOG"
}
