# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: storage — akses penyimpanan Android (termux-setup-storage).

m_storage_probe() {
  if [ -d "$HOME/storage" ] && [ -r /sdcard ]; then
    PROBE=OK; NOTE='storage Termux ada, /sdcard terbaca'
  elif [ -d "$HOME/storage" ]; then
    PROBE=WARN; NOTE='storage Termux ada tapi /sdcard tidak terbaca'
  else
    PROBE=MISS; NOTE='belum dijalankan termux-setup-storage'
  fi
}

m_storage_verify() { m_storage_probe; }

# Izin Android tidak bisa diotomatiskan penuh: dialog harus disentuh Master.
# Karena itu apply hanya MEMBUKA dialog (dengan timeout), lalu verify dicek.
m_storage_apply() {
  if ! have termux-setup-storage; then
    APPLY_NOTE="termux-setup-storage tidak ada (pkg install termux-tools)"
    return 1
  fi
  log_info "membuka dialog izin penyimpanan Android — sentuh 'Izinkan' bila muncul"
  timeout 45 termux-setup-storage </dev/null >/dev/null 2>&1 || true
  if [ -d "$HOME/storage" ] && [ -r /sdcard ]; then
    APPLY_NOTE="izin penyimpanan diberikan"
    return 0
  fi
  APPLY_NOTE="dialog izin belum diterima — buka Termux, jalankan: termux-setup-storage"
  return 1
}
