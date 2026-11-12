# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: launcher — banner + menu in ~/.bashrc (codemux-marked block).
# Bump when the template changes in a way users should receive on `install`.
CODEMUX_LAUNCHER_BLOCK_VERSION="2"

m_launcher_probe() {
  local rc="$HOME/.bashrc"

  if [ ! -f "$rc" ]; then
    PROBE=MISS; NOTE='no bashrc (~/.bashrc)'; return
  fi
  if grep -q 'codemux:launcher begin' "$rc" 2>/dev/null &&
     grep -q 'codemux:launcher end' "$rc" 2>/dev/null; then
    if ! bash -n "$rc" 2>/dev/null; then
      PROBE=FAIL; NOTE="$HOME/.bashrc fails bash -n"
    elif ! grep -q "codemux:launcher version $CODEMUX_LAUNCHER_BLOCK_VERSION" "$rc" 2>/dev/null; then
      PROBE=WARN; NOTE="outdated launcher block (refreshed during install)"
    else
      PROBE=OK; NOTE="marked block present"
    fi
    return
  fi
  if grep -q '_oc_banner' "$rc" 2>/dev/null; then
    PROBE=WARN; NOTE="menu present but without codemux markers (it will be adopted)"
    return
  fi
  PROBE=MISS; NOTE="menu/banner not installed yet"
}

m_launcher_verify() { m_launcher_probe; }

# Take only the trailing region that is the old block (without markers).
# Adoption requires an _oc_launcher call and a final 'fi' line
# (the auto-launch structure at the end of ~/.bashrc). When in doubt → do not touch.
codemux_launcher_legacy_region() {
  local file="$1" tail_part last
  tail_part="$(awk '/^# --- banner \+ menu launcher/{f=1} f' "$file")"
  [ -n "$tail_part" ] || return 1
  printf '%s' "$tail_part" | grep -q '_oc_launcher' || return 1
  last="$(printf '%s\n' "$tail_part" | awk 'NF{l=$0} END{print l}')"
  [ "$last" = "fi" ] || return 1
  printf '%s\n' "$tail_part"
}

m_launcher_apply() {
  local rc="$HOME/.bashrc" tpl="$CODEMUX_ROOT/templates/bashrc-block.sh"
  local bak tmp body new adopted=0 tdir

  if [ ! -f "$tpl" ]; then
    APPLY_NOTE="launcher template missing: $tpl"; return 1
  fi
  mkdir -p "$HOME" || return 1
  [ -f "$rc" ] || : >"$rc" || return 1

  bak="$(codemux_backup launcher "$rc")" || { APPLY_NOTE="failed to back up ~/.bashrc"; return 1; }
  tdir="${TMPDIR:-$PREFIX/tmp}"
  mkdir -p "$tdir" 2>/dev/null || tdir="$HOME/.cache/codemux"
  mkdir -p "$tdir" 2>/dev/null || { APPLY_NOTE="cannot write the temporary directory"; return 1; }
  tmp="$(mktemp "$tdir/codemux-bashrc.XXXXXX" 2>/dev/null)" || {
    APPLY_NOTE="mktemp failed in $tdir"; return 1
  }
  body="$tmp.body"
  new="$tmp.new"

  # 1) drop the old marked block (if any) → idempotent
  awk '/# codemux:launcher begin/{skip=1;next} /# codemux:launcher end/{skip=0;next} !skip' \
    "$rc" >"$body" || { rm -f "$tmp" "$body"; APPLY_NOTE="failed to read ~/.bashrc"; return 1; }

  # 2) adopt an old block without markers (only when its structure is recognised)
  if ! grep -q 'codemux:launcher begin' "$rc" 2>/dev/null; then
    if codemux_launcher_legacy_region "$body" >/dev/null 2>&1; then
      awk '/^# --- banner \+ menu launcher/{f=1} !f' "$body" >"$body.cut" &&
        mv -f "$body.cut" "$body" || { rm -f "$tmp" "$body"; APPLY_NOTE="failed to cut the old block"; return 1; }
      adopted=1
    fi
  fi

  # 3) assemble: old contents (without trailing blank lines) + template block
  {
    awk 'NF{l=NR} {line[NR]=$0} END{for (i=1; i<=(l?l:0); i++) print line[i]}' "$body"
    printf '\n'
    cat "$tpl"
  } >"$new" || { rm -f "$tmp" "$body" "$new"; APPLY_NOTE="failed to assemble the new ~/.bashrc"; return 1; }

  # 4) syntax check; on failure → restore the backup, never leave a broken bashrc
  if ! bash -n "$new" 2>/dev/null; then
    rm -f "$tmp" "$body" "$new"
    [ -n "$bak" ] && cp -a "$bak" "$rc" 2>/dev/null
    APPLY_NOTE="the new block fails bash -n — ~/.bashrc restored"; return 1
  fi

  codemux_atomic_write "$rc" <"$new" || {
    rm -f "$tmp" "$body" "$new"
    [ -n "$bak" ] && cp -a "$bak" "$rc" 2>/dev/null
    APPLY_NOTE="failed to write ~/.bashrc"; return 1
  }
  chmod 600 "$rc" 2>/dev/null || true
  rm -f "$tmp" "$body" "$new"

  if [ "$adopted" -eq 1 ]; then
    APPLY_NOTE="old block adopted (backup: ${bak:-none})"
  else
    APPLY_NOTE="banner+menu block installed"
  fi
  return 0
}
