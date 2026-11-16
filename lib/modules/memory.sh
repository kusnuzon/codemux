# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: memory — cross-session memory for V1 + V2 (see PRD §12A).
# Rule: NEVER overwrite an existing MEMORY.md/AGENTS.md.

# Source of the mechanism (code, not personal data). Can be overridden via env for tests.
CODEMUX_MEMORY_PLUGIN_URL="${CODEMUX_MEMORY_PLUGIN_URL:-https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/plugins/memory.js}"
CODEMUX_MEMORY_TITLE_URL="${CODEMUX_MEMORY_TITLE_URL:-https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/plugins/session-title.js}"
CODEMUX_MEMORY_NOTICE_URL="${CODEMUX_MEMORY_NOTICE_URL:-https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/plugins/update-notice.js}"
CODEMUX_MEMORY_DIGEST_URL="${CODEMUX_MEMORY_DIGEST_URL:-https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/plugins/session-digest.py}"
CODEMUX_MEMORY_QUOTA_URL="${CODEMUX_MEMORY_QUOTA_URL:-https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/plugins/quota.py}"
CODEMUX_MEMORY_LIMIT="${CODEMUX_MEMORY_LIMIT:-24000}"

codemux_memory_base() { printf '%s/.config/opencode' "$HOME"; }

# Point a downloaded Python script at this Termux prefix (shebang on line 1).
codemux_py_shebang() {
  local f="$1"
  [ -f "$f" ] || return 1
  sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$f" 2>/dev/null || return 1
  return 0
}

# The estimator used to be called `kuota` (< 0.7.6). Drop the old file and
# symlink so only one name stays reachable.
codemux_memory_drop_legacy() {
  rm -f "$(codemux_memory_base)/bin/kuota" 2>/dev/null || true
  if [ -L "$PREFIX/bin/kuota" ]; then
    rm -f "$PREFIX/bin/kuota" 2>/dev/null || true
  fi
  return 0
}

