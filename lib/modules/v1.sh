# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: v1 — OpenCode V1 lewat adapter repo opencode-termux (bukan salinan kode).
# Versi diambil dari payload (`opencode --version`), BUKAN dpkg: paket dpkg bisa
# tertinggal (1.19.0) saat payload sudah 1.19.3.

CODEMUX_UPSTREAM_V1="${CODEMUX_UPSTREAM_V1:-https://api.github.com/repos/kusnuzon/opencode-termux/contents/install.sh}"

m_v1_probe() {
  local payload="$PREFIX/share/opencode/opencode.real"
  local launcher="$PREFIX/bin/opencode"
  local ver pkg_ver held=1 note

  if [ ! -x "$payload" ]; then
    PROBE=MISS; NOTE="payload belum ada ($payload)"; return
  fi

  ver="$(opencode_v1_version)"
  pkg_ver="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
  apt-mark showhold 2>/dev/null | grep -qx opencode || held=0

  note="v$ver"
  if [ -n "$pkg_ver" ] && [ "$pkg_ver" != "$ver" ]; then
    note="$note (dpkg $pkg_ver)"
  fi
  if [ -x "$launcher" ]; then
    note="$note · launcher ok"
  else
    note="$note · launcher HILANG"
  fi
  if [ "$held" -eq 1 ]; then
    note="$note · apt hold aktif"
  else
    note="$note · BELUM di-apt-mark hold"
  fi

  if [ "$held" -eq 1 ] && [ -x "$launcher" ]; then
    PROBE=OK; NOTE="$note"
  else
    PROBE=WARN; NOTE="$note"
  fi
}

m_v1_verify() { m_v1_probe; }

m_v1_apply() {
  local script rc
  if ! script="$(codemux_adapter_fetch v1 "$CODEMUX_UPSTREAM_V1")"; then
    APPLY_NOTE="gagal mengunduh install.sh hulu V1 (jaringan?)"
    return 1
  fi
  log_info "adapter V1: install.sh hulu ($(codemux_adapter_sha "$script")) dijalankan terpisah"

  codemux_spawn v1 bash "$script" || { APPLY_NOTE="gagal menjalankan adapter V1"; return 1; }
  local rc=0
  codemux_wait v1 3600 || rc=$?
  if [ "$rc" -ne 0 ]; then
    APPLY_NOTE="adapter V1 gagal (rc $rc): $(codemux_step_tail v1)"
    return "$rc"
  fi
  APPLY_NOTE="adapter V1 selesai · opencode $(opencode_v1_version)"
  return 0
}
