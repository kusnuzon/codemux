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
# Components installed by default (the user can pick V1 only, V2 only, or both).
CODEMUX_COMPONENTS_DEFAULT="${CODEMUX_COMPONENTS_DEFAULT:-v1 v2}"

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

# --- progress feedback --------------------------------------------------------
# A long step (apt, adapters, downloads) prints one line that keeps updating, so
# the install never looks frozen. Silent when stderr is not a terminal or when
# CODEMUX_PROGRESS=0 / CODEMUX_NO_PROGRESS=1 (tests, CI, log files).
# CODEMUX_PROGRESS=1 forces it on (used by the tests).
CODEMUX_SPIN_PID=""
CODEMUX_SPIN_PREFIX=""
CODEMUX_SPIN_DIR=""

codemux_progress_tty() {
  case "${CODEMUX_PROGRESS:-}" in
    1 | yes | on) return 0 ;;
    0 | no | off) return 1 ;;
  esac
  [ -z "${CODEMUX_NO_PROGRESS:-}" ] && [ -t 2 ]
}

# Text next to the spinner ("installing", "downloading memory.js", …).
codemux_spin_msg() { # <message>
  [ -n "$CODEMUX_SPIN_DIR" ] || return 0
  printf '%s' "${1:-working}" >"$CODEMUX_SPIN_DIR/.spin.msg" 2>/dev/null || true
}

# Show the growing size of a file (e.g. the .part of a download).
codemux_spin_size() { # [file]
  [ -n "$CODEMUX_SPIN_DIR" ] || return 0
  if [ -n "${1:-}" ]; then
    printf '%s' "$1" >"$CODEMUX_SPIN_DIR/.spin.size" 2>/dev/null || true
  else
    rm -f "$CODEMUX_SPIN_DIR/.spin.size" 2>/dev/null || true
  fi
}

# codemux_spin_start <prefix> [message]
# The prefix is the part that stays fixed (e.g. "[6/11] v1         "); the
# caller prints the result right after codemux_spin_stop returns.
codemux_spin_start() {
  codemux_spin_stop
  codemux_progress_tty || return 0
  CODEMUX_SPIN_PREFIX="$1"
  CODEMUX_SPIN_DIR="${CODEMUX_HOME:-${TMPDIR:-/tmp}}/run"
  mkdir -p "$CODEMUX_SPIN_DIR" 2>/dev/null || { CODEMUX_SPIN_DIR=""; return 0; }
  codemux_spin_msg "${2:-working}"
  codemux_spin_size ""
  (
    frames='|/-\'
    i=0
    start=$SECONDS
    while :; do
      msg="$(cat "$CODEMUX_SPIN_DIR/.spin.msg" 2>/dev/null)" || msg=working
      extra=""
      sf="$(cat "$CODEMUX_SPIN_DIR/.spin.size" 2>/dev/null)"
      if [ -n "$sf" ] && [ -f "$sf" ]; then
        b="$(stat -c %s "$sf" 2>/dev/null || echo 0)"
        extra=" · $(human_bytes "$b")"
      fi
      printf '\r%s%s%s %s%s (%ss%s)\033[K' \
        "$CODEMUX_SPIN_PREFIX" "$C_INFO" "${frames:$((i % 4)):1}" "$C_R" \
        "$msg" "$((SECONDS - start))" "$extra" >&2
      i=$((i + 1))
      sleep 0.25 2>/dev/null || sleep 1
    done
  ) &
  CODEMUX_SPIN_PID=$!
}

# Remove the current spinner line but keep the prefix (the caller appends OK/FAIL).
codemux_spin_stop() {
  if [ -z "$CODEMUX_SPIN_PID" ]; then
    CODEMUX_SPIN_DIR=""
    return 0
  fi
  kill "$CODEMUX_SPIN_PID" 2>/dev/null || true
  wait "$CODEMUX_SPIN_PID" 2>/dev/null || true
  CODEMUX_SPIN_PID=""
  printf '\r%s\033[K' "$CODEMUX_SPIN_PREFIX" >&2
  rm -f "$CODEMUX_SPIN_DIR/.spin.msg" "$CODEMUX_SPIN_DIR/.spin.size" 2>/dev/null || true
  CODEMUX_SPIN_DIR=""
  return 0
}

# Called before a normal log line so it does not land on top of the spinner.
codemux_spin_pause() {
  [ -n "$CODEMUX_SPIN_PID" ] || return 0
  printf '\r\033[K' >&2
}

