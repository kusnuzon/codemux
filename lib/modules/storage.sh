# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: storage — Android storage access (termux-setup-storage).

m_storage_probe() {
  if [ -d "$HOME/storage" ] && [ -r /sdcard ]; then
    PROBE=OK; NOTE='Termux storage present, /sdcard readable'
  elif [ -d "$HOME/storage" ]; then
    PROBE=WARN; NOTE='Termux storage present but /sdcard is not readable'
  else
    # Android permission is not required for OpenCode: never fail the install.
    PROBE=WARN; NOTE='termux-setup-storage has not run (optional)'
  fi
}

m_storage_verify() { m_storage_probe; }

# Android permission cannot be fully automated: the dialog must be touched.
# So apply only OPENS the dialog (with a timeout), then verify checks the result.
m_storage_apply() {
  if ! have termux-setup-storage; then
    APPLY_NOTE="termux-setup-storage is missing (pkg install termux-tools) — skipped"
    return 0
  fi
  log_info "opening the Android storage permission dialog — tap 'Allow' if it appears"
  timeout 45 termux-setup-storage </dev/null >/dev/null 2>&1 || true
  if [ -d "$HOME/storage" ] && [ -r /sdcard ]; then
    APPLY_NOTE="storage permission granted"
    return 0
  fi
  APPLY_NOTE="storage permission not granted yet — run termux-setup-storage anytime"
  return 0
}
