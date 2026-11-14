# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: v1 — OpenCode V1 through the opencode-termux repo adapter (not a code copy).
# The version comes from the payload (`opencode --version`), NOT dpkg: the dpkg
# package can lag (1.19.0) while the payload is already 1.19.3.

CODEMUX_UPSTREAM_V1="${CODEMUX_UPSTREAM_V1:-https://api.github.com/repos/kusnuzon/opencode-termux/contents/install.sh}"

m_v1_probe() {
  local payload="$PREFIX/share/opencode/opencode.real"
  local launcher="$PREFIX/bin/opencode"
  local ver pkg_ver held=0 note

  if [ ! -x "$payload" ]; then
    PROBE=MISS; NOTE="payload not installed yet ($payload)"; return
  fi

  ver="$(opencode_v1_version)"
  pkg_ver="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
  apt-mark showhold 2>/dev/null | grep -qx opencode && held=1

  note="v$ver"
  if [ -n "$pkg_ver" ]; then
    note="$note (dpkg $pkg_ver)"
    [ "$held" -eq 1 ] && note="$note · apt hold active"
  else
    note="$note · script launcher (no dpkg)"
  fi
  if [ -x "$launcher" ]; then
    note="$note · launcher ok"
    PROBE=OK
  else
    note="$note · launcher MISSING"
    PROBE=WARN
  fi
  NOTE="$note"
}

m_v1_verify() { m_v1_probe; }

m_v1_apply() {
  local script rc
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
