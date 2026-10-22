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
  printf '  %s %s%s%s%s %s%s%s%s  %s%s%s\n' \
    "$arrow" "$pad" "$BOLD" "$key" "$R" \
    "$pad" "$BOLD" "$namepad" "$R" \
    "$pad" "$DIM" "$desc$R"
}

_oc_menu() {
  local sel="$1"
  printf '  %s───────────────────────────────────────────────%s\n' "$DIM" "$R"
  _oc_row 0 "$sel" 1 "OpenCode V1" "stabil · DB lama"
  _oc_row 1 "$sel" 2 "OpenCode V2" "baru · DB terpisah"
  _oc_row 2 "$sel" 3 "Shell saja" "tanpa opencode"
  _oc_row 3 "$sel" q "Keluar" "tutup Termux"
  printf '  %s───────────────────────────────────────────────%s\n' "$DIM" "$R"
  printf '  %s↑/↓ pilih%s   %sEnter jalankan%s   %s1/2/3/q%s   %sCtrl+C batal%s\n\n' \
    "$DIM" "$R" "$DIM" "$R" "$DIM" "$R" "$DIM" "$R"
}

_oc_read_key() {
  KEY=""
  IFS= read -rsn1 KEY || KEY=""
  case "$KEY" in
    $'\033')
      local rest=""
      IFS= read -rsn2 -t 0.05 rest || rest=""
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

# Mengembalikan 0 = lanjut ke shell, 1 = keluar dari Termux.
_oc_menu_loop() {
  local sel=0 full=1 choice_file="$HOME/.local/state/opencode-choice"
  case "$(cat "$choice_file" 2>/dev/null)" in
    2) sel=1 ;;
    3) sel=2 ;;
    *) sel=0 ;;
  esac

  while :; do
    if [ "$full" = "1" ]; then
      printf '\033[2J\033[H'
      _oc_banner
      full=0
    else
      # menu = 9 baris; kembali ke awal blok menu lalu gambar ulang
      printf '\033[8A'
    fi
    _oc_menu "$sel"
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
      esc|ctrl-c) ;;
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
    printf '  %sKembali ke shell.%s\n\n' "$DIM" "$R"
    _oc_guide
  else
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
