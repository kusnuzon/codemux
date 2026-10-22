# shellcheck shell=bash
# lib/maintenance.sh — `codemux doctor`, `upgrade`, `uninstall` (M5).

# --- util --------------------------------------------------------------------
# --yes / non-tty dianggap setuju; selain itu tanya.
codemux_confirm() {
  local prompt="$1" ans
  [ "${CODEMUX_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || return 0
  printf '%s [y/N] ' "$prompt"
  read -r ans || true
  case "$ans" in y | Y | ya | YA) return 0 ;; *) return 1 ;; esac
}

codemux_strip_managed_blocks() { # <file> <tag...> → stdout tanpa blok bertanda
  local file="$1"
  shift
  local -a tags=("$@")
  awk -v tags="${tags[*]}" '
    BEGIN { n = split(tags, t, " "); for (i = 1; i <= n; i++) on[i] = 0 }
    {
      hit = 0
      for (i = 1; i <= n; i++) {
        if ($0 ~ ("# codemux:" t[i] " begin")) { on[i] = 1; hit = 1 }
        if ($0 ~ ("# codemux:" t[i] " end")) { on[i] = 0; hit = 1 }
        if (on[i]) hit = 1
      }
      if (!hit) print
    }
    END {
      for (i = 1; i <= n; i++) if (on[i]) exit 3
    }
  ' "$file"
}

# --- doctor ------------------------------------------------------------------
codemux_cmd_doctor() {
  local a extra_fail=0 rc=0 base size pct free_kb age
  for a in "$@"; do
    case "$a" in
      -h | --help) codemux_usage; return 0 ;;
      --json) log_warn "doctor --json belum tersedia; pakai: codemux check --json" ;;
      *) : ;;
    esac
  done

  codemux_load_modules
  codemux_cmd_check || rc=$?

  base="$HOME/.config/opencode"
  printf '\n%sPemeriksaan tambahan%s\n' "$C_B" "$C_R"

  # 1. ~/.bashrc
  if [ -f "$HOME/.bashrc" ] && bash -n "$HOME/.bashrc" 2>/dev/null; then
    log_ok "$HOME/.bashrc lolos bash -n"
  else
    log_fail "$HOME/.bashrc rusak (bash -n gagal) — codemux install akan memulihkan dari backup"
    extra_fail=$((extra_fail + 1))
  fi
  if grep -q '_oc_refresh_digest()' "$HOME/.bashrc" 2>/dev/null; then
    log_ok "wrapper digest aktif (RECENT.md segar tiap opencode dibuka)"
  else
    log_warn "wrapper digest belum ada — jalankan: codemux install"
  fi

  # 2. memori
  if [ -f "$base/MEMORY.md" ]; then
    size="$(wc -c <"$base/MEMORY.md")"; size="${size// /}"
    pct=$((size * 100 / CODEMUX_MEMORY_LIMIT))
    if [ "$pct" -ge 100 ]; then
      log_fail "MEMORY.md ${size}B ≥ ${CODEMUX_MEMORY_LIMIT}B — memory_save akan gagal, pangkas sekarang"
      extra_fail=$((extra_fail + 1))
    elif [ "$pct" -ge 90 ]; then
      log_warn "MEMORY.md ${size}B (${pct}%) — hampir penuh, pertimbangkan pangkas"
    else
      log_ok "MEMORY.md ${size}B (${pct}% dari batas)"
    fi
  else
    log_warn "MEMORY.md belum ada — jalankan: codemux install"
  fi
  if [ -f "$base/opencode.jsonc" ] &&
    grep -q 'MEMORY.md' "$base/opencode.jsonc" &&
    grep -q 'RECENT.md' "$base/opencode.jsonc"; then
    log_ok "instructions memuat MEMORY.md + RECENT.md"
  else
    log_warn "instructions di opencode.jsonc belum lengkap — jalankan: codemux install"
  fi

  # 3. env berbahaya untuk payload glibc
  if printf '%s' "${LD_PRELOAD:-}" | grep -q 'libtermux-exec'; then
    log_fail "LD_PRELOAD bionic aktif (${LD_PRELOAD}) — bisa merusak OpenCode V2; launcher menyanasinya, shell ini tidak"
    extra_fail=$((extra_fail + 1))
  else
    log_ok "LD_PRELOAD bersih"
  fi

  # 4. disk
  free_kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  free_kb="${free_kb:-0}"
  if [ "$free_kb" -lt 1048576 ]; then
    log_warn "disk tersisa $(human_bytes $((free_kb * 1024))) — kurang dari 1 GB"
  else
    log_ok "disk tersisa $(human_bytes $((free_kb * 1024)))"
  fi

  # 5. lock & cache update
  if [ -d "$CODEMUX_HOME/lock" ]; then
    if codemux_lock_info | grep -q '^aktif'; then
      log_warn "install/upgrade lain sedang berjalan ($(codemux_lock_info))"
    else
      log_warn "lock basi — jalankan: codemux repair"
    fi
  else
    log_ok "tidak ada lock tertinggal"
  fi
  if [ -f "$(codemux_update_cache)" ]; then
    age=$(( ($(date +%s) - $(stat -c %Y "$(codemux_update_cache)" 2>/dev/null || echo 0)) / 3600 ))
    if [ "$age" -ge 24 ]; then
      log_warn "cache update ${age} jam — jalankan: codemux update-check"
    else
      log_ok "cache update ${age} jam"
    fi
  else
    log_warn "belum pernah cek update — jalankan: codemux update-check"
  fi

  printf '\n'
  if [ "$rc" -eq 0 ] && [ "$extra_fail" -eq 0 ]; then
    log_ok "tidak ada masalah yang perlu tindakan."
    return 0
  fi
  if [ "$extra_fail" -gt 0 ]; then
    log_fail "$extra_fail temuan tambahan perlu diperbaiki."
  else
    log_warn "ada modul yang belum siap."
  fi
  log_dim "perbaiki otomatis: codemux install · bereskan sisa proses: codemux repair"
  [ "$extra_fail" -gt 0 ] && return 1
  return "$rc"
}

