# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: memory — ingatan lintas sesi V1 + V2 (lihat PRD §12A).
# Aturan: TIDAK PERNAH menimpa MEMORY.md/AGENTS.md yang sudah ada.

# Sumber mekanisme (kode, bukan data pribadi). Bisa ditimpa lewat env untuk tes.
CODEMUX_MEMORY_PLUGIN_URL="${CODEMUX_MEMORY_PLUGIN_URL:-https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/plugins/memory.js}"
CODEMUX_MEMORY_DIGEST_URL="${CODEMUX_MEMORY_DIGEST_URL:-https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/plugins/session-digest.py}"
CODEMUX_MEMORY_LIMIT="${CODEMUX_MEMORY_LIMIT:-24000}"

codemux_memory_base() { printf '%s/.config/opencode' "$HOME"; }

# Wrapper digest: cukup sekali di ~/.bashrc (blok bertanda codemux:memory).
codemux_memory_wrapper_present() {
  grep -q '_oc_refresh_digest()' "$HOME/.bashrc" 2>/dev/null
}

m_memory_probe() {
  local base need miss=() f size pct
  base="$(codemux_memory_base)"
  need=("MEMORY.md" "AGENTS.md" "RECENT.md" "plugins/memory.js" "bin/session-digest.py")

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
  if ! codemux_memory_wrapper_present; then
    PROBE=WARN; NOTE="wrapper digest di ~/.bashrc belum ada (ditambah saat install)"
    return
  fi

  size="$(wc -c <"$base/MEMORY.md" 2>/dev/null || echo 0)"
  size="${size// /}"
  pct=$((size * 100 / CODEMUX_MEMORY_LIMIT))
  if [ "$pct" -ge 100 ]; then
    PROBE=FAIL; NOTE="MEMORY.md ${size}B ≥ ${CODEMUX_MEMORY_LIMIT}B (memory_save akan gagal) — pangkas dulu"
  elif [ "$pct" -ge 90 ]; then
    PROBE=WARN; NOTE="MEMORY.md ${size}B (${pct}% dari ${CODEMUX_MEMORY_LIMIT}B) — hampir penuh"
  else
    PROBE=OK; NOTE="MEMORY.md ${size}B (${pct}%) · RECENT.md ada"
  fi
}

m_memory_verify() { m_memory_probe; }

# Tambahkan entri instructions tanpa merusak isi opencode.jsonc.
# Pakai python3 (ada setelah langkah toolset). Gagal → dilaporkan, file utuh.
codemux_memory_ensure_instructions() {
  local conf="$1" base="$2" out rc=0

  if ! have python3; then
    APPLY_NOTE="python3 tidak ada — tambahkan manual entri MEMORY.md & RECENT.md di instructions"
    return 1
  fi
  out="$(python3 "$CODEMUX_ROOT/templates/jsonc-instructions.py" "$conf" \
    "$base/MEMORY.md" "$base/RECENT.md" 2>&1)" || rc=$?
  case "$rc" in
    0) : ;;
    *) APPLY_NOTE="gagal menyunting opencode.jsonc: $out"; return 1 ;;
  esac
  # catatan hasil: NOTHING_TO_DO / ADDED:... / CREATED:...
  INSTRUCTIONS_RESULT="$out"
  return 0
}

# Wrapper digest di ~/.bashrc (dipakai bersama V1 & V2).
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

# codemux:memory begin  (dikelola codemux — segarkan ringkasan sesi sebelum opencode)
_oc_refresh_digest() {
  [ -x "$HOME/.config/opencode/bin/session-digest.py" ] || return 0
  python3 "$HOME/.config/opencode/bin/session-digest.py" >/dev/null 2>&1
}
opencode() { _oc_refresh_digest; command opencode "$@"; }
opencode-v2() { _oc_refresh_digest; command opencode-v2 "$@"; }
# codemux:memory end
EOS

  if ! bash -n "$rc" 2>/dev/null; then
    # kembalikan ke ukuran semula (kita hanya menambah di ekor)
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

  mkdir -p "$base/plugins" "$base/bin" || { APPLY_NOTE="tidak bisa membuat $base"; return 1; }

  # 1) data pribadi: hanya dibuat kalau belum ada — JANGAN pernah menimpa
  for f in MEMORY.md AGENTS.md; do
    if [ ! -f "$base/$f" ] && [ -f "$tpl/$f" ]; then
      cp "$tpl/$f" "$base/$f" && chmod 600 "$base/$f" 2>/dev/null && made+=("$f")
    fi
  done

  # 2) mekanisme (plugin + digest) — ambil dari repo hulu
  if [ ! -s "$base/plugins/memory.js" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_PLUGIN_URL" "$base/plugins/memory.js" || {
      APPLY_NOTE="gagal mengunduh plugins/memory.js"; return 1
    }
    chmod 600 "$base/plugins/memory.js" 2>/dev/null || true
    made+=("plugins/memory.js")
  fi
  if [ ! -s "$base/bin/session-digest.py" ]; then
    codemux_fetch_raw "$CODEMUX_MEMORY_DIGEST_URL" "$base/bin/session-digest.py" || {
      APPLY_NOTE="gagal mengunduh bin/session-digest.py"; return 1
    }
    chmod 700 "$base/bin/session-digest.py" 2>/dev/null || true
    made+=("bin/session-digest.py")
  fi

  # 3) RECENT.md: hasilkan sekarang kalau belum ada
  if [ ! -f "$base/RECENT.md" ]; then
    if have python3; then
      python3 "$base/bin/session-digest.py" >/dev/null 2>&1 || true
    fi
    if [ ! -f "$base/RECENT.md" ]; then
      printf '%s\n' '# RECENT' '' '> Ringkasan sesi dibuat otomatis; file ini ditimpa.' \
        | codemux_atomic_write "$base/RECENT.md" || {
        APPLY_NOTE="gagal membuat RECENT.md"; return 1
      }
    fi
    made+=("RECENT.md")
  fi

  # 4) opencode.jsonc: buat baru atau lengkapi entri instructions
  INSTRUCTIONS_RESULT=""
  if [ ! -f "$base/opencode.jsonc" ]; then
    if [ ! -f "$tpl/opencode.jsonc" ]; then
      APPLY_NOTE="template opencode.jsonc tidak ada"; return 1
    fi
    sed "s|@HOME@|$HOME|g" "$tpl/opencode.jsonc" |
      codemux_atomic_write "$base/opencode.jsonc" || {
      APPLY_NOTE="gagal membuat opencode.jsonc"; return 1
    }
    made+=("opencode.jsonc")
  else
    codemux_backup memory-config "$base/opencode.jsonc" >/dev/null || true
    codemux_memory_ensure_instructions "$base/opencode.jsonc" "$base" || return 1
  fi

  # 5) wrapper digest di ~/.bashrc
  codemux_memory_ensure_wrapper || {
    APPLY_NOTE="gagal menambah wrapper digest di ~/.bashrc"; return 1
  }

  if [ "${#made[@]}" -gt 0 ]; then
    APPLY_NOTE="dibuat: ${made[*]}"
  else
    APPLY_NOTE="${INSTRUCTIONS_RESULT:-sudah lengkap}"
  fi
  return 0
}
