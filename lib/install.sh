# shellcheck shell=bash
# lib/install.sh — `codemux install` (M2) + `codemux status`.
# Nature: idempotent, atomic, resumable after being killed midway.

# Base modules: always installed, whatever OpenCode components are chosen.
# The V1/V2 payload modules are appended only when selected.
CODEMUX_INSTALL_BASE=(deps mirror storage toolset glibc)
CODEMUX_INSTALL_TAIL=(launcher dotfiles memory self)
CODEMUX_INSTALL_CRITICAL="deps glibc"

codemux_in_list() {
  case ",$2," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Interactive picker (only used when the user runs `codemux install` in a TTY
# and has not chosen before). Everything stays English: repo output only.
codemux_components_ask() {
  local ans
  # The prompt goes to stderr: only the answer is captured by $( ).
  printf '\n%sWhich OpenCode should be installed?%s\n' "$C_B" "$C_R" >&2
  printf '  1) OpenCode V1 only (stable, legacy DB)\n' >&2
  printf '  2) OpenCode V2 only (new, separate DB)\n' >&2
  printf '  3) Both (V1 + V2, default)\n' >&2
  printf 'Choose [3]: ' >&2
  read -r ans || ans=""
  case "$ans" in
    1) printf 'v1' ;;
    2) printf 'v2' ;;
    *) printf 'v1 v2' ;;
  esac
}

# Build the module list for this run (base + selected payloads + shared tail).
codemux_install_modules() {
  local comps="$1" m
  local -a list=("${CODEMUX_INSTALL_BASE[@]}")
  case " $comps " in *" v1 "*) list+=(v1) ;; esac
  case " $comps " in *" v2 "*) list+=(v2) ;; esac
  list+=("${CODEMUX_INSTALL_TAIL[@]}")
  CODEMUX_INSTALL_MODULES=("${list[@]}")
  return 0
}

