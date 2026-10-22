# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: v1 — OpenCode V1 (payload glibc + apt-mark hold).
# Catatan: versi diambil dari payload (`opencode --version`), BUKAN dari dpkg —
# paket dpkg bisa tertinggal (1.19.0) saat payload sudah 1.19.3.

m_v1_probe() {
  local payload="$PREFIX/share/opencode/opencode.real"
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
  if [ "$held" -eq 1 ]; then
    note="$note · apt hold aktif"
  else
    note="$note · BELUM di-apt-mark hold"
  fi

  if [ "$held" -eq 1 ]; then
    PROBE=OK; NOTE="$note"
  else
    PROBE=WARN; NOTE="$note (rawan tertimpa pkg upgrade)"
  fi
}
