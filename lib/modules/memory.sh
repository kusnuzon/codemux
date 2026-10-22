# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: memory — ingatan lintas sesi V1 + V2 (lihat PRD §12A).

m_memory_probe() {
  local base="$HOME/.config/opencode"
  local need=("MEMORY.md" "AGENTS.md" "RECENT.md" "plugins/memory.js" "bin/session-digest.py")
  local miss=() f size pct

  for f in "${need[@]}"; do
    [ -f "$base/$f" ] || miss+=("$f")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    PROBE=MISS; NOTE="kurang: ${miss[*]}"
    return
  fi

  if ! grep -q 'MEMORY.md' "$base/opencode.jsonc" 2>/dev/null; then
    PROBE=WARN; NOTE="opencode.jsonc belum memuat MEMORY.md di instructions"
    return
  fi
  if ! grep -q 'RECENT.md' "$base/opencode.jsonc" 2>/dev/null; then
    PROBE=WARN; NOTE="opencode.jsonc belum memuat RECENT.md di instructions"
    return
  fi

  size="$(wc -c <"$base/MEMORY.md" 2>/dev/null || echo 0)"
  size="${size// /}"
  pct=$((size * 100 / 24000))
  if [ "$pct" -ge 100 ]; then
    PROBE=FAIL; NOTE="MEMORY.md ${size}B ≥ 24000B (memory_save akan gagal) — pangkas dulu"
  elif [ "$pct" -ge 90 ]; then
    PROBE=WARN; NOTE="MEMORY.md ${size}B (${pct}% dari 24000B) — hampir penuh"
  else
    PROBE=OK; NOTE="MEMORY.md ${size}B (${pct}%) · RECENT.md ada"
  fi
}
