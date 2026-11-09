# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: v2 — OpenCode V2 through the opencode-termux-v2 repo adapter.
# The lib/compat shim (libc.so/libm.so) is required because the Bun binary asks for "libc.so".

CODEMUX_UPSTREAM_V2="${CODEMUX_UPSTREAM_V2:-https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh}"

m_v2_probe() {
  local dir="$PREFIX/share/opencode-v2"
  local launcher="$PREFIX/bin/opencode-v2"
  local ver note

  if [ ! -x "$dir/opencode.real" ]; then
    PROBE=MISS; NOTE="payload not installed yet ($dir/opencode.real)"; return
  fi

  ver="$(opencode_v2_version)"
  note="v$ver"
  if [ -e "$dir/lib/compat/libc.so" ]; then
    note="$note · compat shim ok"
  else
    note="$note · compat shim MISSING (codemux repair)"
  fi
  if [ -x "$launcher" ]; then
    note="$note · launcher ok"
  else
    note="$note · launcher MISSING"
  fi

  if [ -e "$dir/lib/compat/libc.so" ] && [ -x "$launcher" ]; then
    PROBE=OK; NOTE="$note"
  else
    PROBE=WARN; NOTE="$note"
  fi
}

m_v2_verify() { m_v2_probe; }

m_v2_apply() {
  local script rc
  if ! script="$(codemux_adapter_fetch v2 "$CODEMUX_UPSTREAM_V2")"; then
    APPLY_NOTE="failed to download upstream V2 install.sh (network?)"
    return 1
  fi
  log_info "V2 adapter: upstream install.sh ($(codemux_adapter_sha "$script")) runs detached"

  codemux_spawn v2 bash "$script" || { APPLY_NOTE="failed to run the V2 adapter"; return 1; }
  codemux_spin_msg "waiting for the upstream V2 installer (apt + payload, log is live)"
  local rc=0
  codemux_wait v2 3600 || rc=$?
  if [ "$rc" -ne 0 ]; then
    APPLY_NOTE="V2 adapter failed (rc $rc): $(codemux_step_tail v2)"
    return "$rc"
  fi
  APPLY_NOTE="V2 adapter finished · opencode-v2 $(opencode_v2_version)"
  return 0
}
