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
    pkg install -y curl tar coreutils gzip wget >/dev/null 2>&1 ||
      die "gagal memasang prasyarat (curl tar coreutils gzip wget)"
  else
    die "prasyarat kurang: ${missing[*]} (bukan Termux? pasang manual)"
  fi
fi

# 1b) curl ada tapi bisa rusak oleh paket glibc:
#     "cannot locate symbol SSL_set_quic_tls_early_data_enabled".
#     Tanpa ini, unduhan tarball gagal dengan pesan yang menyesatkan.
if ! curl -fsS --max-time 10 -o /dev/null "https://github.com" >/dev/null 2>&1; then
  say "curl tidak sehat — memasang ulang curl/libcurl/openssl"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold curl libcurl openssl ca-certificates >/dev/null 2>&1 || \
    pkg install -y curl libcurl openssl ca-certificates >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
fi

# unduh: curl, lalu wget, lalu python (kalau curl tetap rusak)
download() { # <url> <dest>
  if curl -fsSL --max-time 300 "$1" -o "$2.part" 2>/dev/null && [ -s "$2.part" ]; then
    mv -f "$2.part" "$2"; return 0
  fi
  rm -f "$2.part"
  if command -v wget >/dev/null 2>&1 && wget -q --timeout=60 -O "$2.part" "$1" >/dev/null 2>&1 && [ -s "$2.part" ]; then
    mv -f "$2.part" "$2"; return 0
  fi
  rm -f "$2.part"
  return 1
}

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
  download "$url" "$tarball" || die "gagal mengunduh tarball"
  if [ -n "$sha_url" ]; then
    download "$sha_url" "$CACHE/codemux-download.sha256" 2>/dev/null || true
    expect_sha="$(awk '{print $1}' "$CACHE/codemux-download.sha256" 2>/dev/null || true)"
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
