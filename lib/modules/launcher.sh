# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: launcher — banner + menu di ~/.bashrc.

m_launcher_probe() {
  local rc="$HOME/.bashrc"

  if [ ! -f "$rc" ]; then
    PROBE=MISS; NOTE='bashrc tidak ada (~/.bashrc)'; return
  fi
  if grep -q 'codemux:launcher' "$rc" 2>/dev/null; then
    PROBE=OK; NOTE="blok bertanda ada"
    return
  fi
  if grep -q '_oc_banner' "$rc" 2>/dev/null; then
    PROBE=WARN; NOTE="menu ada tapi tanpa penanda codemux (akan diadopsi)"
    return
  fi
  PROBE=MISS; NOTE="menu/banner belum dipasang"
}
