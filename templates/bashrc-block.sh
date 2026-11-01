# codemux:launcher begin  (dikelola codemux — jangan edit manual)
# Blok banner + menu startup Termux. Ubah lewat template repo codemux,
# lalu jalankan `codemux install`. Lewati menu: OPENCODE_NO_AUTO=1 bash
# Menu pakai tombol panah (↑/↓) + Enter, atau angka 1/2/3 dan q.
# Lewati semuanya: OPENCODE_NO_AUTO=1 bash
_oc_ver() {
  local v=""
  case "$1" in
    v1)
      # versi asli payload; dpkg-query bisa tertinggal dari payload
      if command -v opencode >/dev/null 2>&1; then
        v="$(timeout 8 opencode --version 2>/dev/null | head -n 1 | tr -d '[:space:]')"
      fi
      [ -n "$v" ] || v="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null)"
      ;;
    v2) v="$(cat "$PREFIX/share/opencode-v2/VERSION" 2>/dev/null)" ;;
  esac
  printf '%s' "${v:-?}"
}

_oc_colors() {
  C1=''; C2=''; ACC=''; DIM=''; BOLD=''; HL=''; R=''
  if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    C1=$'\033[38;5;243m'   # OPEN — abu-abu tua
    C2=$'\033[38;5;231m'   # CODE — putih
    ACC=$'\033[38;5;213m'; DIM=$'\033[2m'
    BOLD=$'\033[1m'; HL=$'\033[48;5;236m'; R=$'\033[0m'
  fi
}

_oc_banner() {
  printf '\n'
  # tiap baris: 4 glyph pertama (OPEN) abu-abu, 4 glyph sisanya (CODE) putih
  local a
  for a in "█▀▀█ █▀▀█ █▀▀▀ █▀▀▄ █▀▀▀ █▀▀█ █▀▀▄ █▀▀▀" \
           "█  █ █▀▀▀ █▀▀  █  █ █    █  █ █  █ █▀▀ " \
           "▀▀▀▀ ▀    ▀▀▀▀ ▀  ▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀"; do
    printf '   %s%s%s%s%s%s\n' "$C1" "${a:0:19}" "$R" "$C2" "${a:19}" "$R"
  done
  printf '   %sTermux · Android arm64%s   %sv1 %s%s  %s·%s  %sv2 %s%s\n\n' \
    "$DIM" "$R" "$DIM" "$(_oc_ver v1)" "$R" "$DIM" "$R" "$DIM" "$(_oc_ver v2)" "$R"
}

# Satu baris menu: <indeks> <terpilih?>
_oc_row() {
  local idx="$1" sel="$2" key="$3" name="$4" desc="$5" arrow pad namepad
  if [ "$idx" = "$sel" ]; then
    arrow="$ACC❯$R"; pad="$HL"
  else
    arrow=" "; pad=""
  fi
  printf -v namepad '%-13s' "$name"
  printf '  %s %s%s%s%s %s%s%s%s  %s%s%s\033[K\n' \
    "$arrow" "$pad" "$BOLD" "$key" "$R" \
    "$pad" "$BOLD" "$namepad" "$R" \
    "$pad" "$DIM" "$desc$R"
}

# Hanya 4 baris pilihan (tanpa garis & petunjuk) — dipakai untuk gambar ulang
# saat tombol panah ditekan, supaya layar tidak berkedip.
_oc_rows() {
  local sel="$1"
  _oc_row 0 "$sel" 1 "OpenCode V1" "stabil · DB lama"
  _oc_row 1 "$sel" 2 "OpenCode V2" "baru · DB terpisah"
  _oc_row 2 "$sel" 3 "Shell saja" "tanpa opencode"
  _oc_row 3 "$sel" q "Keluar" "tutup Termux"
}

_oc_menu() {
  printf '  %s───────────────────────────────────────────────%s\n' "$DIM" "$R"
  _oc_rows "$1"
  printf '  %s───────────────────────────────────────────────%s\n' "$DIM" "$R"
  printf '  %s↑/↓ pilih%s   %sEnter jalankan%s   %s1/2/3/q%s   %sCtrl+C batal%s\n\n' \
    "$DIM" "$R" "$DIM" "$R" "$DIM" "$R" "$DIM" "$R"
}

