# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: toolset — paket apt wajib (lihat CODEMUX_APT_PACKAGES).
# Paket tambahan yang besar / butuh repo lain ada di CODEMUX_APT_EXTRA:
# kegagalannya hanya WARN, tidak menggagalkan install.

m_toolset_required_missing() {
  local p
  for p in $CODEMUX_APT_PACKAGES; do
    pkg_installed "$p" || printf '%s\n' "$p"
  done
}

m_toolset_extra_missing() {
  local p
  for p in ${CODEMUX_APT_EXTRA:-}; do
    pkg_installed "$p" || printf '%s\n' "$p"
  done
}

m_toolset_count() {
  local n=0 p
  for p in $1; do n=$((n + 1)); done
  printf '%s' "$n"
}

m_toolset_probe() {
  local total miss n shown more extra note
  total="$(m_toolset_count "$CODEMUX_APT_PACKAGES")"
  if [ "$total" -eq 0 ]; then
    PROBE=WARN; NOTE="versions.env tidak memuat CODEMUX_APT_PACKAGES"; return
  fi

  miss="$(m_toolset_required_missing | tr '\n' ' ' | sed 's/ *$//')"
  extra="$(m_toolset_extra_missing | tr '\n' ' ' | sed 's/ *$//')"

  if [ -z "$miss" ]; then
    PROBE=OK
    NOTE="$total/$total paket wajib terpasang"
  else
    n="$(m_toolset_count "$miss")"
    shown="$(printf '%s' "$miss" | cut -d' ' -f1-4)"
    more=$((n - 4))
    [ "$more" -gt 0 ] && shown="$shown (+$more)"
    PROBE=MISS; NOTE="$((total - n))/$total terpasang · kurang: $shown"
  fi
  if [ -n "$extra" ]; then
    NOTE="$NOTE · opsional belum: $(printf '%s' "$extra" | cut -d' ' -f1-3)"
  fi
}

m_toolset_verify() { m_toolset_probe; }

m_toolset_apply() {
  local miss extra bonus="" repos
  miss="$(m_toolset_required_missing | tr '\n' ' ' | sed 's/ *$//')"
  extra="$(m_toolset_extra_missing | tr '\n' ' ' | sed 's/ *$//')"

  # Repo tambahan (mis. x11-repo untuk chromium/tesseract) dipasang lebih dulu.
  if [ -n "$extra" ] && [ -n "${CODEMUX_APT_REPOS:-}" ]; then
    # shellcheck disable=SC2086
    codemux_apt_install $CODEMUX_APT_REPOS >/dev/null 2>&1 || true
  fi

  if [ -n "$miss" ]; then
    # shellcheck disable=SC2086
    if ! codemux_apt_install $miss; then
      APPLY_NOTE="apt gagal: $miss"
      return 1
    fi
    APPLY_NOTE="dipasang: $miss"
  else
    APPLY_NOTE="tidak ada yang perlu dipasang"
  fi

  if [ -n "$extra" ]; then
    # shellcheck disable=SC2086
    if codemux_apt_install $extra >/dev/null 2>&1; then
      bonus=" · opsional: $extra"
    else
      bonus=" · opsional dilewati: $extra"
      log_warn "paket opsional gagal dipasang (bukan kegagalan install): $extra"
    fi
  fi

  APPLY_NOTE="$APPLY_NOTE$bonus"
  return 0
}
