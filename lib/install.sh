# shellcheck shell=bash
# lib/install.sh — `codemux install` (M2) + `codemux status`.
# Sifat: idempoten, atomik, bisa dilanjutkan setelah mati di tengah.

CODEMUX_INSTALL_MODULES=(deps mirror storage toolset glibc)
CODEMUX_INSTALL_CRITICAL="deps glibc"

codemux_in_list() {
  case ",$2," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# verify kalau ada, kalau tidak pakai probe
codemux_verify_module() {
  local m="$1"
  PROBE=OK
  NOTE=""
  if declare -F "m_${m}_verify" >/dev/null 2>&1; then
    "m_${m}_verify" 2>/dev/null || true
  else
    "m_${m}_probe" 2>/dev/null || true
  fi
}

codemux_cmd_install() {
  local dry=0 fresh=0 skip="" i=0 total need=0 m act note
  local failed=0 ok_n=0 fail_n=0 skip_n=0
  local -A PS=() PN=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --yes | -y) : ;;
      --fresh) fresh=1 ;;
      --skip) skip="${2:-}"; shift ;;
      --skip=*) skip="${1#--skip=}" ;;
      -h | --help) codemux_usage; return 0 ;;
      *) log_warn "opsi tidak dikenal untuk install: $1" ;;
    esac
    shift
  done

  codemux_load_modules

  PROBE=OK; NOTE=""
  m_preflight_probe 2>/dev/null || true
  case "$PROBE" in
    FAIL) log_fail "preflight gagal: $NOTE"; return 2 ;;
    WARN) log_warn "preflight: $NOTE" ;;
  esac

  for m in "${CODEMUX_INSTALL_MODULES[@]}"; do
    codemux_verify_module "$m"
    PS[$m]="$PROBE"
    PN[$m]="$NOTE"
  done

  total=${#CODEMUX_INSTALL_MODULES[@]}
  printf '%s%s %s%s · install%s\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R" \
    "$([ "$dry" -eq 1 ] && printf ' (dry-run)')"

  for m in "${CODEMUX_INSTALL_MODULES[@]}"; do
    i=$((i + 1))
    if codemux_in_list "$m" "$skip"; then
      act=SKIP; note="dilewati (--skip)"
    elif [ "${PS[$m]}" = OK ]; then
      act="siap"; note="${PN[$m]}"
    else
      act="PASANG"; note="${PN[$m]}"; need=$((need + 1))
    fi
    printf '  %d/%d %-10s %-7s %s\n' "$i" "$total" "$m" "$act" "$note"
  done
  printf '\n'

  if [ "$need" -eq 0 ]; then
    log_ok "semua modul M2 sudah siap — tidak ada yang perlu dipasang."
    if [ "$dry" -eq 0 ]; then
      codemux_state_init
      codemux_run_reset "${CODEMUX_INSTALL_MODULES[@]}"
      for m in "${CODEMUX_INSTALL_MODULES[@]}"; do
        codemux_run_set "$m" DONE "${PN[$m]}"
        codemux_state_set "$m" SKIP "-" "${PN[$m]}"
      done
    fi
    return 0
  fi

  if [ "$dry" -eq 1 ]; then
    log_dim "mode --dry-run: tidak ada yang diubah."
    return 0
  fi

  local lock_rc=0
  codemux_lock_acquire || lock_rc=$?
  case "$lock_rc" in
    0) : ;;
    1) log_fail "proses lain sedang berjalan: $(codemux_lock_info)"; return 3 ;;
    *) log_fail "tidak bisa menulis $CODEMUX_HOME"; return 2 ;;
  esac
  # shellcheck disable=SC2064
  trap 'codemux_lock_release' EXIT INT TERM

  codemux_state_init
  codemux_log_start
  printf 'install mulai · skip=%s · preflight=%s\n' "${skip:-none}" "$NOTE" >>"$CODEMUX_LOG"

  if [ "$fresh" -eq 1 ] || [ ! -f "$(codemux_run_file)" ]; then
    codemux_run_reset "${CODEMUX_INSTALL_MODULES[@]}"
  else
    log_info "melanjutkan run sebelumnya (pakai --fresh untuk mulai dari nol)"
  fi
  codemux_run_reconcile

  i=0
  for m in "${CODEMUX_INSTALL_MODULES[@]}"; do
    i=$((i + 1))
    printf '[%d/%d] %-10s ' "$i" "$total" "$m"

    if codemux_in_list "$m" "$skip"; then
      codemux_run_set "$m" SKIP "dilewati (--skip)"
      codemux_state_set "$m" SKIP "-" "dilewati (--skip)"
      printf '%sSKIP%s\n' "$C_DIM" "$C_R"
      skip_n=$((skip_n + 1))
      continue
    fi

    codemux_step_settle "$m" >/dev/null 2>&1 || true

    codemux_verify_module "$m"
    if [ "$PROBE" = OK ]; then
      codemux_run_set "$m" DONE "$NOTE"
      codemux_state_set "$m" SKIP "-" "$NOTE"
      printf '%sOK%s    %s\n' "$C_OK" "$C_R" "$NOTE"
      ok_n=$((ok_n + 1))
      continue
    fi

    codemux_run_set "$m" RUNNING ""
    printf '… '
    APPLY_NOTE=""
    if "m_${m}_apply" 2>>"$CODEMUX_LOG"; then :; fi
    codemux_verify_module "$m"

    if [ "$PROBE" = OK ]; then
      codemux_run_set "$m" DONE "${APPLY_NOTE:-$NOTE}"
      codemux_state_set "$m" DONE "-" "${APPLY_NOTE:-$NOTE}"
      printf '%sOK%s    %s\n' "$C_OK" "$C_R" "${APPLY_NOTE:-$NOTE}"
      ok_n=$((ok_n + 1))
    else
      codemux_run_set "$m" FAILED "${APPLY_NOTE:-$NOTE}"
      codemux_state_set "$m" FAILED "-" "${APPLY_NOTE:-$NOTE}"
      printf '%sFAIL%s  %s\n' "$C_MISS" "$C_R" "${APPLY_NOTE:-$NOTE}"
      fail_n=$((fail_n + 1))
      failed=1
      if codemux_in_list "$m" "$CODEMUX_INSTALL_CRITICAL"; then
        log_warn "langkah kritis '$m' gagal — berhenti di sini."
        log_dim "perbaiki penyebabnya, lalu jalankan lagi: codemux install"
        break
      fi
    fi
  done

  printf '\n'
  codemux_run_summary || true
  if [ "$failed" -eq 0 ]; then
    log_ok "install selesai: $ok_n siap · $skip_n dilewati."
  else
    log_fail "$fail_n langkah gagal."
    log_dim "lihat: codemux status · lanjutkan: codemux install · perbaiki: codemux repair"
  fi
  log_dim "log: $CODEMUX_LOG"

  [ "$failed" -eq 0 ] && return 0
  return 1
}

# --- status ------------------------------------------------------------------
codemux_cmd_status() {
  codemux_load_modules
  printf '%s%s %s%s · status\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R"

  printf 'lock   : %s\n' "$(codemux_lock_info)"
  printf 'state  : %s\n' "$CODEMUX_HOME/state.tsv"

  local f
  f="$(codemux_run_file)"
  if [ -f "$f" ]; then
    [ -d "$CODEMUX_HOME/lock" ] || codemux_run_reconcile
    printf '\nprogres install terakhir:\n'
    awk -F'\t' '!/^#/ {printf "  %-10s %-12s %s\n", $1, $2, $7}' "$f"
    codemux_run_summary || true
  else
    printf '\nbelum ada run install (jalankan: codemux install)\n'
  fi

  local log
  log="$(codemux_log_latest)"
  if [ -n "$log" ]; then
    printf '\nlog terakhir: %s\n' "$log"
    tail -n 10 "$log" 2>/dev/null | sed 's/^/  /'
  fi
  return 0
}
