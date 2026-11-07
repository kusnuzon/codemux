# shellcheck shell=bash
# shellcheck disable=SC2034  # CODEMUX_YES is used by codemux_confirm (other libs)
# lib/selfupdate.sh — `codemux self-update`: replace the codemux code from the upstream release.
# User data (memory, state, backups) is NOT touched.

CODEMUX_REPO="${CODEMUX_REPO:-kusnuzon/codemux}"

codemux_self_cache() { printf '%s/codemux/src' "${XDG_CACHE_HOME:-$HOME/.cache}"; }

# Root that gets replaced; can be overridden for tests.
codemux_self_root() { printf '%s' "${CODEMUX_SELF_ROOT:-$CODEMUX_ROOT}"; }

# Download + verify the release tarball. Result: tarball path on stdout.
# Failure → return 1 (the caller prints the message).
codemux_self_download() {
  local cache tarball url sha_url expected="" got tag base
  cache="$(codemux_self_cache)"
  mkdir -p "$cache" || return 1

  tarball="${CODEMUX_SELF_TARBALL:-}"
  if [ -n "$tarball" ]; then
    [ -s "$tarball" ] || return 1
    expected="${CODEMUX_SELF_SHA256:-}"
    if [ -n "$expected" ]; then
      got="$(sha256sum "$tarball" | awk '{print $1}')"
      [ "$got" = "$expected" ] || return 1
    fi
    printf '%s' "$tarball"
    return 0
  fi

  base="${CODEMUX_GITHUB_BASE:-https://github.com}"
  tag="$(codemux_latest_tag "$CODEMUX_REPO" 2>/dev/null || true)"
  if [ -n "$tag" ]; then
    url="$base/$CODEMUX_REPO/releases/download/$tag/codemux.tar.gz"
    sha_url="$url.sha256"
  else
    # no release yet → use main (no sha256; flagged in the message)
    url="https://codeload.github.com/$CODEMUX_REPO/tar.gz/refs/heads/main"
    sha_url=""
  fi

  tarball="$cache/codemux-download.tar.gz"
  rm -f "$tarball.part"
  codemux_download "$url" "$tarball" || return 1

  if [ -n "$sha_url" ]; then
    expected="$(codemux_download "$sha_url" "$cache/codemux-download.sha256" &&
      awk '{print $1}' "$cache/codemux-download.sha256" 2>/dev/null)" || expected=""
  fi
  if [ -n "$expected" ]; then
    got="$(sha256sum "$tarball" | awk '{print $1}')"
    [ "$got" = "$expected" ] || { rm -f "$tarball"; return 1; }
  else
    printf 'no-sha\n' >&2
  fi
  printf '%s' "$tarball"
}

codemux_cmd_self_update() {
  local dry=0 force=0 tarball dest root new_root bak_dir
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -y | --yes) CODEMUX_YES=1 ;;
      --force) force=1 ;;
      -h | --help)
        printf '%s\n' 'usage: codemux self-update [--dry-run] [--yes] [--force]' \
          '' 'Download the latest codemux release (tarball + sha256), back up the old code,' \
          'then swap bin/ lib/ templates/ VERSION. Memory & state are not touched.'
        return 0
        ;;
      *) log_warn "unknown option for self-update: $1" ;;
    esac
    shift
  done

  root="$(codemux_self_root)"
  dest="$(codemux_self_cache)/current"
  printf '%s%s %s%s · self-update\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R"
  printf '  active code : %s\n' "$root"
  printf '  new source  : %s\n\n' "${CODEMUX_SELF_TARBALL:-upstream release $CODEMUX_REPO}"

  if [ "$dry" -eq 1 ]; then log_dim "--dry-run mode: nothing was changed."; return 0; fi
  codemux_confirm "Download and install the latest codemux release?" || { log_dim "cancelled."; return 0; }

  mkdir -p "$CODEMUX_HOME" 2>/dev/null
  tarball="$(codemux_self_download 2>"$CODEMUX_HOME/.selfupdate.err")" || {
    log_fail "failed to download the codemux release"
    [ -s "$CODEMUX_HOME/.selfupdate.err" ] && log_dim "$(tail -1 "$CODEMUX_HOME/.selfupdate.err")"
    return 1
  }
  if grep -q '^no-sha$' "$CODEMUX_HOME/.selfupdate.err" 2>/dev/null && [ "$force" -eq 0 ]; then
    log_warn "the release has no sha256 yet (main fallback) — continue with --force"
    return 1
  fi

  mkdir -p "$dest.new" || { log_fail "cannot write $dest.new"; return 2; }
  rm -rf "${dest:?}.new"
  mkdir -p "$dest.new"
  if ! tar -xzf "$tarball" -C "$dest.new" --strip-components=1 2>/dev/null; then
    log_fail "the tarball could not be extracted"
    rm -rf "$dest.new"
    return 1
  fi
  if [ ! -f "$dest.new/bin/codemux" ] || ! bash -n "$dest.new/bin/codemux" 2>/dev/null; then
    log_fail "the tarball contents are invalid (bin/codemux missing/broken)"
    rm -rf "$dest.new"
    return 1
  fi
  new_root="$(cat "$dest.new/VERSION" 2>/dev/null || echo '?')"

  # back up the old code
  bak_dir="$CODEMUX_HOME/backup/$(date '+%Y%m%d-%H%M%S')-selfupdate"
  mkdir -p "$bak_dir" || { log_fail "cannot create the backup"; return 2; }
  local p
  for p in bin lib templates VERSION versions.env install.sh; do
    [ -e "$root/$p" ] && cp -a "$root/$p" "$bak_dir/" 2>/dev/null
  done

  # swap: bin lib templates VERSION versions.env install.sh
  for p in bin lib templates VERSION versions.env install.sh; do
    [ -e "$dest.new/$p" ] || continue
    rm -rf "${root:?}/$p"
    cp -a "$dest.new/$p" "$root/$p" || {
      log_fail "failed to install $p — restoring the backup"
      cp -a "$bak_dir/." "$root/" 2>/dev/null
      return 1
    }
  done
  rm -rf "${dest:?}.new"

  if ! bash "$root/bin/codemux" version >/dev/null 2>&1; then
    log_warn "the new version failed to run — restoring the backup"
    cp -a "$bak_dir/." "$root/" 2>/dev/null
    return 1
  fi

  log_ok "codemux updated: $CODEMUX_VERSION → $new_root"
  log_dim "old code backup: $bak_dir"
  log_dim "check: codemux check · reinstall the launcher: codemux install"
  return 0
}

# Used by install.sh (bootstrap) after extracting: make sure the layout is valid.
codemux_bootstrap_check() {
  local dir="$1"
  [ -f "$dir/bin/codemux" ] && [ -f "$dir/VERSION" ] || return 1
  bash -n "$dir/bin/codemux" 2>/dev/null || return 1
  return 0
}
