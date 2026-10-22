# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: storage — akses penyimpanan Android (termux-setup-storage).

m_storage_probe() {
  if [ -d "$HOME/storage" ] && [ -r /sdcard ]; then
    PROBE=OK; NOTE='storage Termux ada, /sdcard terbaca'
  elif [ -d "$HOME/storage" ]; then
    PROBE=WARN; NOTE='storage Termux ada tapi /sdcard tidak terbaca'
  else
    PROBE=MISS; NOTE="belum dijalankan termux-setup-storage"
  fi
}
