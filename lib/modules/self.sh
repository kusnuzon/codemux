# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: self — the `codemux` command in $PREFIX/bin (launcher to the active root).

m_self_probe() {
  local bin="$PREFIX/bin/codemux"

  if [ ! -x "$bin" ]; then
    PROBE=MISS; NOTE="the 'codemux' command is not in $PREFIX/bin yet"
    return
  fi
  if grep -qF "$CODEMUX_ROOT/bin/codemux" "$bin" 2>/dev/null; then
    PROBE=OK; NOTE="codemux → $CODEMUX_ROOT"
  else
    PROBE=WARN; NOTE="the codemux launcher points to another root (it will be aligned)"
  fi
}

m_self_verify() { m_self_probe; }

m_self_apply() {
  local bin="$PREFIX/bin/codemux" bash_bin
  bash_bin="$(command -v bash)" || { APPLY_NOTE="bash not found"; return 1; }
  mkdir -p "$PREFIX/bin" || { APPLY_NOTE="cannot write $PREFIX/bin"; return 1; }

  {
    printf '#!%s\n' "$bash_bin"
    printf '# codemux launcher (generated automatically by codemux install)\n'
    printf 'exec %q %q "$@"\n' "$bash_bin" "$CODEMUX_ROOT/bin/codemux"
  } | codemux_atomic_write "$bin" || { APPLY_NOTE="failed to write $bin"; return 1; }
  chmod 755 "$bin" 2>/dev/null || true

  APPLY_NOTE="launcher created: $bin → $CODEMUX_ROOT"
  return 0
}
