# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: v1 — OpenCode V1 through the opencode-termux repo adapter (not a code copy).
# The version comes from the payload (`opencode --version`), NOT dpkg: the dpkg
# package can lag (1.19.0) while the payload is already 1.19.3.

CODEMUX_UPSTREAM_V1="${CODEMUX_UPSTREAM_V1:-https://api.github.com/repos/kusnuzon/opencode-termux/contents/install.sh}"

m_v1_probe() {
  local payload launcher ver pkg_ver held=0 note

  if [ "$(codemux_detect_platform)" = linux ]; then
    # linux profile: native upstream payload, no termuxvoid dpkg, no apt hold.
    payload="$PREFIX/share/opencode/opencode"
    launcher="$PREFIX/bin/opencode"
    if [ ! -x "$payload" ]; then
      PROBE=MISS; NOTE="payload not installed yet ($payload)"; return
    fi
    ver="$(opencode_v1_version)"
    if [ -x "$launcher" ]; then
      PROBE=OK; NOTE="v$ver · native linux"
    else
      PROBE=WARN; NOTE="v$ver · launcher MISSING"
    fi
    return
  fi

  payload="$PREFIX/share/opencode/opencode.real"
  launcher="$PREFIX/bin/opencode"
  if [ ! -x "$payload" ]; then
    PROBE=MISS; NOTE="payload not installed yet ($payload)"; return
  fi
  ver="$(opencode_v1_version)"
  pkg_ver="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
  apt-mark showhold 2>/dev/null | grep -qx opencode && held=1

  note="v$ver"
  if [ -n "$pkg_ver" ]; then
    note="$note (termuxvoid dpkg $pkg_ver)"
  else
    note="$note · termuxvoid dpkg MISSING"
  fi
  if [ -x "$launcher" ]; then
    note="$note · launcher ok"
  else
    note="$note · launcher MISSING"
  fi
  if [ "$held" -eq 1 ]; then
    note="$note · apt hold active"
  else
    note="$note · NOT apt-mark held"
  fi

  if [ -n "$pkg_ver" ] && [ -x "$launcher" ] && [ "$held" -eq 1 ]; then
    PROBE=OK
  else
    PROBE=WARN
  fi
  NOTE="$note"
}

m_v1_apply() {
  local script rc

  if [ "$(codemux_detect_platform)" = linux ]; then
    # linux profile: upstream native tarball, no adapter, no glibc shim.
    if codemux_native_install 1 "$PREFIX/share/opencode" "$PREFIX/bin/opencode"; then
      APPLY_NOTE="V1 native linux · opencode $(opencode_v1_version)"
      return 0
    fi
    APPLY_NOTE="V1 native linux install failed"
    return 1
  fi

  if ! script="$(codemux_adapter_fetch v1 "$CODEMUX_UPSTREAM_V1")"; then
    APPLY_NOTE="failed to download upstream V1 install.sh (network?)"
    return 1
  fi
  log_info "V1 adapter: upstream install.sh ($(codemux_adapter_sha "$script")) runs detached"

  codemux_spawn v1 bash "$script" || { APPLY_NOTE="failed to run the V1 adapter"; return 1; }
  codemux_spin_msg "waiting for the upstream V1 installer (apt + payload, log is live)"
  local rc=0
  codemux_wait v1 3600 || rc=$?
  if [ "$rc" -ne 0 ]; then
    APPLY_NOTE="V1 adapter failed (rc $rc): $(codemux_step_tail v1)"
    return "$rc"
  fi
  APPLY_NOTE="V1 adapter finished · opencode $(opencode_v1_version)"
  return 0
}
