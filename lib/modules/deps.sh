# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: deps — base tools that must exist before anything else.

CODEMUX_DEP_BINS="curl tar sha256sum gzip unzip awk sed jq"

# package name for a binary (some binaries come from a differently named package)
m_deps_pkg() {
  case "$1" in
    awk) echo gawk ;;
    sha256sum) echo coreutils ;;
    *) echo "$1" ;;
  esac
}

m_deps_missing() {
  local b
  for b in $CODEMUX_DEP_BINS; do
    have "$b" || printf '%s\n' "$b"
  done
}

# curl can EXIST but be dead (an effect of the glibc package): tell it apart from "not installed".
m_deps_curl_broken() {
  have curl && ! codemux_curl_ok
}

m_deps_probe() {
  local miss
  miss="$(m_deps_missing | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$miss" ]; then
    PROBE=MISS; NOTE="missing: $miss"; return
  fi
  if m_deps_curl_broken; then
    PROBE=MISS; NOTE="curl is installed but broken (libcurl/openssl) — it will be reinstalled"; return
  fi
  PROBE=OK; NOTE="$CODEMUX_DEP_BINS"
}

m_deps_verify() { m_deps_probe; }

m_deps_apply() {
  local b pkgs="" p
  for b in $(m_deps_missing); do
    p="$(m_deps_pkg "$b")"
    case " $pkgs " in *" $p "*) continue ;; esac
    pkgs="$pkgs $p"
  done
  pkgs="$(printf '%s' "$pkgs" | sed 's/^ *//')"

  if [ -n "$pkgs" ]; then
    codemux_spin_msg "apt install: $pkgs"
    # shellcheck disable=SC2086
    if ! codemux_apt_install $pkgs; then
      APPLY_NOTE="apt failed: $pkgs"
      return 1
    fi
    APPLY_NOTE="installed: $pkgs"
  fi

  if m_deps_curl_broken; then
    codemux_spin_msg "repairing curl (reinstalling curl/libcurl/openssl)"
    codemux_heal_curl || {
      APPLY_NOTE="curl is still broken after reinstalling"
      return 1
    }
    APPLY_NOTE="${APPLY_NOTE:+$APPLY_NOTE · }curl repaired"
  fi

  [ -n "$APPLY_NOTE" ] || APPLY_NOTE="nothing to install"
  return 0
}
