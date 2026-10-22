# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: v2 — OpenCode V2 (payload + shim compat glibc).

m_v2_probe() {
  local dir="$PREFIX/share/opencode-v2"
  local ver compat=""

  if [ ! -x "$dir/opencode.real" ]; then
    PROBE=MISS; NOTE="payload belum ada ($dir/opencode.real)"; return
  fi

  ver="$(cat "$dir/VERSION" 2>/dev/null || echo '?')"
  [ -e "$dir/lib/compat/libc.so" ] && compat="shim ok" || compat="shim HILANG"

  if [ "$compat" = "shim ok" ]; then
    PROBE=OK; NOTE="v$ver · $compat"
  else
    PROBE=WARN; NOTE="v$ver · $compat (jalankan: codemux repair)"
  fi
}
