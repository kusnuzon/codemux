# shellcheck shell=bash
# lib/memory.sh — `codemux memory`: status ingatan lintas sesi (read-only).

codemux_cmd_memory() {
  local json=0 a base size pct st total=0
  local -a rows=()

  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      status | list | check) : ;;
      -h | --help)
        printf '%s\n' \
          'penggunaan: codemux memory [--json]' \
          '' \
          'Menampilkan isi folder ingatan (~/.config/opencode): ukuran file,' \
          'entri instructions, plugin, dan wrapper digest di ~/.bashrc.' \
          'Tidak mengubah apa pun. Untuk memasang/memperbaiki: codemux install'
        return 0
        ;;
      *) log_warn "opsi tidak dikenal untuk memory: $a" ;;
    esac
  done

  codemux_load_modules
  base="$(codemux_memory_base)"

  local -a files=("MEMORY.md" "AGENTS.md" "RECENT.md" "plugins/memory.js"
    "bin/session-digest.py" "opencode.jsonc")
  local f path s mark

  for f in "${files[@]}"; do
    path="$base/$f"
    if [ -f "$path" ]; then
      s="$(wc -c <"$path" 2>/dev/null || echo 0)"; s="${s// /}"
      mark=ada
    else
      s=0; mark=tidak
    fi
    total=$((total + s))
    if [ "$json" -eq 0 ]; then
      rows+=("$(printf '  %-24s %-6s %s' "$f" "$mark" "$(human_bytes "$s")")")
    fi
  done

  size="$(wc -c <"$base/MEMORY.md" 2>/dev/null || echo 0)"; size="${size// /}"
  pct=$((size * 100 / CODEMUX_MEMORY_LIMIT))
  if [ "$pct" -ge 100 ]; then st=FAIL; elif [ "$pct" -ge 90 ]; then st=WARN; else st=OK; fi

  if [ "$json" -eq 1 ]; then
    printf '{"folder":"%s","total_bytes":%d,"memory_bytes":%d,"limit_bytes":%d,"persen":%d,"status":"%s","wrapper_bashrc":%s,' \
      "$(json_escape "$base")" "$total" "$size" "$CODEMUX_MEMORY_LIMIT" "$pct" "$st" \
      "$(codemux_memory_wrapper_present && echo true || echo false)"
    printf '"instructions":['
    local first=1 p
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ "$first" -eq 1 ] || printf ','
      printf '"%s"' "$(json_escape "$p")"
      first=0
    done < <(sed -n 's/.*"\([^"]*\.md\)".*/\1/p' "$base/opencode.jsonc" 2>/dev/null || true)
    printf ']}\n'
    return 0
  fi

  printf '%s%s %s%s · ingatan lintas sesi (read-only)\n\n' \
    "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R"
  printf '  folder: %s\n\n' "$base"
  printf '%s\n' "${rows[@]}"
  printf '\n'
  printf '  MEMORY.md  : %s / %s (%d%%) — %s\n' \
    "$(human_bytes "$size")" "$(human_bytes "$CODEMUX_MEMORY_LIMIT")" "$pct" "$st"
  printf '  total      : %s\n' "$(human_bytes "$total")"
  printf '  wrapper    : %s\n' "$(codemux_memory_wrapper_present &&
    echo 'ada di ~/.bashrc' || echo 'BELUM ada — jalankan: codemux install')"

  if [ -f "$base/opencode.jsonc" ]; then
    printf '\n  instructions:\n'
    sed -n 's/.*"\([^"]*\.md\)".*/    \1/p' "$base/opencode.jsonc" 2>/dev/null || true
  fi
  printf '\n'
  if [ "$st" = FAIL ]; then
    log_fail "MEMORY.md sudah melewati batas — memory_save akan gagal; pangkas entri usang."
  elif [ "$st" = WARN ]; then
    log_warn "MEMORY.md hampir penuh — pertimbangkan memangkas entri usang."
  else
    log_ok "ingatan sehat."
  fi
  log_dim "pasang/perbaiki: codemux install · cek semua modul: codemux check"
  return 0
}
