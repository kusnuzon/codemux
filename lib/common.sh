# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# lib/common.sh — helper dasar codemux (warna, log, deteksi, util).
# Tidak melakukan aksi apa pun saat di-source.

CODEMUX_NAME="codemux"
CODEMUX_ROOT="${CODEMUX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODEMUX_VERSION="$(cat "$CODEMUX_ROOT/VERSION" 2>/dev/null || echo "0.0.0")"
CODEMUX_HOME="${CODEMUX_HOME:-$HOME/.config/codemux}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# versions.env (opsional; jangan gagal kalau tidak ada)
# Nilai dari environment menang atas file (dipakai tests/ dan CI).
_CODEMUX_ENV_APT="${CODEMUX_APT_PACKAGES-__unset__}"
_CODEMUX_ENV_MIRROR="${CODEMUX_MIRROR_MAIN-__unset__}"
if [ -f "$CODEMUX_ROOT/versions.env" ]; then
  # shellcheck source=/dev/null
  . "$CODEMUX_ROOT/versions.env"
fi
[ "$_CODEMUX_ENV_APT" = "__unset__" ] || CODEMUX_APT_PACKAGES="$_CODEMUX_ENV_APT"
[ "$_CODEMUX_ENV_MIRROR" = "__unset__" ] || CODEMUX_MIRROR_MAIN="$_CODEMUX_ENV_MIRROR"
unset _CODEMUX_ENV_APT _CODEMUX_ENV_MIRROR
OPENCODE_V1_VERSION="${OPENCODE_V1_VERSION:-?}"
OPENCODE_V2_VERSION="${OPENCODE_V2_VERSION:-?}"
CODEMUX_APT_PACKAGES="${CODEMUX_APT_PACKAGES:-}"

# --- warna -------------------------------------------------------------------
codemux_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
    C_OK=$'\033[38;5;42m'; C_WARN=$'\033[38;5;214m'
    C_MISS=$'\033[38;5;203m'; C_INFO=$'\033[38;5;45m'
  else
    C_R=''; C_DIM=''; C_B=''; C_OK=''; C_WARN=''; C_MISS=''; C_INFO=''
  fi
}

# --- log ---------------------------------------------------------------------
log_ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_R" "$*"; }
log_warn() { printf '%s!%s %s\n' "$C_WARN" "$C_R" "$*"; }
log_fail() { printf '%s✖%s %s\n' "$C_MISS" "$C_R" "$*" >&2; }
log_info() { printf '%s→%s %s\n' "$C_INFO" "$C_R" "$*"; }
log_dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_R"; }

codemux_die() {
  log_fail "$*"
  exit 2
}

# --- util --------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

human_bytes() {
  local b="${1:-0}"
  if [ "$b" -ge 1073741824 ]; then
    awk -v b="$b" 'BEGIN{printf "%.1f GB", b/1073741824}'
  elif [ "$b" -ge 1048576 ]; then
    awk -v b="$b" 'BEGIN{printf "%.0f MB", b/1048576}'
  elif [ "$b" -ge 1024 ]; then
    awk -v b="$b" 'BEGIN{printf "%.0f KB", b/1024}'
  else
    printf '%s B' "$b"
  fi
}

# Path aman: hanya boleh di dalam $HOME atau $CODEMUX_HOME.
codemux_safe_path() {
  case "$1" in
    "$HOME"/*|"$CODEMUX_HOME"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# json_escape: escape minimal untuk output --json.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}

codemux_usage() {
  cat <<'EOF'
codemux — pemasang & pemelihara Termux (OpenCode V1 + V2 + ingatan + update)

penggunaan:
  codemux [perintah] [opsi]

perintah:
  check              status tiap modul (tidak mengubah apa pun)
  install            pasang yang belum ada; aman diulang & lanjut setelah terputus
  status             progres install terakhir, lock, 10 baris log terakhir
  repair             bereskan sisa proses yang mati di tengah
  version            versi codemux + komponen terpasang
  help               bantuan ini
  update-check       cek rilis baru di hulu       (M5, belum tersedia)
  upgrade            perbarui semua komponen      (M5, belum tersedia)
  doctor             diagnosa lengkap             (M5, belum tersedia)
  memory             status ingatan lintas sesi (read-only)
  uninstall          lepas komponen               (M5, belum tersedia)

opsi check:
  --json             keluaran mesin

opsi install:
  --dry-run          tampilkan rencana, tidak mengubah apa pun
  --fresh            mulai dari langkah 1 (bukan melanjutkan)
  --skip a,b         lewati modul (deps,mirror,storage,toolset,glibc,v1,v2,launcher,dotfiles,memory)
  -y, --yes          tanpa konfirmasi (default: tanpa tanya)

opsi repair:
  --dry-run          tampilkan perbaikan yang akan dilakukan
EOF
}

# Versi V1 yang SEBENARNYA (payload), bukan versi paket dpkg.
# dpkg bisa tertinggal: paket 1.19.0 tapi payload sudah 1.19.3.
opencode_v1_version() {
  local v="" dpkg_v=""
  if have opencode; then
    v="$(timeout 15 opencode --version 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  fi
  dpkg_v="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
  case "$v" in
    [0-9]*) printf '%s' "$v" ;;
    *) printf '%s' "${dpkg_v:-?}" ;;
  esac
}

opencode_v2_version() {
  cat "$PREFIX/share/opencode-v2/VERSION" 2>/dev/null || printf '?'
}

codemux_versions() {
  printf '%-16s %s\n' "codemux" "$CODEMUX_VERSION"
  printf '%-16s %s\n' "opencode-v1" "$(opencode_v1_version)"
  printf '%-16s %s\n' "opencode-v2" "$(opencode_v2_version)"
}

codemux_not_ready() {
  log_warn "perintah '$1' belum tersedia di versi $CODEMUX_VERSION (milestone berikutnya)."
  log_dim "Saat ini yang jalan: check, version, help."
  exit 1
}
