# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: toolset — required apt packages (see CODEMUX_APT_PACKAGES).
# Large extra packages / packages that need another repo live in CODEMUX_APT_EXTRA:
# their failure is only a WARN, it does not fail the install.

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
    PROBE=WARN; NOTE="versions.env does not define CODEMUX_APT_PACKAGES"; return
  fi

  miss="$(m_toolset_required_missing | tr '\n' ' ' | sed 's/ *$//')"
  extra="$(m_toolset_extra_missing | tr '\n' ' ' | sed 's/ *$//')"

  if [ -z "$miss" ]; then
    PROBE=OK
    NOTE="$total/$total required packages installed"
  else
    n="$(m_toolset_count "$miss")"
    shown="$(printf '%s' "$miss" | cut -d' ' -f1-4)"
    more=$((n - 4))
    [ "$more" -gt 0 ] && shown="$shown (+$more)"
    PROBE=MISS; NOTE="$((total - n))/$total installed · missing: $shown"
  fi
  if [ -n "$extra" ]; then
    NOTE="$NOTE · optional missing: $(printf '%s' "$extra" | cut -d' ' -f1-3)"
  fi
}

m_toolset_verify() { m_toolset_probe; }

m_toolset_apply() {
  local miss extra bonus="" repos
  miss="$(m_toolset_required_missing | tr '\n' ' ' | sed 's/ *$//')"
  extra="$(m_toolset_extra_missing | tr '\n' ' ' | sed 's/ *$//')"

  # Extra repos (e.g. x11-repo for chromium/tesseract) are installed first.
  if [ -n "$extra" ] && [ -n "${CODEMUX_APT_REPOS:-}" ]; then
    codemux_spin_msg "apt install: $CODEMUX_APT_REPOS"
    # shellcheck disable=SC2086
    codemux_apt_install $CODEMUX_APT_REPOS >/dev/null 2>&1 || true
  fi

  if [ -n "$miss" ]; then
    codemux_spin_msg "apt install: $miss (this can take a few minutes)"
    # shellcheck disable=SC2086
    if ! codemux_apt_install $miss; then
      APPLY_NOTE="apt failed: $miss"
      return 1
    fi
    APPLY_NOTE="installed: $miss"
  else
    APPLY_NOTE="nothing to install"
  fi

  if [ -n "$extra" ]; then
    codemux_spin_msg "apt install (optional): $extra"
    # shellcheck disable=SC2086
    if codemux_apt_install $extra >/dev/null 2>&1; then
      bonus=" · optional: $extra"
    else
      bonus=" · optional skipped: $extra"
      log_warn "optional packages failed to install (not an install failure): $extra"
    fi
  fi

  APPLY_NOTE="$APPLY_NOTE$bonus"
  return 0
}
