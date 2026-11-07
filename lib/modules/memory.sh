# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: memory — cross-session memory for V1 + V2 (see PRD §12A).
# Rule: NEVER overwrite an existing MEMORY.md/AGENTS.md.

# Source of the mechanism (code, not personal data). Can be overridden via env for tests.
CODEMUX_MEMORY_PLUGIN_URL="${CODEMUX_MEMORY_PLUGIN_URL:-https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/plugins/memory.js}"
CODEMUX_MEMORY_TITLE_URL="${CODEMUX_MEMORY_TITLE_URL:-https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/plugins/session-title.js}"
CODEMUX_MEMORY_DIGEST_URL="${CODEMUX_MEMORY_DIGEST_URL:-https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/plugins/session-digest.py}"
CODEMUX_MEMORY_LIMIT="${CODEMUX_MEMORY_LIMIT:-24000}"

codemux_memory_base() { printf '%s/.config/opencode' "$HOME"; }

# Digest wrapper: only once in ~/.bashrc (a codemux:memory marked block).
codemux_memory_wrapper_present() {
  grep -q '_oc_refresh_digest()' "$HOME/.bashrc" 2>/dev/null
}

m_memory_probe() {
  local base need miss=() f size pct
  base="$(codemux_memory_base)"
  need=("MEMORY.md" "AGENTS.md" "RECENT.md" "plugins/memory.js" "plugins/session-title.js" "bin/session-digest.py")

  for f in "${need[@]}"; do
    [ -f "$base/$f" ] || miss+=("$f")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    PROBE=MISS; NOTE="missing: ${miss[*]}"
    return
  fi

  if ! grep -q 'MEMORY.md' "$base/opencode.jsonc" 2>/dev/null; then
    PROBE=WARN; NOTE="opencode.jsonc does not list MEMORY.md in instructions yet"
    return
  fi
  if ! grep -q 'RECENT.md' "$base/opencode.jsonc" 2>/dev/null; then
    PROBE=WARN; NOTE="opencode.jsonc does not list RECENT.md in instructions yet"
    return
  fi
  if ! codemux_memory_wrapper_present; then
    PROBE=WARN; NOTE="digest wrapper in ~/.bashrc is missing (added during install)"
    return
  fi

  size="$(wc -c <"$base/MEMORY.md" 2>/dev/null || echo 0)"
  size="${size// /}"
  pct=$((size * 100 / CODEMUX_MEMORY_LIMIT))
  if [ "$pct" -ge 100 ]; then
    PROBE=FAIL; NOTE="MEMORY.md ${size}B ≥ ${CODEMUX_MEMORY_LIMIT}B (memory_save will fail) — trim it first"
  elif [ "$pct" -ge 90 ]; then
    PROBE=WARN; NOTE="MEMORY.md ${size}B (${pct}% of ${CODEMUX_MEMORY_LIMIT}B) — almost full"
  else
    PROBE=OK; NOTE="MEMORY.md ${size}B (${pct}%) · RECENT.md present"
  fi
}

m_memory_verify() { m_memory_probe; }

# Add the instructions entries without breaking the opencode.jsonc contents.
# Uses python3 (available after the toolset step). Failure → reported, file intact.
codemux_memory_ensure_instructions() {
  local conf="$1" base="$2" out rc=0

  if ! have python3; then
    APPLY_NOTE="python3 is missing — add the MEMORY.md & RECENT.md entries to instructions manually"
    return 1
  fi
  out="$(python3 "$CODEMUX_ROOT/templates/jsonc-instructions.py" "$conf" \
    "$base/MEMORY.md" "$base/RECENT.md" 2>&1)" || rc=$?
  case "$rc" in
    0) : ;;
    *) APPLY_NOTE="failed to edit opencode.jsonc: $out"; return 1 ;;
  esac
  # result note: NOTHING_TO_DO / ADDED:... / CREATED:...
  INSTRUCTIONS_RESULT="$out"
  return 0
}

