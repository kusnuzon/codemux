# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: v1 — OpenCode V1 (payload glibc + apt-mark hold).

m_v1_probe() {
  local payload="$PREFIX/share/opencode/opencode.real"
  local ver held=0

  if [ ! -x "$payload" ]; then
    PROBE=MISS; NOTE="payload belum ada ($payload)"; return
  fi

  ver="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
  if apt-mark showhold 2>/dev/null | grep -qx opencode; then
    held=1
  fi

  if [ "$held" -eq 1 ]; then
    PROBE=OK; NOTE="v${ver:-?} · apt hold aktif"
  else
    PROBE=WARN; NOTE="v${ver:-?} · BELUM di-apt-mark hold (rawan tertimpa pkg upgrade)"
  fi
}
