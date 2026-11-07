# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: preflight — minimum environment requirements.

m_preflight_probe() {
  local os arch uid free notes
  os="$(uname -o 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  uid="$(id -u)"
  free="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  free="${free:-0}"

  if [ "$os" != "Android" ] && [ "${CODEMUX_ALLOW_NONANDROID:-0}" != "1" ]; then
    PROBE=FAIL; NOTE="not Android (uname -o = $os)"; return
  fi
  if [ "$arch" != "aarch64" ]; then
    if [ "${CODEMUX_ALLOW_NONANDROID:-0}" = "1" ]; then
      PROBE=WARN; NOTE="architecture $arch (test mode: not enforced)"
      return
    fi
    PROBE=FAIL; NOTE="architecture $arch (codemux v1 is aarch64 only)"; return
  fi
  if [ "$uid" -eq 0 ]; then
    PROBE=FAIL; NOTE="running as root (not supported)"; return
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
