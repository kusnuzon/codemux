# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: deps — alat dasar yang harus ada sebelum apa pun.

CODEMUX_DEP_BINS="curl tar sha256sum gzip unzip awk sed"

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

m_deps_probe() {
  local miss
  miss="$(m_deps_missing | tr '\n' ' ' | sed 's/ *$//')"
  if [ -z "$miss" ]; then
    PROBE=OK; NOTE="$CODEMUX_DEP_BINS"
  else
    PROBE=MISS; NOTE="kurang: $miss"
  fi
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
  if [ -z "$pkgs" ]; then
    APPLY_NOTE="tidak ada yang perlu dipasang"
    return 0
  fi

  # shellcheck disable=SC2086
  codemux_spawn deps env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confold $pkgs || return 1
  local rc=0
  codemux_wait deps 1800 || rc=$?
  if [ "$rc" -ne 0 ]; then
    APPLY_NOTE="apt gagal (rc $rc): $(codemux_step_tail deps)"
    return "$rc"
  fi
  APPLY_NOTE="dipasang:$pkgs"
  return 0
}
