#!/usr/bin/env bash
# tests/platform.sh — the platform profile (PRD §21): detection, the package
# provider interface, and the android-only module skip on plain Linux.
# Runs anywhere: Termux is simulated with env, Linux is the CI reality.
# Summary line format is fixed: "N passed · M failed" (tools grep for it).

set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
pass=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SB="$BASE/codemux-platform-$$"
rm -rf "$SB"
mkdir -p "$SB/bin" "$SB/home" "$SB/state"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

# cm <platform> <cmd...> — run codemux with a forced platform profile.
cm() {
  local plat="$1"
  shift
  env CODEMUX_PLATFORM="$plat" CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
    HOME="$SB/home" CODEMUX_HOME="$SB/state" PREFIX="$SB/prefix" TMPDIR="$BASE" \
    bash bin/codemux "$@" 2>&1 || true
}

# 1. detection ---------------------------------------------------------------
# -u TERMUX_VERSION always: inside a real Termux shell it would leak into every
# case and the "linux" expectations would flip.
det() { # det <env assignments...> -> codemux_detect_platform
  env -u TERMUX_VERSION -u CODEMUX_PLATFORM "$@" bash -c '. lib/common.sh >/dev/null 2>&1; codemux_detect_platform'
}
[ "$(det TERMUX_VERSION=0.119 PREFIX=/data/data/com.termux/files/usr)" = termux ] &&
  ok "detect: TERMUX_VERSION -> termux" || bad "detect: TERMUX_VERSION"
[ "$(det PREFIX=/data/data/com.termux/files/usr)" = termux ] &&
  ok "detect: Termux PREFIX -> termux" || bad "detect: Termux PREFIX"
[ "$(det -u TERMUX_VERSION -u PREFIX)" = linux ] &&
  ok "detect: no Termux markers -> linux" || bad "detect: plain env"
[ "$(det PREFIX=/usr)" = linux ] &&
  ok "detect: foreign PREFIX -> linux" || bad "detect: foreign PREFIX"
[ "$(det CODEMUX_PLATFORM=linux TERMUX_VERSION=1)" = linux ] &&
  ok "detect: explicit override wins" || bad "detect: override"

# 2. provider: pkg_installed picks the right tool ----------------------------
# A minimal PATH: the host's real dpkg-query (Termux) or pacman must not answer
# instead of the fakes.
FVP="$SB/bin"
BASH_BIN="$(command -v bash)"
# ONLY the fakes: on Ubuntu /bin is a symlink to /usr/bin, so any real
# dpkg-query/pacman on the host path would answer before the fakes.
# core/ holds the few non-package tools the provider path itself needs
# (grep inside pkg_installed); everything else stays out.
mkdir -p "$SB/core"
ln -sf "$(command -v grep)" "$SB/core/grep"
MINPATH="$FVP:$SB/core"
printf '#!/bin/sh\necho dpkg-query "$@" >>"%s/calls"\nexit 1\n' "$SB" >"$FVP/dpkg-query"
printf '#!/bin/sh\necho pacman "$@" >>"%s/calls"\nexit 1\n' "$SB" >"$FVP/pacman"
printf '#!/bin/sh\necho rpm "$@" >>"%s/calls"\nexit 1\n' "$SB" >"$FVP/rpm"
chmod +x "$FVP"/dpkg-query "$FVP"/pacman "$FVP/rpm"
prov() { # prov <platform> -> which tool answered for pkg foo
  rm -f "$SB/calls"
  env -u TERMUX_VERSION CODEMUX_PLATFORM="$1" PATH="$MINPATH" "$BASH_BIN" -c \
    '. lib/common.sh >/dev/null 2>&1; pkg_installed foo; true'
  [ -f "$SB/calls" ] && head -n1 "$SB/calls" | cut -d' ' -f1 || echo none
}
[ "$(prov linux)" = dpkg-query ] &&
  ok "provider: linux prefers dpkg-query" || bad "provider: linux dpkg-query"
[ "$(prov termux)" = dpkg-query ] &&
  ok "provider: termux uses dpkg-query" || bad "provider: termux dpkg-query"
rm -f "$FVP/dpkg-query"
[ "$(prov linux)" = pacman ] &&
  ok "provider: linux falls back to pacman" || bad "provider: pacman fallback"
rm -f "$FVP/pacman" "$FVP/rpm"
[ "$(prov linux)" = none ] &&
  ok "provider: no manager -> binary check (no crash)" || bad "provider: no manager"

