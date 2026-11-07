# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# lib/common.sh — core codemux helpers (colors, logging, detection, utils).
# Performs no action when sourced.

CODEMUX_NAME="codemux"
CODEMUX_ROOT="${CODEMUX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODEMUX_VERSION="$(cat "$CODEMUX_ROOT/VERSION" 2>/dev/null || echo "0.0.0")"
CODEMUX_HOME="${CODEMUX_HOME:-$HOME/.config/codemux}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# versions.env (optional; never fail when it is missing)
# Values from the environment win over the file (used by tests/ and CI).
_CODEMUX_ENV_APT="${CODEMUX_APT_PACKAGES-__unset__}"
_CODEMUX_ENV_MIRROR="${CODEMUX_MIRROR_MAIN-__unset__}"
if [ -f "$CODEMUX_ROOT/versions.env" ]; then
  # shellcheck source=/dev/null
  . "$CODEMUX_ROOT/versions.env"
fi
[ "$_CODEMUX_ENV_APT" = "__unset__" ] || CODEMUX_APT_PACKAGES="$_CODEMUX_ENV_APT"
[ "$_CODEMUX_ENV_MIRROR" = "__unset__" ] || CODEMUX_MIRROR_MAIN="$_CODEMUX_ENV_MIRROR"
unset _CODEMUX_ENV_APT _CODEMUX_ENV_MIRROR
OPENCODE_V1_VERSION="${OPENCODE_V1_VERSION:-?}"
OPENCODE_V2_VERSION="${OPENCODE_V2_VERSION:-?}"
CODEMUX_APT_PACKAGES="${CODEMUX_APT_PACKAGES:-}"
CODEMUX_APT_EXTRA="${CODEMUX_APT_EXTRA:-}"
CODEMUX_APT_REPOS="${CODEMUX_APT_REPOS:-}"

# --- colors ------------------------------------------------------------------
codemux_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
    C_OK=$'\033[38;5;42m'; C_WARN=$'\033[38;5;214m'
    C_MISS=$'\033[38;5;203m'; C_INFO=$'\033[38;5;45m'
  else
    C_R=''; C_DIM=''; C_B=''; C_OK=''; C_WARN=''; C_MISS=''; C_INFO=''
  fi
}

# --- logging -----------------------------------------------------------------
log_ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_R" "$*"; }
log_warn() { printf '%s!%s %s\n' "$C_WARN" "$C_R" "$*"; }
log_fail() { printf '%s✖%s %s\n' "$C_MISS" "$C_R" "$*" >&2; }
log_info() { printf '%s→%s %s\n' "$C_INFO" "$C_R" "$*"; }
log_dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_R"; }

codemux_die() {
  log_fail "$*"
  exit 2
}

# --- utils -------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

human_bytes() {
  local b="${1:-0}"
  if [ "$b" -ge 1073741824 ]; then
    awk -v b="$b" 'BEGIN{printf "%.1f GB", b/1073741824}'
  elif [ "$b" -ge 1048576 ]; then
    awk -v b="$b" 'BEGIN{printf "%.0f MB", b/1048576}'
  elif [ "$b" -ge 1024 ]; then
    awk -v b="$b" 'BEGIN{printf "%.0f KB", b/1024}'
  else
    printf '%s B' "$b"
  fi
}

