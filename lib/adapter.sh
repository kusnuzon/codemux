# shellcheck shell=bash
# lib/adapter.sh — unduh skrip installer hulu (adapter, bukan salinan kode).
# Sumber: API GitHub dengan Accept raw (raw.githubusercontent sering cache basi).

# codemux_adapter_fetch <nama> <url> -> cetak path skrip lokal
# url boleh: https://… (API raw) · file:///path · /path (untuk tests)
codemux_adapter_fetch() {
  local name="$1" url="$2"
  local dir="$CODEMUX_HOME/cache"
  local dest="$dir/$name-install.sh"

  mkdir -p "$dir" || return 1
  rm -f "$dest.part" "$dest.part.sha256"

  case "$url" in
    http://* | https://*)
      curl -fsSL -H 'Accept: application/vnd.github.raw' "$url" -o "$dest.part" || {
        rm -f "$dest.part"
        return 1
      }
      ;;
    file://*)
      cp "${url#file://}" "$dest.part" || return 1
      ;;
    /*)
      cp "$url" "$dest.part" || return 1
      ;;
    *)
      return 1
      ;;
  esac

  if [ ! -s "$dest.part" ]; then
    rm -f "$dest.part"
    return 1
  fi
  # harus skrip shell, bukan halaman error HTML
  if ! head -c 2 "$dest.part" 2>/dev/null | grep -q '#!'; then
    rm -f "$dest.part"
    return 1
  fi

  mv -f "$dest.part" "$dest" || return 1
  sha256sum "$dest" 2>/dev/null | cut -d' ' -f1 >"$dest.sha256"
  printf '%s\n' "$dest"
}

codemux_adapter_sha() {
  local f="$1"
  [ -f "$f.sha256" ] && cut -c1-12 "$f.sha256"
}
