#!/data/data/com.termux/files/usr/bin/bash
# tests/release.sh — uji bootstrap install.sh + codemux self-update (M6).
# Tarball dibuat dari checkout ini (git archive); tidak menyentuh sistem.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX="$BASE/codemux-rel-$$"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/home" "$SANDBOX/prefix" "$SANDBOX/state"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- tarball rilis dari checkout ini -----------------------------------------
TARBALL="$SANDBOX/codemux.tar.gz"
if git archive --format=tar.gz --prefix=codemux/ -o "$TARBALL" HEAD 2>"$SANDBOX/tar.err"; then
  ok "tarball dibuat dari HEAD"
else
  bad "git archive gagal ($(cat "$SANDBOX/tar.err" | head -2))"
  printf '\n%s lulus · %s gagal\n' "$pass" "$fail"
  exit 1
fi
SHA="$(sha256sum "$TARBALL" | awk '{print $1}')"

run_bootstrap() { # <opsi...>
  env HOME="$SANDBOX/home" XDG_CACHE_HOME="$SANDBOX/home/.cache" PREFIX="$SANDBOX/prefix" CODEMUX_HOME="$SANDBOX/state" \
    TMPDIR="$BASE" CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
    CODEMUX_BOOTSTRAP_TARBALL="$TARBALL" CODEMUX_BOOTSTRAP_SHA256="$SHA" \
    bash -s -- "$@" <"$ROOT/install.sh"
}

# =============================================================================
# 1. bootstrap: ekstrak + lanjut ke install
# =============================================================================
out="$(run_bootstrap --dry-run 2>&1)"
if printf '%s' "$out" | grep -q 'sha256 cocok' &&
  printf '%s' "$out" | grep -q 'dry-run' &&
  printf '%s' "$out" | grep -q 'install (dry-run)'; then
  ok "bootstrap: sha256 diverifikasi + install dilanjutkan"
else
  bad "bootstrap: alur tidak sesuai"
  printf '%s\n' "$out" | tail -6 | sed 's/^/     /'
fi
cache="$SANDBOX/home/.cache/codemux/src/current"
if [ -f "$cache/bin/codemux" ] && [ -f "$cache/VERSION" ] && bash -n "$cache/bin/codemux" 2>/dev/null; then
  ok "bootstrap: kode diekstrak ke cache/current"
else
  bad "bootstrap: cache/current tidak valid"
fi

# sha mismatch harus ditolak
if env HOME="$SANDBOX/home2" XDG_CACHE_HOME="$SANDBOX/home2/.cache" PREFIX="$SANDBOX/prefix" CODEMUX_HOME="$SANDBOX/state2" \
  TMPDIR="$BASE" CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
  CODEMUX_BOOTSTRAP_TARBALL="$TARBALL" CODEMUX_BOOTSTRAP_SHA256="deadbeef" \
  bash -s -- --dry-run <"$ROOT/install.sh" >"$SANDBOX/bad.out" 2>&1; then
  bad "bootstrap: sha256 salah seharusnya ditolak"
else
  if grep -q 'sha256 tidak cocok' "$SANDBOX/bad.out"; then
    ok "bootstrap: sha256 salah ditolak dengan pesan jelas"
  else
    bad "bootstrap: pesan sha256 salah tidak jelas"
  fi
fi

# =============================================================================
# 2. self-update: tukar kode, backup, dan tetap bisa dijalankan
# =============================================================================
DEST="$SANDBOX/root"
mkdir -p "$DEST"
for p in bin lib templates VERSION versions.env install.sh; do
  [ -e "$ROOT/$p" ] && cp -a "$ROOT/$p" "$DEST/"
done
printf '0.0.1-old\n' >"$DEST/VERSION"

out="$(env HOME="$SANDBOX/home" XDG_CACHE_HOME="$SANDBOX/home/.cache" PREFIX="$SANDBOX/prefix" CODEMUX_HOME="$SANDBOX/state" \
  TMPDIR="$BASE" CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
  CODEMUX_SELF_ROOT="$DEST" CODEMUX_SELF_TARBALL="$TARBALL" CODEMUX_SELF_SHA256="$SHA" \
  bash "$ROOT/bin/codemux" self-update --yes 2>&1)"
rc=$?
want="$(cat "$ROOT/VERSION")"
if [ "$rc" -eq 0 ] && [ "$(cat "$DEST/VERSION")" = "$want" ]; then
  ok "self-update: kode ditukar ke versi rilis ($want)"
else
  bad "self-update: gagal (rc=$rc, VERSION=$(cat "$DEST/VERSION" 2>/dev/null))"
  printf '%s\n' "$out" | tail -6 | sed 's/^/     /'
fi
if ls -d "$SANDBOX/state"/backup/*-selfupdate >/dev/null 2>&1; then
  ok "self-update: kode lama di-backup"
else
  bad "self-update: backup tidak dibuat"
fi
if bash "$DEST/bin/codemux" version >/dev/null 2>&1; then
  ok "self-update: hasil bisa dijalankan"
else
  bad "self-update: hasil tidak bisa dijalankan"
fi

rm -rf "$SANDBOX"
printf '\n%s lulus · %s gagal\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
