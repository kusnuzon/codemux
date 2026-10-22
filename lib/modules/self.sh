# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: self — perintah `codemux` di $PREFIX/bin (launcher ke root aktif).

m_self_probe() {
  local bin="$PREFIX/bin/codemux"

  if [ ! -x "$bin" ]; then
    PROBE=MISS; NOTE="perintah 'codemux' belum ada di $PREFIX/bin"
    return
  fi
  if grep -qF "$CODEMUX_ROOT/bin/codemux" "$bin" 2>/dev/null; then
    PROBE=OK; NOTE="codemux → $CODEMUX_ROOT"
  else
    PROBE=WARN; NOTE="launcher codemux menunjuk root lain (akan diselaraskan)"
  fi
}

m_self_verify() { m_self_probe; }

m_self_apply() {
  local bin="$PREFIX/bin/codemux" bash_bin
  bash_bin="$(command -v bash)" || { APPLY_NOTE="bash tidak ditemukan"; return 1; }
  mkdir -p "$PREFIX/bin" || { APPLY_NOTE="tidak bisa menulis $PREFIX/bin"; return 1; }

  {
    printf '#!%s\n' "$bash_bin"
    printf '# launcher codemux (dibuat otomatis oleh codemux install)\n'
    printf 'exec %q %q "$@"\n' "$bash_bin" "$CODEMUX_ROOT/bin/codemux"
  } | codemux_atomic_write "$bin" || { APPLY_NOTE="gagal menulis $bin"; return 1; }
  chmod 755 "$bin" 2>/dev/null || true

  APPLY_NOTE="launcher dibuat: $bin → $CODEMUX_ROOT"
  return 0
}