# Refresh the mechanism (code only) from upstream: fetch, compare, back up, swap.
# Personal data (MEMORY.md, AGENTS.md, RECENT.md, opencode.jsonc contents) is
# never replaced — only the plugins/scripts that keep the feature working.
# Sets CODEMUX_MEMORY_CHANGED to the number of files that were replaced.
codemux_memory_sync_mechanism() {
  local base pair mode rel url dst tmp changed=0 rc=0
  base="$(codemux_memory_base)"
  mkdir -p "$base/bin" "$base/plugins" "$CODEMUX_HOME/cache" || return 1
  local pairs=(
    "600|plugins/memory.js|$CODEMUX_MEMORY_PLUGIN_URL"
    "600|plugins/session-title.js|$CODEMUX_MEMORY_TITLE_URL"
    "600|plugins/update-notice.js|$CODEMUX_MEMORY_NOTICE_URL"
    "700|bin/session-digest.py|$CODEMUX_MEMORY_DIGEST_URL"
    "700|bin/quota|$CODEMUX_MEMORY_QUOTA_URL"
  )
  for pair in "${pairs[@]}"; do
    IFS='|' read -r mode rel url <<<"$pair"
    dst="$base/$rel"
    tmp="$CODEMUX_HOME/cache/$(basename "$rel")"
    if ! codemux_fetch_raw "$url" "$tmp"; then
      log_warn "memory: could not download $rel"
      rc=1
      continue
    fi
    case "$rel" in
      bin/*) codemux_py_shebang "$tmp" || true ;;
    esac
    if [ -s "$dst" ] && cmp -s "$tmp" "$dst"; then
      continue
    fi
    if [ -s "$dst" ]; then
      codemux_backup memory "$dst" >/dev/null 2>&1 || true
    fi
    if codemux_atomic_write "$dst" <"$tmp"; then
      chmod "$mode" "$dst" 2>/dev/null || true
      changed=$((changed + 1))
      log_dim "memory: $rel updated"
    else
      log_warn "memory: could not write $rel"
      rc=1
    fi
  done
  if [ -x "$base/bin/quota" ]; then
    mkdir -p "$PREFIX/bin" 2>/dev/null || true
    ln -sf "$base/bin/quota" "$PREFIX/bin/quota" 2>/dev/null || true
  fi
  codemux_memory_drop_legacy
  CODEMUX_MEMORY_CHANGED="$changed"
  return "$rc"
}

# Digest wrapper: only once in ~/.bashrc (a codemux:memory marked block).
codemux_memory_wrapper_present() {
  grep -q '_oc_refresh_digest()' "$HOME/.bashrc" 2>/dev/null
}

m_memory_probe() {
  local base need miss=() f size pct
  base="$(codemux_memory_base)"
  need=("MEMORY.md" "AGENTS.md" "RECENT.md" "plugins/memory.js" "plugins/session-title.js"
    "plugins/update-notice.js" "bin/session-digest.py" "bin/quota")

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
  if ! codemux_memory_wrapper_current; then
    PROBE=WARN; NOTE="bashrc wrapper predates the terminal repair (rewritten during install)"
    return
  fi
  if grep -q '^# --- refresh the session summary before opencode starts' "$HOME/.bashrc" 2>/dev/null; then
    PROBE=WARN; NOTE="legacy opencode-termux wrapper still in .bashrc (removed during install)"
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

# Digest wrapper in ~/.bashrc (shared by V1 & V2). The block carries a version
# marker: the body has to be rewritten whenever it changes, because an older
# block that is already in the file would keep winning (same function names,
# first definition is overridden but two copies are dead weight).
CODEMUX_MEMORY_WRAPPER_VERSION="5"

codemux_memory_wrapper_body() {
  # The version line is printed from the constant, never typed twice: bumping the
  # constant alone would leave the marker on the old number, the probe would keep
  # reporting "outdated", and every install would rewrite an identical block.
  printf '\n%s\n' "# codemux:memory begin  (managed by codemux — refresh the session summary before opencode)"
  printf '# codemux:memory version %s\n' "$CODEMUX_MEMORY_WRAPPER_VERSION"
  cat <<'EOS'
_oc_refresh_digest() {
  [ -x "$HOME/.config/opencode/bin/session-digest.py" ] || return 0
  python3 "$HOME/.config/opencode/bin/session-digest.py" >/dev/null 2>&1
}
# V1 keeps its own database. Drop the V2 XDG_* values so starting V1 from a V2
# shell cannot point it at the V2 database ("no session table", blank screen).
# Also put the terminal back after EVERY agent run: a clean /exit can still
# leave raw termios or the alternate screen behind, and the shell then looks
# frozen (keys arrive, nothing echoes). Gating the repair on a failed exit code
# is not enough. stty reads /dev/tty because stdin can be the broken fd.
_oc_tty_repair() {
  [ -t 1 ] || return 0
  # End a control string a killed TUI left open (BEL ends OSC, ST ends DCS/APC)
  # and send XON: a stray XOFF pauses all output and looks like a frozen screen.
  printf '\007\033\\\033\\\017'
  # termios back to sane; stdin, /dev/tty and stderr are tried in turn because a
  # full-screen agent can leave any one of them unusable.
  if command -v stty >/dev/null 2>&1; then
    stty sane 2>/dev/null || stty sane </dev/tty 2>/dev/null || stty sane <&2 2>/dev/null
  fi
  # Leave alternate screen, mouse, focus, bracketed-paste, synchronized-output
  # and scroll-region modes, reset the emulator (RIS), then clear + home: until
  # that happens the screen keeps the agent's last frame while the shell is fine.
  printf '\033[?2026l\033[?2031l\033[?1049l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?1016l\033[?1004l\033[?2004l\033[?1l\033>\033[!p\033[r\033[?6l\033[?7h\033(B\033[0m\033[?25h\033c\033[2J\033[H'
}
opencode() {
  _oc_refresh_digest
  local rc=0
  ( unset XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; command opencode "$@" )
  rc=$?
  _oc_tty_repair
  return "$rc"
}
opencode-v2() {
  _oc_refresh_digest
  local rc=0
  command opencode-v2 "$@"
  rc=$?
  _oc_tty_repair
  return "$rc"
}
# codemux:memory end
EOS
}

codemux_memory_wrapper_current() {
  grep -q "codemux:memory version $CODEMUX_MEMORY_WRAPPER_VERSION" "$HOME/.bashrc" 2>/dev/null
}

# Older `opencode-termux` installers appended a markerless copy of this wrapper
# to ~/.bashrc (header: "--- refresh the session summary ..."). It carries the
# old "repair only when the exit code is non-zero" behaviour and would keep
# shadowing nothing but confuse readers, so it is dropped: one definition, one
# behaviour. awk keeps this to a single pass and cannot touch other blocks.
codemux_memory_drop_legacy_wrapper() {
  local rc="$HOME/.bashrc" tmp bak tdir
  grep -q '^# --- refresh the session summary before opencode starts' "$rc" 2>/dev/null || return 0
  # `mktemp` with no template uses /tmp, which Termux does not have: fall back to
  # $TMPDIR and then the prefix's tmp, like the launcher module does.
  tdir="${TMPDIR:-${PREFIX:-/tmp}}"
  mkdir -p "$tdir" 2>/dev/null || tdir="$HOME/.cache/codemux"
  mkdir -p "$tdir" 2>/dev/null || return 1
  tmp="$(mktemp "$tdir/codemux-memrc.XXXXXX" 2>/dev/null)" || return 1
  awk '
    /^# --- refresh the session summary before opencode starts/ { skip = 1; next }
    skip && /^opencode-v2\(\) \{/ { in_v2 = 1; next }
    skip && in_v2 && /^\}/ { skip = 0; in_v2 = 0; next }
    !skip { print }
  ' "$rc" >"$tmp" || { rm -f "$tmp"; return 1; }
  bak="$(codemux_backup memory "$rc")" || true
  if ! cp "$tmp" "$rc" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  if ! bash -n "$rc" 2>/dev/null; then
    [ -n "$bak" ] && cp -a "$bak" "$rc"
    return 1
  fi
  chmod 600 "$rc" 2>/dev/null || true
  return 0
}

# Replace any marked wrapper block with the current body. The old block is
# removed first (both the `memory` and the legacy `memory-xdg` variant) so the
# file keeps exactly one definition.
codemux_memory_write_wrapper() {
  local rc="$HOME/.bashrc" bak
  [ -f "$rc" ] || : >"$rc" || return 1
  bak="$(codemux_backup memory "$rc")" || return 1
  sed -i '/^# codemux:memory begin/,/^# codemux:memory end/d' "$rc" 2>/dev/null || true
  sed -i '/^# codemux:memory-xdg begin/,/^# codemux:memory-xdg end/d' "$rc" 2>/dev/null || true
  codemux_memory_drop_legacy_wrapper || true
  codemux_memory_wrapper_body >>"$rc" || return 1
  if ! bash -n "$rc" 2>/dev/null; then
    [ -n "$bak" ] && cp -a "$bak" "$rc"
    return 1
  fi
  chmod 600 "$rc" 2>/dev/null || true
  return 0
}

# Digest wrapper in ~/.bashrc (shared by V1 & V2).
codemux_memory_ensure_wrapper() {
  # A wrapper from an older `opencode-termux` install has no marker, so the
  # rewrite below cannot see it: drop it first, then decide.
  codemux_memory_drop_legacy_wrapper || true
  codemux_memory_wrapper_current && return 0
  codemux_memory_write_wrapper || return 1
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

  # 2) mechanism (plugins + digest + quota) — fetched from the upstream repo
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
  if [ ! -s "$base/plugins/update-notice.js" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_NOTICE_URL" "$base/plugins/update-notice.js" || {
      APPLY_NOTE="failed to download plugins/update-notice.js"; return 1
    }
    chmod 600 "$base/plugins/update-notice.js" 2>/dev/null || true
    made+=("plugins/update-notice.js")
  fi
  if [ ! -s "$base/bin/session-digest.py" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_DIGEST_URL" "$base/bin/session-digest.py" || {
      APPLY_NOTE="failed to download bin/session-digest.py"; return 1
    }
    codemux_py_shebang "$base/bin/session-digest.py"
    chmod 700 "$base/bin/session-digest.py" 2>/dev/null || true
    made+=("bin/session-digest.py")
  fi
  if [ ! -s "$base/bin/quota" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_QUOTA_URL" "$base/bin/quota" || {
      APPLY_NOTE="failed to download bin/quota"; return 1
    }
    codemux_py_shebang "$base/bin/quota"
    chmod 700 "$base/bin/quota" 2>/dev/null || true
    made+=("bin/quota")
  fi
  # `quota` must be reachable from PATH (the launcher menu checks `command -v`).
  if [ -x "$base/bin/quota" ]; then
    mkdir -p "$PREFIX/bin" 2>/dev/null || true
    ln -sf "$base/bin/quota" "$PREFIX/bin/quota" 2>/dev/null ||
      APPLY_NOTE="quota installed, but the symlink in $PREFIX/bin failed"
  fi
  codemux_memory_drop_legacy

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
