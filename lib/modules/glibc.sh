# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: glibc — runtime glibc Termux (wajib untuk payload OpenCode).

m_glibc_probe() {
  local ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  local libc="$PREFIX/glibc/lib/libc.so.6"
  local missing=""

  [ -x "$ld" ] || missing="loader"
  [ -e "$libc" ] || missing="${missing:+$missing, }libc.so.6"

  if [ -z "$missing" ]; then
    PROBE=OK; NOTE="loader + libc.so.6"
  else
    PROBE=MISS; NOTE="kurang: $missing (paket glibc-repo, glibc, termux-exec-glibc)"
  fi
}

m_glibc_verify() { m_glibc_probe; }

m_glibc_apply() {
  # glibc-repo harus ditambahkan dulu, baru paket glibc tersedia.
  codemux_spawn glibc bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y glibc-repo
    apt-get update -qq
    apt-get install -y glibc termux-exec-glibc
  ' || { APPLY_NOTE="gagal menjalankan apt untuk glibc"; return 1; }
  local rc=0
  codemux_wait glibc 3600 || rc=$?
  if [ "$rc" -ne 0 ]; then
    APPLY_NOTE="apt glibc gagal (rc $rc): $(codemux_step_tail glibc)"
    return "$rc"
  fi
  APPLY_NOTE="glibc-repo + glibc + termux-exec-glibc dipasang"
  return 0
}
