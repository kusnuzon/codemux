# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: glibc — runtime glibc Termux (wajib untuk payload OpenCode).
# Catatan: pemasangan glibc bisa menimpa libcurl milik Termux sehingga curl
# mati ("cannot locate symbol SSL_set_quic_tls_early_data_enabled"). Semua
# modul sesudahnya butuh curl, jadi curl dipulihkan di akhir modul ini.

m_glibc_probe() {
  local ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  local libc="$PREFIX/glibc/lib/libc.so.6"
  local missing=""

  [ -x "$ld" ] || missing="loader"
  [ -e "$libc" ] || missing="${missing:+$missing, }libc.so.6"

  if [ -z "$missing" ]; then
    if codemux_curl_ok; then
      PROBE=OK; NOTE="loader + libc.so.6"
    else
      PROBE=WARN; NOTE="loader + libc.so.6 · curl perlu dipulihkan"
    fi
  else
    PROBE=MISS; NOTE="kurang: $missing (paket glibc-repo, glibc, termux-exec-glibc)"
  fi
}

m_glibc_verify() { m_glibc_probe; }

m_glibc_apply() {
  local ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

  if [ ! -x "$ld" ]; then
    # glibc-repo harus ditambahkan dulu, baru paket glibc tersedia.
    codemux_apt_install glibc-repo || { APPLY_NOTE="gagal memasang glibc-repo"; return 1; }
    codemux_apt_update || true
    codemux_apt_install glibc termux-exec-glibc || {
      APPLY_NOTE="gagal memasang glibc/termux-exec-glibc"
      return 1
    }
    [ -x "$ld" ] || { APPLY_NOTE="loader glibc tidak muncul di $ld"; return 1; }
    APPLY_NOTE="glibc-repo + glibc + termux-exec-glibc dipasang"
  else
    APPLY_NOTE="runtime glibc sudah ada"
  fi

  # Jaring pengaman: pulihkan curl sebelum modul v1/v2/memory mengunduh apa pun.
  if ! codemux_curl_ok; then
    if codemux_heal_curl; then
      APPLY_NOTE="$APPLY_NOTE · curl dipulihkan"
    else
      APPLY_NOTE="$APPLY_NOTE · curl masih rusak (unduhan bisa gagal)"
      log_warn "curl masih rusak setelah pemasangan ulang; modul unduhan akan mencoba wget/python"
    fi
  fi
  return 0
}
