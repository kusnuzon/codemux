# shellcheck shell=bash
# lib/check.sh — runner `codemux check` (read-only, tanpa mengubah sistem).

CODEMUX_MODULES=(preflight deps mirror storage toolset glibc v1 v2 launcher dotfiles memory self updatecache)

codemux_label() {
  case "$1" in
    v1) echo "opencode-v1" ;;
    v2) echo "opencode-v2" ;;
    updatecache) echo "update-cache" ;;
    *) echo "$1" ;;
  esac
}

codemux_load_modules() {
  local m
  for m in "${CODEMUX_MODULES[@]}"; do
    # shellcheck source=/dev/null
    . "$CODEMUX_ROOT/lib/modules/$m.sh"
  done
}

codemux_cmd_check() {
  local json=0 a m i=0 label
  local ok=0 warn=0 miss=0 fail=0
  local total="${#CODEMUX_MODULES[@]}"
  local -a J=()

  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      *) log_warn "opsi tidak dikenal untuk check: $a" ;;
    esac
  done

  codemux_load_modules

  if [ "$json" -eq 0 ]; then
    printf '%s%s %s%s · mode check (tidak mengubah apa pun)\n\n' \
      "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R"
  fi

  for m in "${CODEMUX_MODULES[@]}"; do
    i=$((i + 1))
    PROBE=OK
    NOTE=""
    "m_${m}_probe" 2>/dev/null || true
    label="$(codemux_label "$m")"

    case "$PROBE" in
      OK) ok=$((ok + 1)) ;;
      WARN) warn=$((warn + 1)) ;;
      MISS) miss=$((miss + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      *) PROBE=FAIL; NOTE="probe error"; fail=$((fail + 1)) ;;
    esac

    if [ "$json" -eq 1 ]; then
      J+=("{\"modul\":\"$(json_escape "$label")\",\"status\":\"$PROBE\",\"catatan\":\"$(json_escape "$NOTE")\"}")
    else
      case "$PROBE" in
        OK) printf '[%2d/%2d] %-12s %sOK%s    %s%s%s\n' "$i" "$total" "$label" "$C_OK" "$C_R" "$C_DIM" "$NOTE" "$C_R" ;;
        WARN) printf '[%2d/%2d] %-12s %sWARN%s  %s%s%s\n' "$i" "$total" "$label" "$C_WARN" "$C_R" "$C_DIM" "$NOTE" "$C_R" ;;
        MISS) printf '[%2d/%2d] %-12s %sMISS%s  %s%s%s\n' "$i" "$total" "$label" "$C_MISS" "$C_R" "$C_DIM" "$NOTE" "$C_R" ;;
        FAIL) printf '[%2d/%2d] %-12s %sFAIL%s  %s%s%s\n' "$i" "$total" "$label" "$C_MISS" "$C_R" "$C_DIM" "$NOTE" "$C_R" ;;
      esac
    fi
  done

  local joined
  joined="$(printf '%s,' "${J[@]}" 2>/dev/null || true)"
  joined="${joined%,}"

  if [ "$json" -eq 1 ]; then
    printf '{"codemux":"%s","versi":"%s","modul":[%s],"ringkasan":{"ok":%d,"warn":%d,"miss":%d,"fail":%d}}\n' \
      "$CODEMUX_NAME" "$CODEMUX_VERSION" "$joined" "$ok" "$warn" "$miss" "$fail"
  else
    printf '\n'
    printf '%s%d OK%s · %s%d WARN%s · %s%d MISS%s · %s%d FAIL%s\n' \
      "$C_OK" "$ok" "$C_R" "$C_WARN" "$warn" "$C_R" "$C_MISS" "$miss" "$C_R" "$C_MISS" "$fail" "$C_R"

    if [ "$fail" -gt 0 ]; then
      log_fail "ada komponen yang belum memenuhi syarat — lihat baris FAIL di atas."
    elif [ "$miss" -gt 0 ] || [ "$warn" -gt 0 ]; then
      log_info "yang belum lengkap akan dipasang oleh \`codemux install\`."
    else
      log_ok "semua komponen siap."
    fi
  fi

  if [ "$fail" -gt 0 ]; then
    return 2
  elif [ "$miss" -gt 0 ] || [ "$warn" -gt 0 ]; then
    return 1
  fi
  return 0
}
