# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: v2 — OpenCode V2 lewat adapter repo opencode-termux-v2.
# Wajib shim lib/compat (libc.so/libm.so) karena binary Bun minta "libc.so".

CODEMUX_UPSTREAM_V2="${CODEMUX_UPSTREAM_V2:-https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh}"

m_v2_probe() {
  local dir="$PREFIX/share/opencode-v2"
  local launcher="$PREFIX/bin/opencode-v2"
  local ver note

  if [ ! -x "$dir/opencode.real" ]; then
    PROBE=MISS; NOTE="payload belum ada ($dir/opencode.real)"; return
  fi

  ver="$(opencode_v2_version)"
  note="v$ver"
  if [ -e "$dir/lib/compat/libc.so" ]; then
    note="$note · shim compat ok"
  else
    note="$note · shim compat HILANG (codemux repair)"
  fi
  if [ -x "$launcher" ]; then
    note="$note · launcher ok"
  else
    note="$note · launcher HILANG"
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
    APPLY_NOTE="gagal mengunduh install.sh hulu V2 (jaringan?)"
    return 1
  fi
  log_info "adapter V2: install.sh hulu ($(codemux_adapter_sha "$script")) dijalankan terpisah"

  codemux_spawn v2 bash "$script" || { APPLY_NOTE="gagal menjalankan adapter V2"; return 1; }
  local rc=0
  codemux_wait v2 3600 || rc=$?
  if [ "$rc" -ne 0 ]; then
    APPLY_NOTE="adapter V2 gagal (rc $rc): $(codemux_step_tail v2)"
    return "$rc"
  fi
  APPLY_NOTE="adapter V2 selesai · opencode-v2 $(opencode_v2_version)"
  return 0
}
