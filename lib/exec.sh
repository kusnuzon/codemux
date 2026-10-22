# shellcheck shell=bash
# lib/exec.sh — eksekusi tahan-mati: spawn detached, wait, tulis atomik, backup.

codemux_run_dir() { printf '%s/run' "$CODEMUX_HOME"; }

# --- tulis atomik ------------------------------------------------------------
# Pakai: printf 'isi\n' | codemux_atomic_write /path/file
codemux_atomic_write() {
  local dest="$1" dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.codemux.XXXXXX" 2>/dev/null)" || return 1
  if cat >"$tmp"; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"
    return 1
  fi
}

# --- backup -----------------------------------------------------------------
# Pakai: bak="$(codemux_backup mirror /path/file)"
codemux_backup() {
  local tag="$1" src="$2" dir dest
  [ -e "$src" ] || { printf ''; return 0; }
  dir="$CODEMUX_HOME/backup/$(date '+%Y%m%d-%H%M%S')-$tag"
  mkdir -p "$dir" || return 1
  dest="$dir/$(basename "$src")"
  cp -a "$src" "$dest" 2>/dev/null || return 1
  printf '%s\n' "$dest"
}

# --- proses terpisah dari shell ---------------------------------------------
# codemux_spawn <langkah> <perintah...>
# Anak menulis pid sendiri, lalu rc ke <langkah>.rc. Shell/opencode mati
# tidak membunuh anak (setsid + nohup).
codemux_spawn() {
  local step="$1"
  shift
  local dir script log rc pidf cmd a i
  dir="$(codemux_run_dir)"
  mkdir -p "$dir" || return 1
  script="$dir/$step.sh"
  log="$dir/$step.log"
  rc="$dir/$step.rc"
  pidf="$dir/$step.pid"
  rm -f "$rc" "$pidf"
  cmd=""
  for a in "$@"; do cmd+="$(printf '%q' "$a") "; done
  {
    printf '#!%s\n' "$(command -v bash)"
    printf 'echo $$ > %q\n' "$pidf"
    printf '%s\n' "$cmd"
    printf 'rc=$?\necho "$rc" > %q\nexit "$rc"\n' "$rc"
  } >"$script" || return 1
  chmod 700 "$script" 2>/dev/null || true

  if have setsid; then
    setsid nohup bash "$script" >>"$log" 2>&1 </dev/null &
  else
    nohup bash "$script" >>"$log" 2>&1 </dev/null &
  fi

  i=0
  while [ ! -s "$pidf" ] && [ "$i" -lt 100 ]; do
    i=$((i + 1))
    sleep 0.1 2>/dev/null || sleep 1
  done
  [ -s "$pidf" ]
}

codemux_step_pid() { cat "$(codemux_run_dir)/$1.pid" 2>/dev/null || true; }
codemux_step_rc() { cat "$(codemux_run_dir)/$1.rc" 2>/dev/null || true; }
codemux_step_log() { printf '%s/%s.log' "$(codemux_run_dir)" "$1"; }

codemux_step_alive() {
  local p
  p="$(codemux_step_pid "$1")"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# codemux_wait <langkah> [detik_maks]
# 0..255 = kode keluar anak · 124 = timeout · 125 = anak mati tanpa rc
codemux_wait() {
  local step="$1" max="${2:-900}" rc="" i=0
  while :; do
    rc="$(codemux_step_rc "$step")"
    if [ -n "$rc" ]; then return "$rc"; fi
    if ! codemux_step_alive "$step"; then
      rc="$(codemux_step_rc "$step")"
      if [ -n "$rc" ]; then return "$rc"; fi
      return 125
    fi
    i=$((i + 1))
    if [ "$i" -ge "$max" ]; then return 124; fi
    sleep 1
  done
}

# Tunggu proses sisa dari run sebelumnya (mis. apt masih jalan saat induk mati).
codemux_step_settle() {
  local step="$1" pid wait_s=0
  pid="$(codemux_step_pid "$step")"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    log_info "menunggu proses '$step' dari run sebelumnya (pid $pid)…"
    while kill -0 "$pid" 2>/dev/null; do
      sleep 2
      wait_s=$((wait_s + 2))
      [ "$wait_s" -ge 1800 ] && { log_warn "masih jalan setelah 30 menit; dilewati"; return 1; }
    done
    log_info "proses '$step' sebelumnya selesai (rc $(codemux_step_rc "$step"))"
  fi
  return 0
}

# Ekor log terakhir sebagai catatan kegagalan.
codemux_step_tail() {
  local f
  f="$(codemux_step_log "$1")"
  [ -f "$f" ] || { printf ''; return 0; }
  tail -n 3 "$f" 2>/dev/null | tr '\n\t' '  ' | cut -c1-180
}