# --- upgrade -----------------------------------------------------------------
codemux_upgrade_step_apt() {
  local rc=0
  log_info "apt: perbarui daftar paket"
  codemux_spawn upgrade_apt env DEBIAN_FRONTEND=noninteractive apt-get update ||
    { log_warn "gagal menjalankan apt-get update"; return 1; }
  codemux_wait upgrade_apt 1800 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "apt-get update gagal (rc $rc): $(codemux_step_tail upgrade_apt)"
    return 1
  fi
  log_info "apt: upgrade paket (opencode di-hold)"
  codemux_spawn upgrade_apt2 env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confold upgrade ||
    { log_warn "gagal menjalankan apt-get upgrade"; return 1; }
  codemux_wait upgrade_apt2 5400 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "apt-get upgrade gagal (rc $rc): $(codemux_step_tail upgrade_apt2)"
    return 1
  fi
  log_ok "apt: paket diperbarui"
  return 0
}

codemux_upgrade_step_v1() {
  local script="$PREFIX/share/opencode/upgrade.sh" rc=0
  if [ -x "$script" ]; then
    log_info "V1: $script"
    codemux_spawn upgrade_v1 bash "$script" || return 1
    codemux_wait upgrade_v1 3600 || rc=$?
    [ "$rc" -eq 0 ] || { log_warn "upgrade V1 gagal (rc $rc)"; return 1; }
  else
    log_info "V1: tidak ada upgrade.sh lokal — pasang ulang payload terbaru lewat adapter"
    m_v1_apply || return 1
  fi
  log_ok "V1: $(opencode_v1_version)"
  return 0
}

codemux_upgrade_step_v2() {
  local script="$PREFIX/share/opencode-v2/upgrade.sh" rc=0
  if [ -x "$script" ]; then
    log_info "V2: $script"
    codemux_spawn upgrade_v2 bash "$script" || return 1
    codemux_wait upgrade_v2 3600 || rc=$?
    [ "$rc" -eq 0 ] || { log_warn "upgrade V2 gagal (rc $rc)"; return 1; }
  else
    log_info "V2: tidak ada upgrade.sh lokal — pasang ulang payload terbaru lewat adapter"
    m_v2_apply || return 1
  fi
  log_ok "V2: $(opencode_v2_version)"
  return 0
}

