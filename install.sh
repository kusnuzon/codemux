#!/data/data/com.termux/files/usr/bin/bash
# install.sh — bootstrap codemux: ambil rilis (tarball + sha256) lalu jalankan install.
# Aman dipakai lewat `curl … | bash`: tidak ada pipe script kedua.
#   curl -fsSL -H 'Accept: application/vnd.github.raw' \
#     https://api.github.com/repos/kusnuzon/codemux/contents/install.sh | bash
set -Eeuo pipefail

REPO="${CODEMUX_REPO:-kusnuzon/codemux}"
BASE="${CODEMUX_GITHUB_BASE:-https://github.com}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/codemux/src"
ARGS=("$@")

say() { printf '  %s\n' "$*"; }
die() {
  printf '✖ %s\n' "$*" >&2
  exit 1
}

# 0) dijalankan dari checkout utuh (mis. `bash install.sh` di repo) → pakai itu.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
  if [ -f "$SELF_DIR/bin/codemux" ]; then
    say "menjalankan codemux dari $SELF_DIR"
    exec bash "$SELF_DIR/bin/codemux" install "${ARGS[@]}"
  fi
fi

# 1) prasyarat minimum
missing=()
for c in curl tar sha256sum gzip; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v pkg >/dev/null 2>&1; then
    say "memasang prasyarat: ${missing[*]}"
    pkg update -y >/dev/null 2>&1 || true
    pkg install -y curl tar coreutils gzip >/dev/null 2>&1 ||
      die "gagal memasang prasyarat (curl tar coreutils gzip)"
  else
    die "prasyarat kurang: ${missing[*]} (bukan Termux? pasang manual)"
  fi
fi

# 2) tarball: env (tes/offline) atau rilis terbaru, fallback main
tarball="${CODEMUX_BOOTSTRAP_TARBALL:-}"
expect_sha="${CODEMUX_BOOTSTRAP_SHA256:-}"
verified=1
if [ -z "$tarball" ]; then
  tag="$(curl -fsSIL -o /dev/null -w '%{url_effective}' --max-time 10 \
    "$BASE/$REPO/releases/latest" 2>/dev/null || true)"
  case "$tag" in
    */tag/*) tag="${tag##*/tag/}" ;;
    *) tag="" ;;
  esac
  if [ -n "$tag" ]; then
    url="$BASE/$REPO/releases/download/$tag/codemux.tar.gz"
    sha_url="$url.sha256"
    say "rilis terbaru: $tag"
  else
    url="https://codeload.github.com/$REPO/tar.gz/refs/heads/main"
    sha_url=""
    verified=0
    say "! belum ada rilis — memakai branch main (tanpa sha256)"
  fi
  mkdir -p "$CACHE" || die "tidak bisa menulis $CACHE"
  tarball="$CACHE/codemux-download.tar.gz"
  rm -f "$tarball.part"
  say "mengunduh $url"
  curl -fsSL --max-time 300 "$url" -o "$tarball.part" || {
    rm -f "$tarball.part"
    die "gagal mengunduh tarball"
  }
  mv -f "$tarball.part" "$tarball" || die "gagal menyimpan tarball"
  if [ -n "$sha_url" ]; then
    expect_sha="$(curl -fsSL --max-time 20 "$sha_url" 2>/dev/null | awk '{print $1}' || true)"
  fi
fi

[ -s "$tarball" ] || die "tarball kosong: $tarball"
if [ -n "$expect_sha" ]; then
  got="$(sha256sum "$tarball" | awk '{print $1}')"
  [ "$got" = "$expect_sha" ] || die "sha256 tidak cocok (file rusak/diubah)"
  say "sha256 cocok: $got"
elif [ "$verified" -eq 1 ]; then
  say "! sha256 tidak tersedia — lanjut (tarball dari env)"
fi

# 3) ekstrak ke current (atomik: new → tukar)
dest="$CACHE/current"
rm -rf "$dest.new"
mkdir -p "$dest.new" || die "tidak bisa membuat $dest.new"
tar -xzf "$tarball" -C "$dest.new" --strip-components=1 || die "gagal mengekstrak tarball"
[ -f "$dest.new/bin/codemux" ] || die "tarball tidak berisi bin/codemux"
bash -n "$dest.new/bin/codemux" 2>/dev/null || die "bin/codemux rusak"
new_ver="$(cat "$dest.new/VERSION" 2>/dev/null || echo '?')"

rm -rf "$dest.old"
if [ -d "$dest" ]; then mv "$dest" "$dest.old" || die "gagal menukar $dest"; fi
mv "$dest.new" "$dest" || die "gagal memasang $dest"
rm -rf "$dest.old"

say "codemux $new_ver siap di $dest"
exec bash "$dest/bin/codemux" install "${ARGS[@]}"