# Digest wrapper in ~/.bashrc (shared by V1 & V2).
codemux_memory_ensure_wrapper() {
  local rc="$HOME/.bashrc" size bak
  if codemux_memory_wrapper_present; then
    return 0
  fi
  [ -f "$rc" ] || : >"$rc" || return 1
  bak="$(codemux_backup memory "$rc")" || return 1
  size="$(wc -c <"$rc" 2>/dev/null || echo 0)"
  size="${size// /}"

  cat >>"$rc" <<'EOS'

# codemux:memory begin  (managed by codemux — refresh the session summary before opencode)
_oc_refresh_digest() {
  [ -x "$HOME/.config/opencode/bin/session-digest.py" ] || return 0
  python3 "$HOME/.config/opencode/bin/session-digest.py" >/dev/null 2>&1
}
opencode() { _oc_refresh_digest; command opencode "$@"; }
opencode-v2() { _oc_refresh_digest; command opencode-v2 "$@"; }
# codemux:memory end
EOS

  if ! bash -n "$rc" 2>/dev/null; then
    # restore the original size (we only appended to the tail)
    truncate -s "$size" "$rc" 2>/dev/null || { [ -n "$bak" ] && cp -a "$bak" "$rc"; }
    return 1
  fi
  chmod 600 "$rc" 2>/dev/null || true
  return 0
}

m_memory_apply() {
  local base tpl made=() f
  base="$(codemux_memory_base)"
  tpl="$CODEMUX_ROOT/templates/memory"

  mkdir -p "$base/plugins" "$base/bin" || { APPLY_NOTE="cannot create $base"; return 1; }

  # 1) personal data: create only when missing — NEVER overwrite
  for f in MEMORY.md AGENTS.md; do
    if [ ! -f "$base/$f" ] && [ -f "$tpl/$f" ]; then
      cp "$tpl/$f" "$base/$f" && chmod 600 "$base/$f" 2>/dev/null && made+=("$f")
    fi
  done

  # 2) mechanism (plugins + digest) — fetched from the upstream repo
  if [ ! -s "$base/plugins/memory.js" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_PLUGIN_URL" "$base/plugins/memory.js" || {
      APPLY_NOTE="failed to download plugins/memory.js"; return 1
    }
    chmod 600 "$base/plugins/memory.js" 2>/dev/null || true
    made+=("plugins/memory.js")
  fi
  if [ ! -s "$base/plugins/session-title.js" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_TITLE_URL" "$base/plugins/session-title.js" || {
      APPLY_NOTE="failed to download plugins/session-title.js"; return 1
    }
    chmod 600 "$base/plugins/session-title.js" 2>/dev/null || true
    made+=("plugins/session-title.js")
  fi
  if [ ! -s "$base/bin/session-digest.py" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_DIGEST_URL" "$base/bin/session-digest.py" || {
      APPLY_NOTE="failed to download bin/session-digest.py"; return 1
    }
    chmod 700 "$base/bin/session-digest.py" 2>/dev/null || true
    made+=("bin/session-digest.py")
  fi

  # 3) RECENT.md: generate it now if missing
  if [ ! -f "$base/RECENT.md" ]; then
    if have python3; then
      python3 "$base/bin/session-digest.py" >/dev/null 2>&1 || true
    fi
    if [ ! -f "$base/RECENT.md" ]; then
      printf '%s\n' '# RECENT' '' '> Session summary generated automatically; this file is overwritten.' \
        | codemux_atomic_write "$base/RECENT.md" || {
        APPLY_NOTE="failed to create RECENT.md"; return 1
      }
    fi
    made+=("RECENT.md")
  fi

  # 4) opencode.jsonc: create it or complete the instructions entries
  INSTRUCTIONS_RESULT=""
  if [ ! -f "$base/opencode.jsonc" ]; then
    if [ ! -f "$tpl/opencode.jsonc" ]; then
      APPLY_NOTE="opencode.jsonc template is missing"; return 1
    fi
    sed "s|@HOME@|$HOME|g" "$tpl/opencode.jsonc" |
      codemux_atomic_write "$base/opencode.jsonc" || {
      APPLY_NOTE="failed to create opencode.jsonc"; return 1
    }
    made+=("opencode.jsonc")
  else
    codemux_backup memory-config "$base/opencode.jsonc" >/dev/null || true
    codemux_memory_ensure_instructions "$base/opencode.jsonc" "$base" || return 1
  fi

  # 5) digest wrapper in ~/.bashrc
  codemux_memory_ensure_wrapper || {
    APPLY_NOTE="failed to add the digest wrapper in ~/.bashrc"; return 1
  }

  if [ "${#made[@]}" -gt 0 ]; then
    APPLY_NOTE="created: ${made[*]}"
  else
    APPLY_NOTE="${INSTRUCTIONS_RESULT:-already complete}"
  fi
  return 0
}
