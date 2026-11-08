# shellcheck shell=bash
# lib/check.sh — `codemux check` runner (read-only, does not modify the system).

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
  local ok=0 warn=0 miss=0 fail=0 skip=0 comps
  local total="${#CODEMUX_MODULES[@]}"
  local -a J=()

  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      *) log_warn "unknown option for check: $a" ;;
    esac
  done

  codemux_load_modules
  comps="$(codemux_components_get)"

  if [ "$json" -eq 0 ]; then
    printf '%s%s %s%s · check mode (changes nothing)\n\n' \
      "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R"
  fi

  for m in "${CODEMUX_MODULES[@]}"; do
    i=$((i + 1))
    PROBE=OK
    NOTE=""
    if { [ "$m" = v1 ] || [ "$m" = v2 ]; } && ! codemux_component_selected "$m"; then
      # Not selected by the user: report it, but do not count it as missing.
      PROBE=SKIP
      NOTE="not selected (components: $comps)"
    else
      "m_${m}_probe" 2>/dev/null || true
    fi
    label="$(codemux_label "$m")"

    case "$PROBE" in
      OK) ok=$((ok + 1)) ;;
      WARN) warn=$((warn + 1)) ;;
      MISS) miss=$((miss + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      SKIP) skip=$((skip + 1)) ;;
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
        SKIP) printf '[%2d/%2d] %-12s %sSKIP%s  %s%s%s\n' "$i" "$total" "$label" "$C_DIM" "$C_R" "$C_DIM" "$NOTE" "$C_R" ;;
      esac
    fi
  done

  local joined
  joined="$(printf '%s,' "${J[@]}" 2>/dev/null || true)"
  joined="${joined%,}"

  if [ "$json" -eq 1 ]; then
    printf '{"codemux":"%s","versi":"%s","komponen":"%s","modul":[%s],"ringkasan":{"ok":%d,"warn":%d,"miss":%d,"fail":%d,"skip":%d}}\n' \
      "$CODEMUX_NAME" "$CODEMUX_VERSION" "$comps" "$joined" "$ok" "$warn" "$miss" "$fail" "$skip"
  else
    printf '\n'
    printf '%s%d OK%s · %s%d WARN%s · %s%d MISS%s · %s%d FAIL%s · %s%d SKIP%s\n' \
      "$C_OK" "$ok" "$C_R" "$C_WARN" "$warn" "$C_R" "$C_MISS" "$miss" "$C_R" \
      "$C_MISS" "$fail" "$C_R" "$C_DIM" "$skip" "$C_R"

    if [ "$fail" -gt 0 ]; then
      log_fail "some components do not meet the requirements yet — see the FAIL lines above."
    elif [ "$miss" -gt 0 ] || [ "$warn" -gt 0 ]; then
      log_info "whatever is still missing will be installed by \`codemux install\`."
    else
      log_ok "all components are ready."
    fi
  fi

  if [ "$fail" -gt 0 ]; then
    return 2
  elif [ "$miss" -gt 0 ] || [ "$warn" -gt 0 ]; then
    return 1
  fi
  return 0
}
