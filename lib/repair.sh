# shellcheck shell=bash
# lib/repair.sh — `codemux repair`: bereskan sisa proses yang mati di tengah.
# Semua langkah aman diulang; `--dry-run` hanya menampilkan rencana.

codemux_repair_say() { printf '  %s·%s %s\n' "$C_INFO" "$C_R" "$*"; }

codemux_apt_busy() {
  pgrep -x apt >/dev/null 2>&1 && return 0
  pgrep -x apt-get >/dev/null 2>&1 && return 0
  pgrep -x dpkg >/dev/null 2>&1 && return 0
  return 1
}

codemux_cmd_repair() {
  local dry=0 a fixes=0
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -h | --help) codemux_usage; return 0 ;;
      *) log_warn "opsi tidak dikenal untuk repair: $a" ;;
    esac
  done

  codemux_load_modules
  printf '%s%s %s%s · repair%s\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R" \
    "$([ "$dry" -eq 1 ] && printf ' (dry-run)')"

  # 1. lock basi
  if [ -d "$CODEMUX_HOME/lock" ]; then
    if codemux_lock_info | grep -q '^basi'; then
      codemux_repair_say "buang lock basi ($(codemux_lock_info))"
      [ "$dry" -eq 0 ] && rm -rf "$CODEMUX_HOME/lock"
      fixes=$((fixes + 1))
    else
      codemux_repair_say "lock aktif — dilewati (ada install berjalan)"
    fi
  fi

  # 2. langkah RUNNING yang prosesnya mati
  if [ -f "$(codemux_run_file)" ]; then
    local stuck
    stuck="$(awk -F'\t' '!/^#/ && $2=="RUNNING" {print $1}' "$(codemux_run_file)" 2>/dev/null | tr '\n' ' ')"
    if [ -n "$stuck" ]; then
      codemux_repair_say "tandai terputus: $stuck"
      [ "$dry" -eq 0 ] && codemux_run_reconcile
      fixes=$((fixes + 1))
    fi
  fi

  # 3. dpkg setengah jadi (mis. Termux dimatikan saat install)
  local audit=""
  audit="$(dpkg --audit 2>/dev/null || true)"
  if [ -n "$audit" ]; then
    codemux_repair_say "dpkg tidak bersih → dpkg --configure -a lalu apt-get -f install -y"
    fixes=$((fixes + 1))
    if [ "$dry" -eq 0 ]; then
      if codemux_apt_busy; then
        log_warn "masih ada proses apt/dpkg aktif — tunggu, lalu jalankan repair lagi"
      else
        codemux_spawn repair_dpkg env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        codemux_wait repair_dpkg 1800 || log_warn "dpkg --configure -a rc $(codemux_step_rc repair_dpkg)"
        codemux_spawn repair_aptfix env DEBIAN_FRONTEND=noninteractive \
          -o Dpkg::Options::=--force-confold apt-get -f install -y || true
        codemux_wait repair_aptfix 1800 || log_warn "apt-get -f install rc $(codemux_step_rc repair_aptfix)"
      fi
    fi
  else
    codemux_repair_say "database dpkg bersih"
  fi

  # 4. lock apt basi (hanya kalau benar-benar tidak ada proses)
  local l
  for l in "$PREFIX/var/lib/dpkg/lock-frontend" "$PREFIX/var/lib/dpkg/lock" \
    "$PREFIX/var/cache/apt/archives/lock" "$PREFIX/var/lib/apt/lists/lock"; do
    [ -e "$l" ] || continue
    if codemux_apt_busy; then break; fi
    codemux_repair_say "buang lock apt basi: ${l#"$PREFIX"/}"
    [ "$dry" -eq 0 ] && rm -f "$l"
    fixes=$((fixes + 1))
  done

  # 5. shim compat V2
  if [ -x "$PREFIX/share/opencode-v2/opencode.real" ] &&
    [ ! -e "$PREFIX/share/opencode-v2/lib/compat/libc.so" ]; then
    codemux_repair_say "buat ulang shim compat V2 (libc.so, libm.so)"
    fixes=$((fixes + 1))
    if [ "$dry" -eq 0 ]; then
      mkdir -p "$PREFIX/share/opencode-v2/lib/compat" 2>/dev/null
      ln -sf "$PREFIX/glibc/lib/libc.so.6" "$PREFIX/share/opencode-v2/lib/compat/libc.so" 2>/dev/null || true
      ln -sf "$PREFIX/glibc/lib/libm.so.6" "$PREFIX/share/opencode-v2/lib/compat/libm.so" 2>/dev/null || true
    fi
  fi

  printf '\n'
  if [ "$fixes" -eq 0 ]; then
    log_ok "tidak ada yang perlu diperbaiki."
  elif [ "$dry" -eq 1 ]; then
    log_dim "$fixes perbaikan akan dijalankan (dry-run: belum diubah)."
  else
    log_ok "$fixes perbaikan selesai."
    log_dim "lanjutkan dengan: codemux install"
  fi
  return 0
}
