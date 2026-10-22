# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: preflight — syarat minimum lingkungan.

m_preflight_probe() {
  local os arch uid free notes
  os="$(uname -o 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  uid="$(id -u)"
  free="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  free="${free:-0}"

  if [ "$os" != "Android" ] && [ "${CODEMUX_ALLOW_NONANDROID:-0}" != "1" ]; then
    PROBE=FAIL; NOTE="bukan Android (uname -o = $os)"; return
  fi
  if [ "$arch" != "aarch64" ]; then
    if [ "${CODEMUX_ALLOW_NONANDROID:-0}" = "1" ]; then
      PROBE=WARN; NOTE="arsitektur $arch (mode uji: tidak dipaksakan)"
      return
    fi
    PROBE=FAIL; NOTE="arsitektur $arch (codemux v1 hanya aarch64)"; return
  fi
  if [ "$uid" -eq 0 ]; then
    PROBE=FAIL; NOTE="dijalankan sebagai root (tidak didukung)"; return
  fi

  notes="$os/$arch · user $(id -un)"
  if [ "$free" -lt 3145728 ]; then
    PROBE=WARN
    NOTE="$notes · disk $(human_bytes $((free * 1024))) (< 3 GB)"
  else
    PROBE=OK
    NOTE="$notes · disk $(human_bytes $((free * 1024)))"
  fi
}