codemux_upgrade_step_launcher() {
  m_launcher_apply || { log_warn "blok launcher gagal disinkronkan"; return 1; }
  m_dotfiles_apply || true
  codemux_memory_ensure_wrapper || { log_warn "wrapper digest gagal dipasang"; return 1; }
  log_ok "launcher + wrapper digest sinkron"
  return 0
}

codemux_cmd_upgrade() {
  local dry=0 only="" m rc=0 ok_n=0 fail_n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -y | --yes) CODEMUX_YES=1 ;;
      --only) only="${2:-}"; shift ;;
      --only=*) only="${1#--only=}" ;;
      -h | --help)
        printf '%s\n' 'penggunaan: codemux upgrade [--dry-run] [--yes] [--only apt,v1,v2,launcher]' \
          '' 'Perbarui paket apt, payload OpenCode V1/V2, lalu sinkronkan blok launcher.' \
          'opencode versi apt tetap di-hold; memori & project tidak disentuh.'
        return 0
        ;;
      *) log_warn "opsi tidak dikenal untuk upgrade: $1" ;;
    esac
    shift
  done
  codemux_load_modules

  local -a steps=(apt v1 v2 launcher)
  local -a run=()
  for m in "${steps[@]}"; do
    if [ -n "$only" ] && ! codemux_in_list "$m" "$only"; then continue; fi
    run+=("$m")
  done
  [ "${#run[@]}" -gt 0 ] || { log_fail "--only tidak cocok (apt,v1,v2,launcher)"; return 2; }

  printf '%s%s %s%s · upgrade%s\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R" \
    "$([ "$dry" -eq 1 ] && printf ' (dry-run)')"
  for m in "${run[@]}"; do
    case "$m" in
      apt) printf '  %-10s %s\n' apt 'apt-get update + upgrade (opencode di-hold)' ;;
      v1) printf '  %-10s %s\n' v1 "payload V1 sekarang $(opencode_v1_version)" ;;
      v2) printf '  %-10s %s\n' v2 "payload V2 sekarang $(opencode_v2_version)" ;;
      launcher) printf '  %-10s %s\n' launcher 'sinkronkan blok launcher + wrapper digest' ;;
    esac
  done
  printf '\n'
  if [ "$dry" -eq 1 ]; then log_dim "mode --dry-run: tidak ada yang diubah."; return 0; fi
  codemux_confirm "Lanjutkan upgrade?" || { log_dim "dibatalkan."; return 0; }

  local lock_rc=0
  codemux_lock_acquire || lock_rc=$?
  case "$lock_rc" in
    0) : ;;
    1) log_fail "proses lain sedang berjalan: $(codemux_lock_info)"; return 3 ;;
    *) log_fail "tidak bisa menulis $CODEMUX_HOME"; return 2 ;;
  esac
  # shellcheck disable=SC2064
  trap 'codemux_lock_release' EXIT INT TERM
  codemux_log_start
  printf 'upgrade mulai · hanya=%s\n' "${only:-semua}" >>"$CODEMUX_LOG"

  for m in "${run[@]}"; do
    printf '[%s] ' "$m"
    if "codemux_upgrade_step_$m" 2>>"$CODEMUX_LOG"; then
      ok_n=$((ok_n + 1)); printf '%sOK%s\n' "$C_OK" "$C_R"
    else
      fail_n=$((fail_n + 1)); printf '%sFAIL%s\n' "$C_MISS" "$C_R"
    fi
  done

  codemux_lock_release
  trap - EXIT INT TERM

  printf '\n'
  if [ "$fail_n" -eq 0 ]; then
    log_ok "upgrade selesai: $ok_n langkah."
    log_dim "cek kesehatan: codemux doctor · log: $CODEMUX_LOG"
    return 0
  fi
  log_fail "$fail_n langkah gagal."
  log_dim "lihat: codemux status · log: $CODEMUX_LOG"
  return 1
}

