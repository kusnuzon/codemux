# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: mirror — repo apt yang dipakai Termux.

CODEMUX_MIRROR_MAIN="${CODEMUX_MIRROR_MAIN:-https://mirror.jeonnam.school/termux/termux-main}"

m_mirror_host() {
  local main="$PREFIX/etc/apt/sources.list" extra="$PREFIX/etc/apt/sources.list.d"
  local host=""
  [ -r "$main" ] && host="$(awk '/^[[:space:]]*deb[[:space:]]/ {print $2; exit}' "$main" 2>/dev/null)"
  if [ -z "$host" ] && [ -d "$extra" ]; then
    host="$(awk '/^[[:space:]]*deb[[:space:]]/ {print $2; exit}' "$extra"/*.list 2>/dev/null)"
  fi
  printf '%s' "$host"
}

m_mirror_probe() {
  local host slow=""
  host="$(m_mirror_host)"
  if [ -z "$host" ]; then
    PROBE=MISS; NOTE="tidak ada repo apt aktif di $PREFIX/etc/apt/sources.list"
    return
  fi
  grep -qs 'leitecastro' "$PREFIX/etc/apt/sources.list" "$PREFIX/etc/apt/sources.list.d" 2>/dev/null && slow="lambat"
  if [ -n "$slow" ]; then
    PROBE=WARN; NOTE="$host (mirror lambat — disarankan ganti)"
  else
    PROBE=OK; NOTE="$host"
  fi
}

m_mirror_verify() {
  local host
  host="$(m_mirror_host)"
  if [ -z "$host" ]; then
    PROBE=FAIL; NOTE="sources.list tidak valid setelah ditulis"
  elif printf '%s' "$host" | grep -q 'leitecastro'; then
    PROBE=WARN; NOTE="$host masih lambat"
  else
    PROBE=OK; NOTE="$host"
  fi
}

m_mirror_apply() {
  local f="$PREFIX/etc/apt/sources.list" host bak
  host="$(m_mirror_host)"

  if [ -z "$host" ]; then
    bak="$(codemux_backup mirror "$f")" || { APPLY_NOTE="gagal backup sources.list"; return 1; }
    printf 'deb %s stable main\n' "$CODEMUX_MIRROR_MAIN" | codemux_atomic_write "$f" || {
      APPLY_NOTE="gagal menulis sources.list"; return 1; }
    APPLY_NOTE="sources.list baru: $CODEMUX_MIRROR_MAIN (backup: $bak)"
  else
    # hanya ganti host, biarkan baris lain apa adanya
    bak="$(codemux_backup mirror "$f")" || { APPLY_NOTE="gagal backup sources.list"; return 1; }
    sed -i "s|^[[:space:]]*deb[[:space:]][^[:space:]]*/termux-main|deb $CODEMUX_MIRROR_MAIN|" "$f" || {
      APPLY_NOTE="gagal menyunting sources.list"; return 1; }
    APPLY_NOTE="host diganti ke $CODEMUX_MIRROR_MAIN (backup: $bak)"
  fi

  # uji nyata: apt-get update harus lolos
  codemux_spawn mirror env DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
    APPLY_NOTE="gagal menjalankan apt-get update"; return 1; }
  local rc=0
  codemux_wait mirror 900 || rc=$?
  if [ "$rc" -ne 0 ]; then
    # pulihkan backup supaya repo tidak rusak
    [ -n "$bak" ] && [ -f "$bak" ] && cp -a "$bak" "$f" 2>/dev/null
    APPLY_NOTE="apt-get update gagal (rc $rc) — sources.list dipulihkan: $(codemux_step_tail mirror)"
    return 1
  fi
  APPLY_NOTE="$APPLY_NOTE · apt-get update lolos"
  return 0
}