# --- logging -----------------------------------------------------------------
log_ok()   { codemux_spin_pause; printf '%s✔%s %s\n' "$C_OK" "$C_R" "$*"; }
log_warn() { codemux_spin_pause; printf '%s!%s %s\n' "$C_WARN" "$C_R" "$*"; }
log_fail() { codemux_spin_pause; printf '%s✖%s %s\n' "$C_MISS" "$C_R" "$*" >&2; }
log_info() { codemux_spin_pause; printf '%s→%s %s\n' "$C_INFO" "$C_R" "$*"; }
log_dim()  { codemux_spin_pause; printf '%s%s%s\n' "$C_DIM" "$*" "$C_R"; }

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

# GitHub API calls without a token are capped at 60 requests/hour and start
# returning HTTP 403 once the quota is gone (a few installs are enough to hit
# it, because V1/V2/memory each download from api.github.com). Reuse a token
# when one is available: env first, then the gh CLI.
_CODEMUX_GH_TOKEN_CACHE=""
codemux_gh_token() {
  if [ -n "$_CODEMUX_GH_TOKEN_CACHE" ]; then
    printf '%s' "$_CODEMUX_GH_TOKEN_CACHE"
    return 0
  fi
  local tok="${CODEMUX_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
  if [ -z "$tok" ] && have gh; then
    tok="$(gh auth token --hostname github.com 2>/dev/null || true)"
  fi
  _CODEMUX_GH_TOKEN_CACHE="$tok"
  printf '%s' "$tok"
}

# Is this a GitHub API URL (i.e. subject to the 60/hour rate limit)?
codemux_api_url() {
  case "$1" in
    "https://api.github.com/"*) return 0 ;;
  esac
  return 1
}

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

# Curl is healthy when it completes an HTTPS request, whatever the status code:
# api.github.com answers 403 once the unauthenticated quota (60/h) is gone, and
# -f used to turn that into "curl is broken" -> pointless reinstall on every run.
codemux_curl_ok() {
  have curl || return 1
  local tok=""
  if codemux_api_url "$CODEMUX_NET_PROBE"; then
    tok="$(codemux_gh_token)"
  fi
  if [ -n "$tok" ]; then
    curl -sS --max-time 10 -o /dev/null -H "Authorization: Bearer $tok" "$CODEMUX_NET_PROBE" >/dev/null 2>&1
  else
    curl -sS --max-time 10 -o /dev/null "$CODEMUX_NET_PROBE" >/dev/null 2>&1
  fi
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
  local url="$1" dest="$2" accept="${3:-}" tok=""
  local -a hdr=()
  if codemux_api_url "$url"; then
    tok="$(codemux_gh_token)"
  fi
  [ -n "$accept" ] && hdr+=(-H "Accept: $accept")
  [ -n "$tok" ] && hdr+=(-H "Authorization: Bearer $tok")
  if have curl; then
    curl -fsSL --max-time "$CODEMUX_NET_TIMEOUT" "${hdr[@]+"${hdr[@]}"}" "$url" -o "$dest" 2>/dev/null
    [ -s "$dest" ] && return 0
    rm -f "$dest"
  fi
  if have wget; then
    local -a whdr=()
    [ -n "$tok" ] && whdr+=("--header=Authorization: Bearer $tok")
    wget -q --timeout=60 "${whdr[@]+"${whdr[@]}"}" -O "$dest" "$url" >/dev/null 2>&1
    [ -s "$dest" ] && return 0
    rm -f "$dest"
  fi
  if have python; then
    python - "$url" "$dest" "$accept" "$tok" <<'PY' >/dev/null 2>&1
import sys, urllib.request
url, dest, accept = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
token = sys.argv[4] if len(sys.argv) > 4 else ""
req = urllib.request.Request(url, headers={"User-Agent": "codemux"})
if accept:
    req.add_header("Accept", accept)
if token:
    req.add_header("Authorization", "Bearer " + token)
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
# In a terminal it reports progress (spinner message + growing size), so a slow
# mobile connection does not look frozen.
codemux_download() {
  local url="$1" dest="$2" accept="${3:-}" part="$2.part" name size
  name="$(basename "$dest")"
  mkdir -p "$(dirname "$dest")" || return 1
  rm -f "$part"

  if codemux_progress_tty; then
    if [ -n "$CODEMUX_SPIN_PID" ]; then
      codemux_spin_msg "downloading $name"
      codemux_spin_size "$part"
    else
      printf '  %s↓ downloading %s…%s\n' "$C_DIM" "$name" "$C_R" >&2
    fi
  fi

  if codemux_dl_once "$url" "$part" "$accept"; then
    mv -f "$part" "$dest" || return 1
  else
    rm -f "$part"
    codemux_heal_curl >/dev/null 2>&1 || true
    if codemux_dl_once "$url" "$part" "$accept"; then
      mv -f "$part" "$dest" || return 1
    else
      rm -f "$part"
      if codemux_api_url "$url" && [ -z "$(codemux_gh_token)" ]; then
        log_warn "download failed: the GitHub API allows 60 requests/hour without a token (HTTP 403). Run 'gh auth login' or export GITHUB_TOKEN, then retry."
      fi
      return 1
    fi
  fi

  if codemux_progress_tty; then
    if [ -n "$CODEMUX_SPIN_PID" ]; then
      codemux_spin_size ""
      codemux_spin_msg "installing"
    else
      size="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
      printf '  %s↓ %s (%s)%s\n' "$C_DIM" "$name" "$(human_bytes "$size")" "$C_R" >&2
    fi
  fi
  return 0
}

# --- component selection (V1 only / V2 only / both) --------------------------
# The choice is stored in ~/.config/codemux/components ("v1 v2" = both) so
# install, check, upgrade and update-check agree with each other.
codemux_components_file() { printf '%s/components' "$CODEMUX_HOME"; }

# codemux_components_norm <v1|v2|both|v1,v2|...> → "v1 v2" (ordered, unique)
# Returns 1 for anything unrecognised.
codemux_components_norm() {
  local raw="${1:-}" item seen_v1=0 seen_v2=0 out=""
  raw="${raw//,/ }"
  for item in $raw; do
    case "$item" in
      both | all)
        seen_v1=1; seen_v2=1 ;;
      v1) seen_v1=1 ;;
      v2) seen_v2=1 ;;
      *) return 1 ;;
    esac
  done
  [ "$seen_v1" -eq 1 ] && out="v1"
  if [ "$seen_v2" -eq 1 ]; then
    out="${out:+$out }v2"
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Saved selection, or the default when nothing has been saved yet.
codemux_components_get() {
  local f val
  f="$(codemux_components_file)"
  if [ -f "$f" ]; then
    val="$(codemux_components_norm "$(tr '\n' ' ' <"$f" 2>/dev/null)")" &&
      { printf '%s' "$val"; return 0; }
  fi
  printf '%s' "$CODEMUX_COMPONENTS_DEFAULT"
}