# use verify when available, otherwise fall back to probe
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
  local dry=0 fresh=0 only="" skip="" comps="" i=0 total need=0 m act note
  local failed=0 ok_n=0 fail_n=0 skip_n=0 compfile
  local -A PS=() PN=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --yes | -y) CODEMUX_YES=1 ;;
      --fresh) fresh=1 ;;
      --only) only="${2:-}"; shift ;;
      --only=*) only="${1#--only=}" ;;
      --components) only="${2:-}"; shift ;;
      --components=*) only="${1#--components=}" ;;
      --skip) skip="${2:-}"; shift ;;
      --skip=*) skip="${1#--skip=}" ;;
      -h | --help) codemux_usage; return 0 ;;
      *) log_warn "unknown option for install: $1" ;;
    esac
    shift
  done

  compfile="$(codemux_components_file)"
  if [ -n "$only" ]; then
    comps="$(codemux_components_norm "$only")" || {
      log_fail "unknown component list '$only' — use: v1, v2, or both"
      return 2
    }
  elif [ -n "${CODEMUX_COMPONENTS:-}" ]; then
    comps="$(codemux_components_norm "$CODEMUX_COMPONENTS")" || {
      log_fail "unknown CODEMUX_COMPONENTS '${CODEMUX_COMPONENTS}' — use: v1, v2, or both"
      return 2
    }
  elif [ -f "$compfile" ]; then
    comps="$(codemux_components_get)"
  elif [ "$dry" -eq 0 ] && [ "${CODEMUX_YES:-0}" != 1 ] && [ -t 0 ] && [ -t 1 ]; then
    comps="$(codemux_components_ask)" || comps=""
    comps="$(codemux_components_norm "$comps")" || comps=""
  else
    comps="$(codemux_components_get)"
  fi
  [ -n "$comps" ] || comps="$(codemux_components_get)"

  # Remember the choice so check/upgrade/update-check follow it later.
  if [ "$dry" -eq 0 ]; then
    codemux_components_set "$comps" || log_warn "cannot save the component choice in $compfile"
  fi
  codemux_install_modules "$comps"

  codemux_load_modules

  PROBE=OK; NOTE=""
  m_preflight_probe 2>/dev/null || true
  case "$PROBE" in
    FAIL) log_fail "preflight failed: $NOTE"; return 2 ;;
    WARN) log_warn "preflight: $NOTE" ;;
  esac

  codemux_spin_start "" "checking the current state"
  for m in "${CODEMUX_INSTALL_MODULES[@]}"; do
    codemux_verify_module "$m"
    PS[$m]="$PROBE"
    PN[$m]="$NOTE"
  done
  codemux_spin_stop

  total=${#CODEMUX_INSTALL_MODULES[@]}
  printf '%s%s %s%s · install [%s]%s\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R" \
    "$(printf '%s' "$comps" | tr ' ' '+')" \
    "$([ "$dry" -eq 1 ] && printf ' (dry-run)')"

  for m in "${CODEMUX_INSTALL_MODULES[@]}"; do
    i=$((i + 1))
    if codemux_in_list "$m" "$skip"; then
      act=SKIP; note="skipped (--skip)"
    elif [ "${PS[$m]}" = OK ]; then
      act="ready"; note="${PN[$m]}"
    else
      act="INSTALL"; note="${PN[$m]}"; need=$((need + 1))
    fi
    printf '  %d/%d %-10s %-7s %s\n' "$i" "$total" "$m" "$act" "$note"
  done
  printf '\n'

  if [ "$need" -eq 0 ]; then
    log_ok "all modules are ready — nothing to install."
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
    log_dim "--dry-run mode: nothing was changed."
    return 0
  fi

  local lock_rc=0
  codemux_lock_acquire || lock_rc=$?
  case "$lock_rc" in
    0) : ;;
    1) log_fail "another process is running: $(codemux_lock_info)"; return 3 ;;
    *) log_fail "cannot write $CODEMUX_HOME"; return 2 ;;
  esac
  # shellcheck disable=SC2064
  trap 'codemux_lock_release' EXIT INT TERM

  codemux_state_init
  codemux_log_start
  printf 'install start · components=%s · skip=%s · preflight=%s\n' \
    "$comps" "${skip:-none}" "$NOTE" >>"$CODEMUX_LOG"

  if [ "$fresh" -eq 1 ] || [ ! -f "$(codemux_run_file)" ]; then
    codemux_run_reset "${CODEMUX_INSTALL_MODULES[@]}"
  else
    log_info "resuming the previous run (use --fresh to start over)"
  fi
  codemux_run_reconcile

  i=0
  for m in "${CODEMUX_INSTALL_MODULES[@]}"; do
    i=$((i + 1))
    printf '[%d/%d] %-10s ' "$i" "$total" "$m"

    if codemux_in_list "$m" "$skip"; then
      codemux_run_set "$m" SKIP "skipped (--skip)"
      codemux_state_set "$m" SKIP "-" "skipped (--skip)"
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
    APPLY_NOTE=""
    codemux_spin_start "$(printf '[%d/%d] %-10s ' "$i" "$total" "$m")" "installing"
    if "m_${m}_apply" 2>>"$CODEMUX_LOG"; then :; fi
    codemux_spin_stop
    codemux_verify_module "$m"

    if [ "$PROBE" = OK ]; then
      codemux_run_set "$m" DONE "${APPLY_NOTE:-$NOTE}"
      codemux_state_set "$m" DONE "-" "${APPLY_NOTE:-$NOTE}"
      printf '%sOK%s    %s\n' "$C_OK" "$C_R" "${APPLY_NOTE:-$NOTE}"
      ok_n=$((ok_n + 1))
    elif [ "$PROBE" = WARN ]; then
      # already installed, but needs attention (e.g. MEMORY.md almost full).
      codemux_run_set "$m" DONE "${APPLY_NOTE:-$NOTE}"
      codemux_state_set "$m" WARN "-" "${APPLY_NOTE:-$NOTE}"
      printf '%sWARN%s  %s\n' "$C_WARN" "$C_R" "$NOTE"
      ok_n=$((ok_n + 1))
    else
      codemux_run_set "$m" FAILED "${APPLY_NOTE:-$NOTE}"
      codemux_state_set "$m" FAILED "-" "${APPLY_NOTE:-$NOTE}"
      printf '%sFAIL%s  %s\n' "$C_MISS" "$C_R" "${APPLY_NOTE:-$NOTE}"
      fail_n=$((fail_n + 1))
      failed=1
      if codemux_in_list "$m" "$CODEMUX_INSTALL_CRITICAL"; then
        log_warn "critical step '$m' failed — stopping here."
        log_dim "fix the cause, then run again: codemux install"
        break
      fi
    fi
  done

  printf '\n'
  codemux_run_summary || true
  if [ "$failed" -eq 0 ]; then
    log_ok "install finished: $ok_n ready · $skip_n skipped."
  else
    log_fail "$fail_n steps failed."
    log_dim "see: codemux status · resume: codemux install · repair: codemux repair"
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
    printf '\nlast install progress:\n'
    awk -F'\t' '!/^#/ {printf "  %-10s %-12s %s\n", $1, $2, $7}' "$f"
    codemux_run_summary || true
  else
    printf '\nno install run yet (run: codemux install)\n'
  fi

  local log
  log="$(codemux_log_latest)"
  if [ -n "$log" ]; then
    printf '\nlast log: %s\n' "$log"
    tail -n 10 "$log" 2>/dev/null | sed 's/^/  /'
  fi
  return 0
}