# 3. provider: codemux_pkg_install dispatches --------------------------------
# FVP2 holds ONLY pacman: with apt-get also present, the linux dispatcher
# prefers apt and the pacman branch would never be reached.
FVP2="$SB/bin2"
mkdir -p "$FVP2"
printf '#!/bin/sh\necho pacman "$@" >>"%s/calls"\nexit 0\n' "$SB" >"$FVP2/pacman"
printf '#!/bin/sh\necho apt-get "$@" >>"%s/calls"\nexit 0\n' "$SB" >"$FVP/apt-get"
chmod +x "$FVP2/pacman" "$FVP/apt-get"
inst() { # inst <platform> <PATH> -> first word the package tool was called with
  rm -f "$SB/calls"
  env -u TERMUX_VERSION CODEMUX_PLATFORM="$1" PATH="$2" "$BASH_BIN" -c \
    '. lib/common.sh >/dev/null 2>&1; codemux_pkg_install foo; true'
  [ -f "$SB/calls" ] && head -n1 "$SB/calls" | cut -d' ' -f1 || echo none
}
[ "$(inst linux "$FVP2")" = pacman ] &&
  ok "install: linux + pacman -> pacman -S" || bad "install: pacman dispatch"
grep -q -- '--noconfirm' "$SB/calls" 2>/dev/null &&
  ok "install: pacman runs unattended" || bad "install: pacman flags"
[ "$(inst linux "$MINPATH")" = apt-get ] &&
  ok "install: linux + apt-get -> apt path" || bad "install: apt dispatch"
[ "$(inst termux "$MINPATH")" = apt-get ] &&
  ok "install: termux -> apt path" || bad "install: termux apt"
# the legacy name still works (callers and older tests use it)
rm -f "$SB/calls"
env -u TERMUX_VERSION CODEMUX_PLATFORM=termux PATH="$MINPATH" "$BASH_BIN" -c \
  '. lib/common.sh >/dev/null 2>&1; codemux_apt_install foo; true'
[ -f "$SB/calls" ] && ok "install: codemux_apt_install still works" ||
  bad "install: legacy name broken"

# 4. check: android-only modules are SKIP on linux, probed on termux ---------
# Pin the components: the machine's saved choice (often just "pi") would leave
# v1/v2 out of the module list entirely. The selection lives in the state file,
# not in an env var, so write it into the sandbox state.
printf 'v1 v2\n' >"$SB/state/components"
json="$(cm linux check --json)"
st() { # st <json> <module> -> status
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for m in d["modules"]:
    if m["module"] == sys.argv[2]:
        print(m["status"])
        break
' "$1" "$2"
}
for m in mirror storage glibc; do
  [ "$(st "$json" "$m")" = SKIP ] &&
    ok "check: $m SKIP on linux" || bad "check: $m on linux ($(st "$json" "$m"))"
done
[ "$(st "$json" preflight)" != FAIL ] &&
  ok "check: preflight not FAIL on linux" || bad "check: preflight FAIL on linux"
json_t="$(cm termux check --json)"
[ "$(st "$json_t" mirror)" != SKIP ] &&
  ok "check: mirror probed on termux" || bad "check: mirror skipped on termux"
# Regression guard: a missing payload must read MISS on both platforms. The
# termux probe once lost its payload check and read WARN instead, which made a
# failed adapter run settle as DONE (adapter suite: "HTML not rejected").
[ "$(st "$json_t" opencode-v1)" = MISS ] &&
  ok "check: v1 MISS without payload (termux)" || bad "check: v1 termux ($(st "$json_t" v1))"
[ "$(st "$json_t" opencode-v2)" = MISS ] &&
  ok "check: v2 MISS without payload (termux)" || bad "check: v2 termux ($(st "$json_t" v2))"
[ "$(st "$json" opencode-v1)" = MISS ] &&
  ok "check: v1 MISS without payload (linux)" || bad "check: v1 linux ($(st "$json" v1))"
[ "$(st "$json" opencode-v2)" = MISS ] &&
  ok "check: v2 MISS without payload (linux)" || bad "check: v2 linux ($(st "$json" v2))"

# 5. install plan: rows stay complete, android-only shown as SKIP ------------
out="$(cm linux install --dry-run)"
rows="$(printf '%s\n' "$out" | grep -cE '^  [0-9]+/[0-9]+ ' || true)"
if [ "$rows" -ge 11 ]; then ok "plan: rows complete on linux ($rows)"; else bad "plan: rows=$rows"; fi
printf '%s\n' "$out" | grep -E '^  [0-9]+/[0-9]+ mirror ' | grep -q SKIP &&
  ok "plan: mirror row shows SKIP on linux" || bad "plan: mirror row"
printf '%s\n' "$out" | grep -E '^  [0-9]+/[0-9]+ pi ' | grep -q 'INSTALL\|ready' &&
  ok "plan: pi still actionable on linux" || bad "plan: pi row"
out="$(cm termux install --dry-run)"
printf '%s\n' "$out" | grep -E '^  [0-9]+/[0-9]+ mirror ' | grep -q SKIP &&
  bad "plan: mirror wrongly skipped on termux" ||
  ok "plan: mirror not skipped on termux"

