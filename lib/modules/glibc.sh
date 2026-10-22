# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: glibc — runtime glibc Termux (wajib untuk payload OpenCode).

m_glibc_probe() {
  local ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  local libc="$PREFIX/glibc/lib/libc.so.6"
  local missing=()

  [ -x "$ld" ] || missing+=("loader")
  [ -e "$libc" ] || missing+=("libc.so.6")

  if [ "${#missing[@]}" -eq 0 ]; then
    PROBE=OK; NOTE="loader + libc.so.6"
  else
    PROBE=MISS; NOTE="kurang: ${missing[*]} (pkg install glibc-repo glibc termux-exec-glibc)"
  fi
}
