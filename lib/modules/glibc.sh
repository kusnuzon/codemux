# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: glibc — the Termux glibc runtime (required by the OpenCode payloads).
# Note: installing glibc can overwrite Termux's libcurl so curl dies
# ("cannot locate symbol SSL_set_quic_tls_early_data_enabled"). Every module
# after this one needs curl, so curl is repaired at the end of this module.

m_glibc_probe() {
  local ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  local libc="$PREFIX/glibc/lib/libc.so.6"
  local missing=""

  [ -x "$ld" ] || missing="loader"
  [ -e "$libc" ] || missing="${missing:+$missing, }libc.so.6"

  if [ -z "$missing" ]; then
    if codemux_curl_ok; then
      PROBE=OK; NOTE="loader + libc.so.6"
    else
      PROBE=WARN; NOTE="loader + libc.so.6 · curl needs repairing"
    fi
  else
    PROBE=MISS; NOTE="missing: $missing (packages glibc-repo, glibc, termux-exec-glibc)"
  fi
}

m_glibc_verify() { m_glibc_probe; }

m_glibc_apply() {
  local ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

  if [ ! -x "$ld" ]; then
    # glibc-repo must be added first, only then are the glibc packages available.
    codemux_spin_msg "apt install: glibc-repo"
    codemux_apt_install glibc-repo || { APPLY_NOTE="failed to install glibc-repo"; return 1; }
    codemux_spin_msg "apt install: glibc termux-exec-glibc (large download)"
    codemux_apt_update || true
    codemux_apt_install glibc termux-exec-glibc || {
      APPLY_NOTE="failed to install glibc/termux-exec-glibc"
      return 1
    }
    [ -x "$ld" ] || { APPLY_NOTE="the glibc loader did not appear at $ld"; return 1; }
    APPLY_NOTE="glibc-repo + glibc + termux-exec-glibc installed"
  else
    APPLY_NOTE="the glibc runtime is already present"
  fi

  # Safety net: repair curl before the v1/v2/memory modules download anything.
  if ! codemux_curl_ok; then
    if codemux_heal_curl; then
      APPLY_NOTE="$APPLY_NOTE · curl repaired"
    else
      APPLY_NOTE="$APPLY_NOTE · curl is still broken (downloads may fail)"
      log_warn "curl is still broken after reinstalling; download modules will try wget/python"
    fi
  fi
  return 0
}