_oc_read_key() {
  KEY=""
  _oc_int=0
  # Tunggu tombol maksimal 0,2 dtk per putaran: dengan begitu sinyal Ctrl+C
  # sempat ditangani sebelum tombol berikutnya, jadi tidak ada tombol yang
  # "termakan" (dan kursor tidak tertinggal tersembunyi).
  while :; do
    IFS= read -rsn1 -t 0.2 KEY && break
    if [ "${_oc_int:-0}" = "1" ]; then KEY="cancel"; return 0; fi
  done
  case "$KEY" in
    $'\033')
      local rest="" ch=""
      # Baca sisa escape sequence byte per byte: kalau byte-nya datang
      # terpisah (mis. setelah Ctrl+C), jangan sampai tombol panah hilang.
      while [ "${#rest}" -lt 2 ]; do
        IFS= read -rsn1 -t 0.25 ch || break
        rest+="$ch"
      done
      case "$rest" in
        '[A') KEY="up" ;;
        '[B') KEY="down" ;;
        '[C') KEY="right" ;;
        '[D') KEY="left" ;;
        *) KEY="esc" ;;
      esac
      ;;
    ''|$'\r'|$'\n') KEY="enter" ;;
    k|K) KEY="up" ;;
    j|J) KEY="down" ;;
  esac
}

# Versi yang benar-benar terpasang sekarang (kosong kalau tak terdeteksi).
# Dipakai untuk menyaring baris cache yang sudah basi.
_oc_live_ver() {
  local pre="${PREFIX:-/data/data/com.termux/files/usr}"
  case "$1" in
    opencode-v1) cat "$pre/share/opencode/VERSION" 2>/dev/null ;;
    opencode-v2) cat "$pre/share/opencode-v2/VERSION" 2>/dev/null ;;
    *) : ;;
  esac
}

# Baris notifikasi update (baca cache codemux; tidak menahan prompt).
_oc_update_notice() {
  local dir="$HOME/.config/codemux"
  local cache="$dir/update-cache.tsv" stamp="$dir/.update-check.stamp"
  local age=-1 s_age=999999 n=0 v1 v2 rows stale=0 unknown=0 wait_h=6
  v1="$(_oc_live_ver opencode-v1)"
  v2="$(_oc_live_ver opencode-v2)"
  if [ -f "$cache" ]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ) / 3600 ))
    # Baris dianggap basi kalau versi "lokal" di cache ≠ versi terpasang
    # (mis. payload baru diganti di luar menu). Yang basi disembunyikan,
    # lalu cache dipaksa dicek ulang.
    # "na" = cek hulu gagal (jaringan putus/timeout). Jangan dipercaya 24 jam:
    # coba lagi paling cepat 1 jam sekali.
    { read -r n; read -r rows; read -r stale; read -r unknown; } < <(awk -F'\t' -v v1="$v1" -v v2="$v2" '
      $4=="update" {
        if (($1=="opencode-v1" && v1!="" && $2!=v1) ||
            ($1=="opencode-v2" && v2!="" && $2!=v2)) { stale=1; next }
        out = out sep (($1=="apt") ? $2 " paket apt" : $1 " " $3); sep = " · "
        n++
      }
      $4=="na" { unknown++ }
      END { print n+0; print out; print (stale?1:0); print unknown+0 }' "$cache" 2>/dev/null)
    n="${n// /}"
    if [ "${n:-0}" -gt 0 ] && [ -n "$rows" ]; then
      printf '   %supdate tersedia:%s %s\n' "$ACC" "$R" "$rows"
      printf '   %sjalankan: codemux upgrade%s\n\n' "$DIM" "$R"
    fi
    [ "${stale:-0}" = "1" ] && age=999999 # cache tak cocok → cek ulang
    if [ "${unknown:-0}" -gt 0 ]; then
      age=999999 # hasil cek tak lengkap → coba lagi lebih cepat
      wait_h=1
    fi
  fi
  # cek di latar belakang kalau cache basi; maksimal sekali per 6 jam
  command -v codemux >/dev/null 2>&1 || return 0
  if [ -f "$stamp" ]; then
    s_age=$(( ( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ) / 3600 ))
  fi
  if { [ ! -f "$cache" ] || [ "$age" -ge 24 ]; } && [ "$s_age" -ge "$wait_h" ]; then
    mkdir -p "$dir" 2>/dev/null
    : >"$stamp" 2>/dev/null
    ( codemux update-check --quiet >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
}

_oc_cursor_hide() { printf '\033[?25l'; }
_oc_cursor_show() { printf '\033[?25h'; }

# Mengembalikan 0 = lanjut ke shell, 1 = keluar dari Termux.
_oc_menu_loop() {
  local sel=0 full=1 choice_file="$HOME/.local/state/opencode-choice"
  case "$(cat "$choice_file" 2>/dev/null)" in
    2) sel=1 ;;
    3) sel=2 ;;
    *) sel=0 ;;
  esac

  # Kursor disembunyikan selama menu: kalau tampil, dia berkedip di baris
  # bawah menu dan terlihat seperti glitch saat naik/turun. Ctrl+C hanya
  # membatalkan tombol (tidak mematikan menu), jadi kursor tidak tertinggal
  # dalam keadaan tersembunyi.
  trap '_oc_int=1' INT
  _oc_cursor_hide
  while :; do
    if [ "$full" = "1" ]; then
      printf '\033[2J\033[H'
      _oc_banner
      _oc_update_notice
      _oc_menu "$sel"
      full=0
    else
      # gambar ulang 4 baris pilihan saja (garis & petunjuk dibiarkan):
      # dari baris kosong di bawah menu naik 7 baris ke pilihan pertama,
      # tulis 4 baris, lalu turun 3 baris (garis + petunjuk + baris kosong).
      printf '\033[7A'
      _oc_rows "$sel"
      printf '\033[3B'
    fi
    _oc_read_key

    case "$KEY" in
      up|left)   sel=$(( (sel + 3) % 4 )) ;;
      down|right) sel=$(( (sel + 1) % 4 )) ;;
      enter)
        case "$sel" in
          0|1)
            mkdir -p "$HOME/.local/state" 2>/dev/null
            printf '%s\n' "$((sel + 1))" >"$choice_file" 2>/dev/null
            printf '\n'
            # opencode butuh kursor terlihat; sembunyikan lagi saat balik ke menu
            _oc_cursor_show
            if [ "$sel" -eq 0 ]; then
              printf '  %s→ OpenCode V1%s\n\n' "$DIM" "$R"
              if command -v opencode >/dev/null 2>&1; then
                opencode
              else
                printf '  opencode V1 tidak ditemukan.\n'
              fi
            else
              printf '  %s→ OpenCode V2%s\n\n' "$DIM" "$R"
              if command -v opencode-v2 >/dev/null 2>&1; then
                opencode-v2
              else
                printf '  opencode-v2 tidak ditemukan.\n'
              fi
            fi
            # setelah opencode ditutup (mis. ketik exit), balik ke menu
            _oc_cursor_hide
            full=1
            ;;
          2) printf '\n'; return 0 ;;
          3) printf '\n'; return 1 ;;
        esac
        ;;
      1) sel=0 ;;
      2) sel=1 ;;
      3) sel=2 ;;
      q|Q) sel=3; return 1 ;;
      esc|cancel|ctrl-c) ;;
    esac
  done
}