# 6. native upstream install (linux profile, PRD §21.2) -----------------------
# Fake curl routes the releases list and the asset download to fixtures; the
# fixture tarball holds a fake `opencode` that prints the fixture version.
FIX="$SB/fix"
mkdir -p "$FIX"
printf '%s\n' '[{"tag_name":"v9.9.9"},{"tag_name":"v2.0.0"},{"tag_name":"v1.0.0"}]' >"$FIX/releases.json"
mkfix() { # mkfix <version> <tarball-name>
  local d="$SB/fix-$1"
  mkdir -p "$d"
  printf '#!/bin/sh\ncase "${1:-}" in --version) echo "%s" ;; esac\n' "$1" >"$d/opencode"
  chmod +x "$d/opencode"
  tar czf "$FIX/$2" -C "$d" opencode
}
mkfix 1.0.0 asset1.tar.gz
mkfix 2.0.0 asset2.tar.gz
cat >"$FVP/curl" <<'CUREOF'
#!/bin/sh
FIX="${ZEN_FIX:?}"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
case "$*" in
  *releases?per_page*) [ -n "$out" ] && cat "$FIX/releases.json" >"$out" || cat "$FIX/releases.json" ;;
  *releases/download/v1.0.0/*) [ -n "$out" ] && cat "$FIX/asset1.tar.gz" >"$out" || cat "$FIX/asset1.tar.gz" ;;
  *releases/download/v2.0.0/*) [ -n "$out" ] && cat "$FIX/asset2.tar.gz" >"$out" || cat "$FIX/asset2.tar.gz" ;;
  *) echo 404 >&2; exit 22 ;;
esac
printf '%s\n' "$*" | grep -o "https://[^ ]*" >>"${ZEN_SB:?}/curllog" || true
CUREOF
chmod +x "$FVP/curl"

nat() { # nat <major> <dest> <launcher> -> rc of codemux_native_install
  # NATPATH: fake curl first, host tools (uname/tar/jq) after — unlike the
  # provider tests above, this path does not need to hide dpkg-query.
  env -u TERMUX_VERSION CODEMUX_PLATFORM=linux PATH="$FVP:$PATH" HOME="$SB/home" \
    CODEMUX_HOME="$SB/state" ZEN_FIX="$FIX" ZEN_SB="$SB" "$BASH_BIN" -c '
. lib/common.sh >/dev/null 2>&1
. lib/native.sh >/dev/null 2>&1
codemux_native_install "$1" "$2" "$3"
' nat "$1" "$2" "$3"
}

touch "$SB/curllog"

V1D="$SB/prefix/share/opencode"
V1L="$SB/prefix/bin/opencode"
nat 1 "$V1D" "$V1L" && ok "native: v1 install rc=0" || bad "native: v1 install failed"
[ -x "$V1D/opencode" ] && ok "native: payload executable" || bad "native: payload missing"
[ "$(cat "$V1D/VERSION" 2>/dev/null)" = 1.0.0 ] &&
  ok "native: VERSION file written" || bad "native: VERSION file"
[ "$("$V1L" --version 2>/dev/null)" = 1.0.0 ] &&
  ok "native: launcher runs the payload" || bad "native: launcher broken"
grep -qF 'exec "' "$V1L" && ! grep -v '^#' "$V1L" | grep -q 'LD_PRELOAD\|glibc' &&
  ok "native: launcher is a plain exec (no shim)" || bad "native: launcher has shim logic"

# idempotent: a second run must not download the asset again (the cheap
# releases-list lookup still happens, only the payload download is skipped)
dl_before="$(grep -c '/download/' "$SB/curllog" || true)"
nat 1 "$V1D" "$V1L" && [ "$(grep -c '/download/' "$SB/curllog" || true)" = "$dl_before" ] &&
  ok "native: already-current install is idempotent" || bad "native: not idempotent"

# v2 resolves the v2.x tag, not v1
V2D="$SB/prefix/share/opencode-v2"
V2L="$SB/prefix/bin/opencode-v2"
nat 2 "$V2D" "$V2L" && [ "$(cat "$V2D/VERSION" 2>/dev/null)" = 2.0.0 ] &&
  ok "native: v2 resolves its own major" || bad "native: v2 tag resolution"

# probe sees the native install as OK
probe_v1="$(env -u TERMUX_VERSION CODEMUX_PLATFORM=linux PATH="$FVP:$PATH" HOME="$SB/home" \
  CODEMUX_HOME="$SB/state" PREFIX="$SB/prefix" ZEN_FIX="$FIX" ZEN_SB="$SB" "$BASH_BIN" -c '
. lib/common.sh >/dev/null 2>&1
. lib/modules/v1.sh >/dev/null 2>&1
m_v1_probe
printf "%s" "$PROBE"
')"
[ "$probe_v1" = OK ] && ok "native: v1 probe OK on linux" || bad "native: v1 probe=$probe_v1"

printf '%d passed · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
