# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: toolset — paket apt wajib (lihat CODEMUX_APT_PACKAGES).

m_toolset_missing() {
  local p
  for p in $CODEMUX_APT_PACKAGES; do
    pkg_installed "$p" || printf '%s\n' "$p"
  done
}

m_toolset_probe() {
  local total=0 miss p
  for p in $CODEMUX_APT_PACKAGES; do total=$((total + 1)); done
  miss="$(m_toolset_missing | tr '\n' ' ' | sed 's/ *$//')"

  if [ "$total" -eq 0 ]; then
    PROBE=WARN; NOTE="versions.env tidak memuat CODEMUX_APT_PACKAGES"; return
  fi
  if [ -z "$miss" ]; then
    PROBE=OK; NOTE="$total/$total paket terpasang"
    return
  fi
  local n
  n="$(printf '%s\n' "$miss" | wc -l | tr -d ' ')"
  local shown more
  shown="$(printf '%s' "$miss" | cut -d' ' -f1-4)"
  more=$((n - 4))
  [ "$more" -gt 0 ] && shown="$shown (+$more)"
  PROBE=MISS; NOTE="$((total - n))/$total terpasang · kurang: $shown"
}

m_toolset_verify() { m_toolset_probe; }

m_toolset_apply() {
  local miss pkgs
  miss="$(m_toolset_missing | tr '\n' ' ' | sed 's/ *$//')"
  if [ -z "$miss" ]; then
    APPLY_NOTE="tidak ada yang perlu dipasang"
    return 0
  fi

  # shellcheck disable=SC2086
  codemux_spawn toolset env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confold $miss || return 1
  local rc=0
  codemux_wait toolset 3600 || rc=$?
  if [ "$rc" -ne 0 ]; then
    APPLY_NOTE="apt gagal (rc $rc): $(codemux_step_tail toolset)"
    return "$rc"
  fi
  APPLY_NOTE="dipasang: $miss"
  return 0
}
