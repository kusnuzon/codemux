# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: toolset — paket apt wajib (lihat CODEMUX_APT_PACKAGES).

m_toolset_probe() {
  local p miss=() total=0
  for p in $CODEMUX_APT_PACKAGES; do
    total=$((total + 1))
    pkg_installed "$p" || miss+=("$p")
  done

  if [ "$total" -eq 0 ]; then
    PROBE=WARN; NOTE="versions.env tidak memuat CODEMUX_APT_PACKAGES"; return
  fi
  if [ "${#miss[@]}" -eq 0 ]; then
    PROBE=OK; NOTE="$total/$total paket terpasang"
    return
  fi

  local shown="${miss[*]:0:4}"
  local more=$(( ${#miss[@]} - 4 ))
  if [ "$more" -gt 0 ]; then
    shown="$shown (+$more)"
  fi
  PROBE=MISS; NOTE="$((total - ${#miss[@]}))/$total terpasang · kurang: $shown"
}
