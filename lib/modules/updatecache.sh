# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: updatecache — cache hasil cek update hulu (PRD §12B).

m_updatecache_probe() {
  local f="$CODEMUX_HOME/update-cache.tsv"
  local age

  if [ ! -f "$f" ]; then
    PROBE=MISS; NOTE="belum pernah cek update"
    return
  fi

  age=$(( ( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ) / 3600 ))
  if [ "$age" -lt 0 ] || [ "$age" -ge 24 ]; then
    PROBE=MISS; NOTE="cache ${age} jam (basi, > 24 jam)"
  else
    local n
    n="$(awk -F'\t' '$4=="update"' "$f" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -gt 0 ]; then
      PROBE=OK; NOTE="cache ${age} jam · ${n} update tersedia (codemux upgrade)"
    else
      PROBE=OK; NOTE="cache ${age} jam · versi terbaru"
    fi
  fi
}
