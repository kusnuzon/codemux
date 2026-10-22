# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: mirror — repo apt yang dipakai Termux.

m_mirror_probe() {
  local main="$PREFIX/etc/apt/sources.list"
  local extra="$PREFIX/etc/apt/sources.list.d"
  local host="" slow=""

  if [ -r "$main" ]; then
    host="$(awk '/^[[:space:]]*deb[[:space:]]/ {print $2; exit}' "$main" 2>/dev/null)"
    grep -q 'leitecastro' "$main" 2>/dev/null && slow="lambat"
  fi
  if [ -d "$extra" ]; then
    if [ -z "$host" ]; then
      host="$(awk '/^[[:space:]]*deb[[:space:]]/ {print $2; exit}' "$extra"/*.list 2>/dev/null)"
    fi
    grep -qs 'leitecastro' "$extra" && slow="lambat"
  fi

  if [ -z "$host" ]; then
    PROBE=WARN; NOTE="tidak ada repo apt aktif di $main"
  elif [ -n "$slow" ]; then
    PROBE=WARN; NOTE="$host ($slow — disarankan ganti)"
  else
    PROBE=OK; NOTE="$host"
  fi
}
