#!/data/data/com.termux/files/usr/bin/bash
# tests/release.sh — test the install.sh bootstrap + codemux self-update (M6).
# The tarball is built from this checkout (git archive); nothing touches the system.
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

# --- release tarball from this checkout --------------------------------------
TARBALL="$SANDBOX/codemux.tar.gz"
if git archive --format=tar.gz --prefix=codemux/ -o "$TARBALL" HEAD 2>"$SANDBOX/tar.err"; then
  ok "tarball built from HEAD"
else
  bad "git archive failed ($(cat "$SANDBOX/tar.err" | head -2))"
  printf '\n%s passed · %s failed\n' "$pass" "$fail"
  exit 1
fi
SHA="$(sha256sum "$TARBALL" | awk '{print $1}')"

run_bootstrap() { # <options...>
  env HOME="$SANDBOX/home" XDG_CACHE_HOME="$SANDBOX/home/.cache" PREFIX="$SANDBOX/prefix" CODEMUX_HOME="$SANDBOX/state" \
    TMPDIR="$BASE" CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
    CODEMUX_BOOTSTRAP_TARBALL="$TARBALL" CODEMUX_BOOTSTRAP_SHA256="$SHA" \
    bash -s -- "$@" <"$ROOT/install.sh"
}

# =============================================================================
# 1. bootstrap: extract + continue into install
# =============================================================================
out="$(run_bootstrap --dry-run 2>&1)"
if printf '%s' "$out" | grep -q 'sha256 matches' &&
  printf '%s' "$out" | grep -q 'dry-run' &&
  printf '%s' "$out" | grep -q 'install (dry-run)'; then
  ok "bootstrap: sha256 verified + install continued"
else
  bad "bootstrap: unexpected flow"
  printf '%s\n' "$out" | tail -6 | sed 's/^/     /'
fi
cache="$SANDBOX/home/.cache/codemux/src/current"
if [ -f "$cache/bin/codemux" ] && [ -f "$cache/VERSION" ] && bash -n "$cache/bin/codemux" 2>/dev/null; then
  ok "bootstrap: code extracted to cache/current"
else
  bad "bootstrap: cache/current is not valid"
fi

# a sha mismatch must be rejected
if env HOME="$SANDBOX/home2" XDG_CACHE_HOME="$SANDBOX/home2/.cache" PREFIX="$SANDBOX/prefix" CODEMUX_HOME="$SANDBOX/state2" \
  TMPDIR="$BASE" CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
  CODEMUX_BOOTSTRAP_TARBALL="$TARBALL" CODEMUX_BOOTSTRAP_SHA256="deadbeef" \
  bash -s -- --dry-run <"$ROOT/install.sh" >"$SANDBOX/bad.out" 2>&1; then
  bad "bootstrap: a wrong sha256 should be rejected"
else
  if grep -q 'sha256 does not match' "$SANDBOX/bad.out"; then
    ok "bootstrap: wrong sha256 rejected with a clear message"
  else
    bad "bootstrap: the wrong-sha256 message is not clear"
  fi
fi

# =============================================================================
# 2. self-update: swap the code, back it up, and stay runnable
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
  ok "self-update: code swapped to the release version ($want)"
else
  bad "self-update: failed (rc=$rc, VERSION=$(cat "$DEST/VERSION" 2>/dev/null))"
  printf '%s\n' "$out" | tail -6 | sed 's/^/     /'
fi
if ls -d "$SANDBOX/state"/backup/*-selfupdate >/dev/null 2>&1; then
  ok "self-update: old code backed up"
else
  bad "self-update: no backup created"
fi
if bash "$DEST/bin/codemux" version >/dev/null 2>&1; then
  ok "self-update: the result runs"
else
  bad "self-update: the result does not run"
fi

rm -rf "$SANDBOX"
printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
