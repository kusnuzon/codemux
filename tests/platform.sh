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
  env -u TERMUX_VERSION "$@" bash -c '. lib/common.sh >/dev/null 2>&1; codemux_detect_platform'
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
MINPATH="$FVP:/system/bin:/bin"
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
[ "$(inst linux "$FVP2:/system/bin:/bin")" = pacman ] &&
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

printf '%d passed · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