# --- uninstall ---------------------------------------------------------------
codemux_cmd_uninstall() {
  local dry=0 purge=0 a dest moved=() rc=0
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -y | --yes) CODEMUX_YES=1 ;;
      --purge) purge=1 ;;
      -h | --help)
        printf '%s\n' 'penggunaan: codemux uninstall [--dry-run] [--yes] [--purge]' \
          '' 'Lepas payload OpenCode V1/V2 + blok launcher di ~/.bashrc.' \
          'TIDAK menghapus MEMORY.md, AGENTS.md, project, atau backup.' \
          '--purge juga menghapus cache/state codemux (~/.config/codemux).'
        return 0
        ;;
      *) log_warn "opsi tidak dikenal untuk uninstall: $a" ;;
    esac
  done

  printf '%s%s %s%s · uninstall%s\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R" \
    "$([ "$dry" -eq 1 ] && printf ' (dry-run)')"
  printf '  yang dilepas : payload OpenCode V1 + V2 + blok launcher/wrapper di ~/.bashrc\n'
  printf '  yang tetap   : MEMORY.md, AGENTS.md, config opencode, project, backup\n'
  [ "$purge" -eq 1 ] && printf '  --purge      : hapus juga %s (state, cache, backup codemux)\n' "$CODEMUX_HOME"
  printf '\n'

  if [ "$dry" -eq 1 ]; then
    log_dim "mode --dry-run: tidak ada yang diubah."
    return 0
  fi
  codemux_confirm "Lepas OpenCode V1/V2 dari Termux?" || { log_dim "dibatalkan."; return 0; }

  dest="$CODEMUX_HOME/backup/$(date '+%Y%m%d-%H%M%S')-uninstall"
  mkdir -p "$dest" || { log_fail "tidak bisa membuat $dest"; return 2; }

  local p name
  for p in "$PREFIX/share/opencode" "$PREFIX/share/opencode-v2" \
    "$PREFIX/bin/opencode" "$PREFIX/bin/opencode-v2"; do
    [ -e "$p" ] || continue
    case "$p" in
      "$PREFIX/share/"*) name="share-$(basename "$p")" ;;
      "$PREFIX/bin/"*) name="bin-$(basename "$p")" ;;
      *) name="$(basename "$p")" ;;
    esac
    if mv "$p" "$dest/$name" 2>/dev/null; then
      moved+=("$(basename "$p")")
    else
      log_warn "gagal memindahkan $p"
      rc=1
    fi
  done

  # blok launcher + wrapper digest di ~/.bashrc
  if [ -f "$HOME/.bashrc" ] &&
    grep -q 'codemux:launcher begin\|codemux:memory begin' "$HOME/.bashrc" 2>/dev/null; then
    local bak tmp
    bak="$(codemux_backup uninstall "$HOME/.bashrc")" || true
    tmp="$(mktemp "$HOME/.bashrc.codemux.XXXXXX" 2>/dev/null)" || tmp=""
    if [ -n "$tmp" ] &&
      codemux_strip_managed_blocks "$HOME/.bashrc" launcher memory >"$tmp" 2>/dev/null; then
      if bash -n "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$HOME/.bashrc" && chmod 600 "$HOME/.bashrc"
        moved+=("blok launcher/wrapper")
      else
        rm -f "$tmp"
        log_warn "hasil tanpa blok gagal bash -n — ~/.bashrc dibiarkan utuh"
        rc=1
      fi
    else
      [ -n "$tmp" ] && rm -f "$tmp"
      log_warn "blok bertanda tidak lengkap — ~/.bashrc dibiarkan utuh"
      rc=1
    fi
    [ -n "${bak:-}" ] && log_dim "backup bashrc: $bak"
  fi

  if [ "$purge" -eq 1 ]; then
    case "$CODEMUX_HOME" in
      "$HOME"/*) rm -rf "$CODEMUX_HOME"; moved+=("$CODEMUX_HOME") ;;
      *) log_warn "tidak menghapus $CODEMUX_HOME (di luar \$HOME)"; rc=1 ;;
    esac
  fi

  printf '\n'
  if [ "${#moved[@]}" -gt 0 ]; then
    log_ok "dilepas: ${moved[*]}"
  else
    log_info "tidak ada yang perlu dilepas."
  fi
  if [ "$rc" -eq 0 ]; then
    log_dim "payload lama disimpan di: $dest"
    log_dim "pasang lagi: codemux install · memori & project tidak disentuh"
    return 0
  fi
  log_warn "sebagian langkah gagal — lihat pesan di atas."
  return 1
}