# Satu baris panduan perintah.
_oc_cmd_row() {
  printf '    %s%-13s%s%s\n' "$ACC" "$1" "$R" "$2"
}

# Panduan singkat setelah memilih "Shell saja".
_oc_guide() {
  printf '  %sShell saja dipilih — opencode tidak dijalankan.%s\n\n' "$DIM" "$R"
  printf '  %sPerintah yang bisa dipakai:%s\n' "$BOLD" "$R"
  _oc_cmd_row menu          'kembali ke menu pilihan (V1 / V2 / shell / keluar)'
  _oc_cmd_row opencode      'jalankan OpenCode V1 langsung'
  _oc_cmd_row opencode-v2   'jalankan OpenCode V2 langsung'
  _oc_cmd_row doctor        'cek kesehatan instalasi OpenCode V2'
  _oc_cmd_row version       'tampilkan versi V1 dan V2'
  _oc_cmd_row codemux       'cek & rawat Termux (check / install / status)'
  _oc_cmd_row 'keluar|exit' 'tutup Termux'
  printf '\n  %sKetik %smenu%s kapan pun untuk balik ke menu ini.%s\n' "$DIM" "$BOLD" "$R" "$R"
  printf '  %sDi dalam opencode, ketik exit atau Ctrl+C → kembali ke menu.%s\n\n' "$DIM" "$R"
}

# Jalankan launcher; dipakai saat startup dan oleh perintah `menu`.
_oc_launcher() {
  _oc_colors
  if _oc_menu_loop; then
    trap - INT
    _oc_cursor_show
    printf '  %sKembali ke shell.%s\n\n' "$DIM" "$R"
    _oc_guide
  else
    trap - INT
    _oc_cursor_show
    printf '  %sSampai jumpa.%s\n\n' "$DIM" "$R"
    exit 0
  fi
  unset C1 C2 ACC DIM BOLD HL R KEY
}

menu() { _oc_launcher; }
version() {
  printf 'OpenCode V1 : %s\n' "$(_oc_ver v1)"
  printf 'OpenCode V2 : %s\n' "$(_oc_ver v2)"
}
doctor() {
  if [ -f "$PREFIX/share/opencode-v2/doctor.sh" ]; then
    bash "$PREFIX/share/opencode-v2/doctor.sh" "$@"
  else
    printf 'doctor.sh tidak ditemukan (OpenCode V2 belum terpasang).\n'
  fi
}
keluar() { exit 0; }

if [ -z "$OPENCODE_NO_AUTO" ] && [ -t 0 ] && [ -t 1 ] && [ -z "$OPENCODE_AUTO_LAUNCHED" ]; then
  export OPENCODE_AUTO_LAUNCHED=1
  _oc_launcher
fi
# codemux:launcher end
