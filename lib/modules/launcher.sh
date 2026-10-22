# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: launcher — banner + menu di ~/.bashrc (blok bertanda codemux).

m_launcher_probe() {
  local rc="$HOME/.bashrc"

  if [ ! -f "$rc" ]; then
    PROBE=MISS; NOTE='bashrc tidak ada (~/.bashrc)'; return
  fi
  if grep -q 'codemux:launcher begin' "$rc" 2>/dev/null &&
     grep -q 'codemux:launcher end' "$rc" 2>/dev/null; then
    if bash -n "$rc" 2>/dev/null; then
      PROBE=OK; NOTE="blok bertanda ada"
    else
      PROBE=FAIL; NOTE="$HOME/.bashrc gagal bash -n"
    fi
    return
  fi
  if grep -q '_oc_banner' "$rc" 2>/dev/null; then
    PROBE=WARN; NOTE="menu ada tapi tanpa penanda codemux (akan diadopsi)"
    return
  fi
  PROBE=MISS; NOTE="menu/banner belum dipasang"
}

m_launcher_verify() { m_launcher_probe; }

# Ambil hanya bagian akhir yang merupakan blok lama (tanpa penanda).
# Syarat adopsi: ada pemanggil _oc_launcher dan baris terakhir 'fi'
# (struktur auto-launch di akhir ~/.bashrc). Kalau ragu → tidak menyentuh.
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
    APPLY_NOTE="template launcher tidak ada: $tpl"; return 1
  fi
  mkdir -p "$HOME" || return 1
  [ -f "$rc" ] || : >"$rc" || return 1

  bak="$(codemux_backup launcher "$rc")" || { APPLY_NOTE="gagal backup ~/.bashrc"; return 1; }
  tdir="${TMPDIR:-$PREFIX/tmp}"
  mkdir -p "$tdir" 2>/dev/null || tdir="$HOME/.cache/codemux"
  mkdir -p "$tdir" 2>/dev/null || { APPLY_NOTE="tidak bisa menulis direktori sementara"; return 1; }
  tmp="$(mktemp "$tdir/codemux-bashrc.XXXXXX" 2>/dev/null)" || {
    APPLY_NOTE="mktemp gagal di $tdir"; return 1
  }
  body="$tmp.body"
  new="$tmp.new"

  # 1) buang blok bertanda lama (kalau ada) → idempoten
  awk '/# codemux:launcher begin/{skip=1;next} /# codemux:launcher end/{skip=0;next} !skip' \
    "$rc" >"$body" || { rm -f "$tmp" "$body"; APPLY_NOTE="gagal membaca ~/.bashrc"; return 1; }

  # 2) adopsi blok lama tanpa penanda (hanya kalau strukturnya dikenali)
  if ! grep -q 'codemux:launcher begin' "$rc" 2>/dev/null; then
    if codemux_launcher_legacy_region "$body" >/dev/null 2>&1; then
      awk '/^# --- banner \+ menu launcher/{f=1} !f' "$body" >"$body.cut" &&
        mv -f "$body.cut" "$body" || { rm -f "$tmp" "$body"; APPLY_NOTE="gagal memotong blok lama"; return 1; }
      adopted=1
    fi
  fi

  # 3) susun: isi lama (tanpa baris kosong ekor) + blok template
  {
    awk 'NF{l=NR} {line[NR]=$0} END{for (i=1; i<=(l?l:0); i++) print line[i]}' "$body"
    printf '\n'
    cat "$tpl"
  } >"$new" || { rm -f "$tmp" "$body" "$new"; APPLY_NOTE="gagal menyusun ~/.bashrc baru"; return 1; }

  # 4) validasi sintaks; gagal → pulihkan backup, jangan tinggalkan bashrc rusak
  if ! bash -n "$new" 2>/dev/null; then
    rm -f "$tmp" "$body" "$new"
    [ -n "$bak" ] && cp -a "$bak" "$rc" 2>/dev/null
    APPLY_NOTE="blok baru gagal bash -n — ~/.bashrc dipulihkan"; return 1
  fi

  codemux_atomic_write "$rc" <"$new" || {
    rm -f "$tmp" "$body" "$new"
    [ -n "$bak" ] && cp -a "$bak" "$rc" 2>/dev/null
    APPLY_NOTE="gagal menulis ~/.bashrc"; return 1
  }
  chmod 600 "$rc" 2>/dev/null || true
  rm -f "$tmp" "$body" "$new"

  if [ "$adopted" -eq 1 ]; then
    APPLY_NOTE="blok lama diadopsi (backup: ${bak:-none})"
  else
    APPLY_NOTE="blok banner+menu dipasang"
  fi
  return 0
}