# Persist the selection (atomic). Returns 1 when the list is invalid.
codemux_components_set() {
  local val
  val="$(codemux_components_norm "$1")" || return 1
  mkdir -p "$CODEMUX_HOME" || return 1
  printf '%s\n' "$val" | codemux_atomic_write "$(codemux_components_file)"
}

# Components that really have a payload on this device. Upgrade uses this so a
# V1-only (or V2-only) install never pulls the missing component in.
codemux_components_installed() {
  local out=""
  [ -f "$PREFIX/share/opencode/opencode.real" ] && out="v1"
  if [ -f "$PREFIX/share/opencode-v2/opencode.real" ]; then
    out="${out:+$out }v2"
  fi
  printf '%s' "$out"
}

codemux_component_selected() {
  case " $(codemux_components_get) " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
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
  --only v1|v2|both  install OpenCode V1 only, V2 only, or both (default: ask,
                     or keep the saved choice; non-interactive → both)
  --components X     same as --only
  --skip a,b         skip modules (deps,mirror,storage,toolset,glibc,v1,v2,launcher,dotfiles,memory,self)
  -y, --yes          no confirmation, never ask (keep the saved/default choice)

component choice:
  With --only v1 only the V1 payload is installed (V2 stays untouched) and the
  other way around; "both" installs V1 + V2. The shared dependencies (base
  tools, apt toolset, glibc runtime, memory files, launcher) are ALWAYS
  installed first, so any choice works on a fresh Termux install.
  The choice is saved in ~/.config/codemux/components and reused by
  install/check/upgrade/update-check. Override it any time with --only.

repair options:
  --dry-run          show the repairs that would be made

progress:
  Long steps (apt, the V1/V2 adapters, downloads) show a live spinner with
  elapsed time and, while downloading, the size so far. Set CODEMUX_PROGRESS=0
  (or CODEMUX_NO_PROGRESS=1) to silence it; non-terminal output is silent
  automatically, so logs and CI stay clean.
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
  local found=0
  printf '%-16s %s\n' "codemux" "$CODEMUX_VERSION"
  if codemux_component_selected v1 && have opencode; then
    printf '%-16s %s\n' "opencode-v1" "$(opencode_v1_version)"
    found=1
  fi
  if codemux_component_selected v2 && [ -x "$PREFIX/share/opencode-v2/opencode.real" ]; then
    printf '%-16s %s\n' "opencode-v2" "$(opencode_v2_version)"
    found=1
  fi
  [ "$found" -eq 1 ] || printf '%-16s %s\n' "components" "none installed yet"
  printf '%-16s %s\n' "components" "$(codemux_components_get)"
}

codemux_not_ready() {
  log_warn "command '$1' is not available yet in version $CODEMUX_VERSION (next milestone)."
  log_dim "Available commands: check, install, status, repair, memory, update-check, doctor, upgrade, uninstall, self-update, version, help."
  exit 1
}