# Safe path: must be inside $HOME or $CODEMUX_HOME.
codemux_safe_path() {
  case "$1" in
    "$HOME"/*|"$CODEMUX_HOME"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# json_escape: minimal escaping for --json output.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}

# --- environment-proof apt & downloads ---------------------------------------
# Two real failures seen on a from-scratch Termux install (log 2026-11-02):
#   1. apt used without `apt-get update` -> "E: Unable to locate package …"
#      (nodejs/tesseract/chromium) so the toolset module FAILED.
#   2. the glibc package overwrote libcurl -> curl died with
#      `cannot locate symbol "SSL_set_quic_tls_early_data_enabled"`, so
#      EVERY later download (V1/V2 adapters, memory plugins) failed too.
# The helpers below close both gaps and are used by all modules.

CODEMUX_NET_TIMEOUT="${CODEMUX_NET_TIMEOUT:-300}"
CODEMUX_NET_PROBE="${CODEMUX_NET_PROBE:-https://api.github.com/}"

codemux_apt_update() {
  local i
  have apt-get || return 1
  for i in 1 2 3; do
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && return 0
    sleep $((i * 2))
  done
  return 1
}

# codemux_apt_install <package...> — install; if the package list is stale, update and retry.
codemux_apt_install() {
  local pkgs=("$@") out rc=0
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  have apt-get || return 1
  if out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confold "${pkgs[@]}" 2>&1)"; then
    return 0
  fi
  rc=$?
  case "$out" in
    *"Unable to locate package"*|*"has no installation candidate"*|*"404"*)
      codemux_apt_update || true
      if out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-confold --fix-missing "${pkgs[@]}" 2>&1)"; then
        return 0
      fi
      rc=$?
      ;;
  esac
  printf '%s\n' "$out" | tail -n 3 >&2
  return "$rc"
}

codemux_curl_ok() {
  have curl || return 1
  curl -fsS --max-time 10 -o /dev/null "$CODEMUX_NET_PROBE" >/dev/null 2>&1
}

# Repair curl damaged by the glibc package (wrong libcurl version).
codemux_heal_curl() {
  codemux_curl_ok && return 0
  log_warn "curl is unhealthy (usually an effect of the glibc package) — reinstalling curl/libcurl/openssl"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold curl libcurl openssl ca-certificates \
    >/dev/null 2>&1 || codemux_apt_install curl libcurl openssl ca-certificates || true
  hash -r 2>/dev/null || true
  codemux_curl_ok
}

# One download attempt. <url> <dest> [accept]
codemux_dl_once() {
  local url="$1" dest="$2" accept="${3:-}"
  if have curl; then
    if [ -n "$accept" ]; then
      curl -fsSL --max-time "$CODEMUX_NET_TIMEOUT" -H "Accept: $accept" "$url" -o "$dest" 2>/dev/null
    else
      curl -fsSL --max-time "$CODEMUX_NET_TIMEOUT" "$url" -o "$dest" 2>/dev/null
    fi
    [ -s "$dest" ] && return 0
    rm -f "$dest"
  fi
  if have wget; then
    wget -q --timeout=60 -O "$dest" "$url" >/dev/null 2>&1
    [ -s "$dest" ] && return 0
    rm -f "$dest"
  fi
  if have python; then
    python - "$url" "$dest" "$accept" <<'PY' >/dev/null 2>&1
import sys, urllib.request
url, dest, accept = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
req = urllib.request.Request(url, headers={"User-Agent": "codemux"})
if accept:
    req.add_header("Accept", accept)
data = urllib.request.urlopen(req, timeout=60).read()
if not data:
    raise SystemExit(1)
open(dest, "wb").write(data)
PY
    [ -s "$dest" ] && return 0
    rm -f "$dest"
  fi
  return 1
}

# codemux_download <url> <dest> [accept] — curl, then repair curl, then wget/python.
codemux_download() {
  local url="$1" dest="$2" accept="${3:-}" part="$2.part"
  mkdir -p "$(dirname "$dest")" || return 1
  rm -f "$part"
  if codemux_dl_once "$url" "$part" "$accept"; then
    mv -f "$part" "$dest" && return 0
  fi
  rm -f "$part"
  codemux_heal_curl >/dev/null 2>&1 || true
  if codemux_dl_once "$url" "$part" "$accept"; then
    mv -f "$part" "$dest" && return 0
  fi
  rm -f "$part"
  return 1
}

codemux_usage() {
  cat <<'EOF'
codemux — Termux installer & maintainer (OpenCode V1 + V2 + memory + updates)

usage:
  codemux [command] [options]

commands:
  check              status of each module (changes nothing)
  install            install what is missing; safe to repeat & resumes after a break
  status             last install progress, lock, last 10 log lines
  repair             clean up leftovers from a process that died midway
  version            codemux version + installed components
  help               this help
  update-check       compare local versions with upstream releases (24h cache)
  upgrade            update apt + V1/V2 payload + launcher
  doctor             full diagnosis + repair suggestions
  memory             cross-session memory status (read-only)
  uninstall          remove V1/V2 payload + launcher block (memory stays)
  self-update        update the codemux code from the upstream release

check options:
  --json             machine-readable output

install options:
  --dry-run          show the plan, change nothing
  --fresh            start from step 1 (do not resume)
  --skip a,b         skip modules (deps,mirror,storage,toolset,glibc,v1,v2,launcher,dotfiles,memory,self)
  -y, --yes          no confirmation (default: no questions asked)

repair options:
  --dry-run          show the repairs that would be made
EOF
}

# The ACTUAL V1 version (payload), not the dpkg package version.
# dpkg can lag behind: package 1.19.0 but payload already 1.19.3.
opencode_v1_version() {
  local v="" dpkg_v=""
  if have opencode; then
    v="$(timeout 15 opencode --version 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  fi
  dpkg_v="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
  case "$v" in
    [0-9]*) printf '%s' "$v" ;;
    *) printf '%s' "${dpkg_v:-?}" ;;
  esac
}

opencode_v2_version() {
  cat "$PREFIX/share/opencode-v2/VERSION" 2>/dev/null || printf '?'
}

codemux_versions() {
  printf '%-16s %s\n' "codemux" "$CODEMUX_VERSION"
  printf '%-16s %s\n' "opencode-v1" "$(opencode_v1_version)"
  printf '%-16s %s\n' "opencode-v2" "$(opencode_v2_version)"
}

codemux_not_ready() {
  log_warn "command '$1' is not available yet in version $CODEMUX_VERSION (next milestone)."
  log_dim "Available commands: check, install, status, repair, memory, update-check, doctor, upgrade, uninstall, self-update, version, help."
  exit 1
}
