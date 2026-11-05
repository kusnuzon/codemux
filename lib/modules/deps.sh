# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: deps — alat dasar yang harus ada sebelum apa pun.

CODEMUX_DEP_BINS="curl tar sha256sum gzip unzip awk sed jq"

# nama paket untuk sebuah binary (beberapa binary beda paket)
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

# curl bisa ADA tapi mati (efek paket glibc): bedakan dari "tidak terpasang".
m_deps_curl_broken() {
  have curl && ! codemux_curl_ok
}

m_deps_probe() {
  local miss
  miss="$(m_deps_missing | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$miss" ]; then
    PROBE=MISS; NOTE="kurang: $miss"; return
  fi
  if m_deps_curl_broken; then
    PROBE=MISS; NOTE="curl terpasang tapi rusak (libcurl/openssl) — akan dipasang ulang"; return
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
    # shellcheck disable=SC2086
    if ! codemux_apt_install $pkgs; then
      APPLY_NOTE="apt gagal: $pkgs"
      return 1
    fi
    APPLY_NOTE="dipasang: $pkgs"
  fi

  if m_deps_curl_broken; then
    codemux_heal_curl || {
      APPLY_NOTE="curl tetap rusak setelah pemasangan ulang"
      return 1
    }
    APPLY_NOTE="${APPLY_NOTE:+$APPLY_NOTE · }curl dipulihkan"
  fi

  [ -n "$APPLY_NOTE" ] || APPLY_NOTE="tidak ada yang perlu dipasang"
  return 0
}
