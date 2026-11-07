#!/data/data/com.termux/files/usr/bin/bash
# install.sh — codemux bootstrap: fetch the release (tarball + sha256) then run install.
# Safe to use via `curl … | bash`: there is no second piped script.
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

# 0) run from a complete checkout (e.g. `bash install.sh` in the repo) → use that.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
  if [ -f "$SELF_DIR/bin/codemux" ]; then
    say "running codemux from $SELF_DIR"
    exec bash "$SELF_DIR/bin/codemux" install "${ARGS[@]}"
  fi
fi

# 1) minimum prerequisites
missing=()
for c in curl tar sha256sum gzip; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v pkg >/dev/null 2>&1; then
    say "installing prerequisites: ${missing[*]}"
    pkg update -y >/dev/null 2>&1 || true
    pkg install -y curl tar coreutils gzip wget >/dev/null 2>&1 ||
      die "failed to install prerequisites (curl tar coreutils gzip wget)"
  else
    die "missing prerequisites: ${missing[*]} (not Termux? install manually)"
  fi
fi

# 1b) curl exists but the glibc package can break it:
#     "cannot locate symbol SSL_set_quic_tls_early_data_enabled".
#     Without this, the tarball download fails with a misleading message.
if ! curl -fsS --max-time 10 -o /dev/null "https://github.com" >/dev/null 2>&1; then
  say "curl is unhealthy — reinstalling curl/libcurl/openssl"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold curl libcurl openssl ca-certificates >/dev/null 2>&1 || \
    pkg install -y curl libcurl openssl ca-certificates >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
fi

# download: curl, then wget, then python (if curl is still broken)
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

# 2) tarball: env (tests/offline) or latest release, fallback to main
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
    say "latest release: $tag"
  else
    url="https://codeload.github.com/$REPO/tar.gz/refs/heads/main"
    sha_url=""
    verified=0
    say "! no release yet — using branch main (no sha256)"
  fi
  mkdir -p "$CACHE" || die "cannot write $CACHE"
  tarball="$CACHE/codemux-download.tar.gz"
  rm -f "$tarball.part"
  say "downloading $url"
  download "$url" "$tarball" || die "failed to download tarball"
  if [ -n "$sha_url" ]; then
    download "$sha_url" "$CACHE/codemux-download.sha256" 2>/dev/null || true
    expect_sha="$(awk '{print $1}' "$CACHE/codemux-download.sha256" 2>/dev/null || true)"
  fi
fi

[ -s "$tarball" ] || die "empty tarball: $tarball"
if [ -n "$expect_sha" ]; then
  got="$(sha256sum "$tarball" | awk '{print $1}')"
  [ "$got" = "$expect_sha" ] || die "sha256 does not match (file corrupt/modified)"
  say "sha256 matches: $got"
elif [ "$verified" -eq 1 ]; then
  say "! sha256 not available — continuing (tarball from env)"
fi

# 3) extract to current (atomic: new → swap)
dest="$CACHE/current"
rm -rf "$dest.new"
mkdir -p "$dest.new" || die "cannot create $dest.new"
tar -xzf "$tarball" -C "$dest.new" --strip-components=1 || die "failed to extract tarball"
[ -f "$dest.new/bin/codemux" ] || die "tarball does not contain bin/codemux"
bash -n "$dest.new/bin/codemux" 2>/dev/null || die "bin/codemux is broken"
new_ver="$(cat "$dest.new/VERSION" 2>/dev/null || echo '?')"

rm -rf "$dest.old"
if [ -d "$dest" ]; then mv "$dest" "$dest.old" || die "failed to swap $dest"; fi
mv "$dest.new" "$dest" || die "failed to install $dest"
rm -rf "$dest.old"

say "codemux $new_ver ready at $dest"
exec bash "$dest/bin/codemux" install "${ARGS[@]}"
