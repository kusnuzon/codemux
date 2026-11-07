# shellcheck shell=bash
# lib/adapter.sh — download upstream installer scripts (adapter, not a code copy).
# Source: GitHub API with Accept raw (raw.githubusercontent often serves a stale cache).

# codemux_adapter_fetch <name> <url> -> print the local script path
# url may be: https://… (API raw) · file:///path · /path (for tests)
codemux_adapter_fetch() {
  local name="$1" url="$2"
  local dir="$CODEMUX_HOME/cache"
  local dest="$dir/$name-install.sh"

  mkdir -p "$dir" || return 1
  rm -f "$dest.part" "$dest.part.sha256"

  case "$url" in
    http://* | https://*)
      codemux_download "$url" "$dest.part" 'application/vnd.github.raw' || {
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
  # must be a shell script, not an HTML error page
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

# codemux_fetch_raw <url> <dest> — download any text file (plugin, digest).
# Rejects HTML pages (rate-limit/error) so they are never stored as code.
codemux_fetch_raw() {
  local url="$1" dest="$2" dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 1
  rm -f "$dest.part"
  case "$url" in
    http://* | https://*)
      codemux_download "$url" "$dest.part" 'application/vnd.github.raw' || {
        rm -f "$dest.part"
        return 1
      }
      ;;
    file://*) cp "${url#file://}" "$dest.part" || return 1 ;;
    /*) cp "$url" "$dest.part" || return 1 ;;
    *) return 1 ;;
  esac
  if [ ! -s "$dest.part" ]; then
    rm -f "$dest.part"
    return 1
  fi
  case "$(head -c 1 "$dest.part" 2>/dev/null)" in
    '<') rm -f "$dest.part"; return 1 ;;
  esac
  mv -f "$dest.part" "$dest"
}
