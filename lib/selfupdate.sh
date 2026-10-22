# shellcheck shell=bash
# shellcheck disable=SC2034  # CODEMUX_YES dipakai codemux_confirm (lib lain)
# lib/selfupdate.sh — `codemux self-update`: ganti kode codemux dari rilis hulu.
# Data pengguna (memori, state, backup) TIDAK disentuh.

CODEMUX_REPO="${CODEMUX_REPO:-kusnuzon/codemux}"

codemux_self_cache() { printf '%s/codemux/src' "${XDG_CACHE_HOME:-$HOME/.cache}"; }

# Root yang diganti; bisa ditimpa untuk tes.
codemux_self_root() { printf '%s' "${CODEMUX_SELF_ROOT:-$CODEMUX_ROOT}"; }

# Unduh + verifikasi tarball rilis. Hasil: path tarball di stdout.
# Gagal → return 1 (pemanggil yang memberi pesan).
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
    # belum ada rilis → pakai main (tanpa sha256; ditandai di pesan)
    url="https://codeload.github.com/$CODEMUX_REPO/tar.gz/refs/heads/main"
    sha_url=""
  fi

  tarball="$cache/codemux-download.tar.gz"
  rm -f "$tarball.part"
  curl -fsSL --max-time 180 "$url" -o "$tarball.part" || { rm -f "$tarball.part"; return 1; }
  mv -f "$tarball.part" "$tarball" || return 1

  if [ -n "$sha_url" ]; then
    expected="$(curl -fsSL --max-time 20 "$sha_url" 2>/dev/null | awk '{print $1}')" || expected=""
  fi
  if [ -n "$expected" ]; then
    got="$(sha256sum "$tarball" | awk '{print $1}')"
    [ "$got" = "$expected" ] || { rm -f "$tarball"; return 1; }
  else
    printf 'tanpa-sha\n' >&2
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
        printf '%s\n' 'penggunaan: codemux self-update [--dry-run] [--yes] [--force]' \
          '' 'Unduh rilis codemux terbaru (tarball + sha256), backup kode lama,' \
          'lalu tukar bin/ lib/ templates/ VERSION. Memori & state tidak disentuh.'
        return 0
        ;;
      *) log_warn "opsi tidak dikenal untuk self-update: $1" ;;
    esac
    shift
  done

  root="$(codemux_self_root)"
  dest="$(codemux_self_cache)/current"
  printf '%s%s %s%s · self-update\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R"
  printf '  kode aktif : %s\n' "$root"
  printf '  sumber baru: %s\n\n' "${CODEMUX_SELF_TARBALL:-rilis hulu $CODEMUX_REPO}"

  if [ "$dry" -eq 1 ]; then log_dim "mode --dry-run: tidak ada yang diubah."; return 0; fi
  codemux_confirm "Unduh dan pasang rilis codemux terbaru?" || { log_dim "dibatalkan."; return 0; }

  mkdir -p "$CODEMUX_HOME" 2>/dev/null
  tarball="$(codemux_self_download 2>"$CODEMUX_HOME/.selfupdate.err")" || {
    log_fail "gagal mengunduh rilis codemux"
    [ -s "$CODEMUX_HOME/.selfupdate.err" ] && log_dim "$(tail -1 "$CODEMUX_HOME/.selfupdate.err")"
    return 1
  }
  if grep -q '^tanpa-sha$' "$CODEMUX_HOME/.selfupdate.err" 2>/dev/null && [ "$force" -eq 0 ]; then
    log_warn "rilis belum punya sha256 (fallback main) — lanjutkan dengan --force"
    return 1
  fi

  mkdir -p "$dest.new" || { log_fail "tidak bisa menulis $dest.new"; return 2; }
  rm -rf "${dest:?}.new"
  mkdir -p "$dest.new"
  if ! tar -xzf "$tarball" -C "$dest.new" --strip-components=1 2>/dev/null; then
    log_fail "tarball tidak bisa diekstrak"
    rm -rf "$dest.new"
    return 1
  fi
  if [ ! -f "$dest.new/bin/codemux" ] || ! bash -n "$dest.new/bin/codemux" 2>/dev/null; then
    log_fail "isi tarball tidak valid (bin/codemux hilang/rusak)"
    rm -rf "$dest.new"
    return 1
  fi
  new_root="$(cat "$dest.new/VERSION" 2>/dev/null || echo '?')"

  # backup kode lama
  bak_dir="$CODEMUX_HOME/backup/$(date '+%Y%m%d-%H%M%S')-selfupdate"
  mkdir -p "$bak_dir" || { log_fail "tidak bisa membuat backup"; return 2; }
  local p
  for p in bin lib templates VERSION versions.env install.sh; do
    [ -e "$root/$p" ] && cp -a "$root/$p" "$bak_dir/" 2>/dev/null
  done

  # tukar: bin lib templates VERSION versions.env install.sh
  for p in bin lib templates VERSION versions.env install.sh; do
    [ -e "$dest.new/$p" ] || continue
    rm -rf "${root:?}/$p"
    cp -a "$dest.new/$p" "$root/$p" || {
      log_fail "gagal memasang $p — memulihkan backup"
      cp -a "$bak_dir/." "$root/" 2>/dev/null
      return 1
    }
  done
  rm -rf "${dest:?}.new"

  if ! bash "$root/bin/codemux" version >/dev/null 2>&1; then
    log_warn "versi baru gagal dijalankan — memulihkan backup"
    cp -a "$bak_dir/." "$root/" 2>/dev/null
    return 1
  fi

  log_ok "codemux diperbarui: $CODEMUX_VERSION → $new_root"
  log_dim "backup kode lama: $bak_dir"
  log_dim "cek: codemux check · pasang ulang launcher: codemux install"
  return 0
}

# Dipakai install.sh (bootstrap) setelah mengekstrak: pastikan layout valid.
codemux_bootstrap_check() {
  local dir="$1"
  [ -f "$dir/bin/codemux" ] && [ -f "$dir/VERSION" ] || return 1
  bash -n "$dir/bin/codemux" 2>/dev/null || return 1
  return 0
}
