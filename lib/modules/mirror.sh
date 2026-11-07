# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: mirror — the apt repo used by Termux.

CODEMUX_MIRROR_MAIN="${CODEMUX_MIRROR_MAIN:-https://mirror.jeonnam.school/termux/termux-main}"

m_mirror_host() {
  local main="$PREFIX/etc/apt/sources.list" extra="$PREFIX/etc/apt/sources.list.d"
  local host=""
  [ -r "$main" ] && host="$(awk '/^[[:space:]]*deb[[:space:]]/ {print $2; exit}' "$main" 2>/dev/null)"
  if [ -z "$host" ] && [ -d "$extra" ]; then
    host="$(awk '/^[[:space:]]*deb[[:space:]]/ {print $2; exit}' "$extra"/*.list 2>/dev/null)"
  fi
  printf '%s' "$host"
}

m_mirror_probe() {
  local host slow=""
  host="$(m_mirror_host)"
  if [ -z "$host" ]; then
    PROBE=MISS; NOTE="no active apt repo in $PREFIX/etc/apt/sources.list"
    return
  fi
  grep -qs 'leitecastro' "$PREFIX/etc/apt/sources.list" "$PREFIX/etc/apt/sources.list.d" 2>/dev/null && slow="slow"
  if [ -n "$slow" ]; then
    PROBE=WARN; NOTE="$host (slow mirror — replacing it is recommended)"
  else
    PROBE=OK; NOTE="$host"
  fi
}

m_mirror_verify() {
  local host
  host="$(m_mirror_host)"
  if [ -z "$host" ]; then
    PROBE=FAIL; NOTE="sources.list is not valid after writing"
  elif printf '%s' "$host" | grep -q 'leitecastro'; then
    PROBE=WARN; NOTE="$host is still slow"
  else
    PROBE=OK; NOTE="$host"
  fi
}

m_mirror_apply() {
  local f="$PREFIX/etc/apt/sources.list" host bak
  host="$(m_mirror_host)"

  if [ -z "$host" ]; then
    bak="$(codemux_backup mirror "$f")" || { APPLY_NOTE="failed to back up sources.list"; return 1; }
    printf 'deb %s stable main\n' "$CODEMUX_MIRROR_MAIN" | codemux_atomic_write "$f" || {
      APPLY_NOTE="failed to write sources.list"; return 1; }
    APPLY_NOTE="new sources.list: $CODEMUX_MIRROR_MAIN (backup: $bak)"
  else
    # replace only the host, leave the other lines as they are
    bak="$(codemux_backup mirror "$f")" || { APPLY_NOTE="failed to back up sources.list"; return 1; }
    sed -i "s|^[[:space:]]*deb[[:space:]][^[:space:]]*/termux-main|deb $CODEMUX_MIRROR_MAIN|" "$f" || {
      APPLY_NOTE="failed to edit sources.list"; return 1; }
    APPLY_NOTE="host replaced with $CODEMUX_MIRROR_MAIN (backup: $bak)"
  fi

  # real test: apt-get update must pass
  codemux_spawn mirror env DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
    APPLY_NOTE="failed to run apt-get update"; return 1; }
  local rc=0
  codemux_wait mirror 900 || rc=$?
  if [ "$rc" -ne 0 ]; then
    # restore the backup so the repo is not left broken
    [ -n "$bak" ] && [ -f "$bak" ] && cp -a "$bak" "$f" 2>/dev/null
    APPLY_NOTE="apt-get update failed (rc $rc) — sources.list restored: $(codemux_step_tail mirror)"
    return 1
  fi
  APPLY_NOTE="$APPLY_NOTE · apt-get update passed"
  return 0
}
