#!/usr/bin/env bash
# tests/skills.sh — the skills module: managed skill sync + python deps.
# Full sandbox: dedicated skills dir, fake python3/pip/curl/chromium. The real
# pip, network and chromium are never touched.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX_ROOT="$BASE/codemux-skills-$$"
rm -rf "$SANDBOX_ROOT"
trap 'rm -rf "$SANDBOX_ROOT"' EXIT
mkdir -p "$SANDBOX_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

new_sandbox() {
  local d="${SANDBOX_ROOT:?}/$1"
  rm -rf "$d"
  mkdir -p "$d/skills" "$d/prefix/bin" "$d/prefix/share"
  printf '%s' "$d"
}

# Fake python3: `-c "import <mod>"` succeeds iff $SB/modules/<mod> exists.
# Anything else is out of scope for this suite.
fake_python3() { # <sandbox>
  local sb="$1"
  local f="$sb/prefix/bin/python3"
  mkdir -p "$sb/prefix/bin" "$sb/modules"
  cat >"$f" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-c" ]; then
  mod="\$(printf '%s' "\$2" | sed -n 's/^import \\([A-Za-z_][A-Za-z0-9_]*\\).*/\\1/p')"
  if [ -n "\$mod" ] && [ -f "$sb/modules/\$mod" ]; then exit 0; fi
  exit 1
fi
exit 0
EOF
  chmod +x "$f"
}

# Load the module directly with stubs for the shared helpers it may call.
probe() { # <sandbox> [codemux_root]
  local sb="$1" root="${2:-$ROOT}"
  (
    CODEMUX_ROOT="$root" CODEMUX_SKILLS_DIR="$sb/skills"
    CODEMUX_ZPLAYWRIGHT_INSTALL="https://example.invalid/install.sh"
    export CODEMUX_ROOT CODEMUX_SKILLS_DIR CODEMUX_ZPLAYWRIGHT_INSTALL
    PATH="$sb/prefix/bin:$PATH"
    export PATH
    codemux_spin_msg() { :; }
    # shellcheck source=/dev/null
    . "$ROOT/lib/modules/skills.sh"
    m_skills_probe
    printf '%s|%s' "$PROBE" "$NOTE"
  ) 2>/dev/null
}

apply() { # <sandbox> [codemux_root]
  local sb="$1" root="${2:-$ROOT}"
  (
    CODEMUX_ROOT="$root" CODEMUX_SKILLS_DIR="$sb/skills"
    CODEMUX_ZPLAYWRIGHT_INSTALL="https://example.invalid/install.sh"
    export CODEMUX_ROOT CODEMUX_SKILLS_DIR CODEMUX_ZPLAYWRIGHT_INSTALL
    PATH="$sb/prefix/bin:$PATH"
    export PATH
    codemux_spin_msg() { :; }
    # shellcheck source=/dev/null
    . "$ROOT/lib/modules/skills.sh"
    m_skills_apply
    printf '%s|%s' "$?" "$APPLY_NOTE"
  ) 2>/dev/null
}

# =============================================================================
# 1. fresh sandbox: everything missing -> MISS with pip + skill entries
# =============================================================================
SB="$(new_sandbox fresh)"
fake_python3 "$SB"
out="$(probe "$SB")"
case "$out" in
  "MISS|"*skill:agent-browser*skill:webapp-testing*pip:pyee*pip:playwright*) ok "fresh probe is MISS and lists every gap" ;;
  *) bad "fresh probe unexpected: $out" ;;
esac

# =============================================================================
# 2. apply with python deps present: syncs both managed skills
# =============================================================================
touch "$SB/modules/pyee" "$SB/modules/playwright"
printf '#!/usr/bin/env sh\nexit 0\n' >"$SB/prefix/bin/chromium-browser"
chmod +x "$SB/prefix/bin/chromium-browser"
out="$(apply "$SB")"
case "$out" in
  "0|"*"skill:agent-browser"*"skill:webapp-testing"*) ok "apply syncs both skills" ;;
  *) bad "apply unexpected: $out" ;;
esac
if grep -qF "managed-by: codemux skills module" "$SB/skills/agent-browser/SKILL.md" &&
  cmp -s "$ROOT/skills/agent-browser/SKILL.md" "$SB/skills/agent-browser/SKILL.md" &&
  cmp -s "$ROOT/skills/webapp-testing/SKILL.md" "$SB/skills/webapp-testing/SKILL.md"; then
  ok "installed copies match the canonical files"
else
  bad "installed copies differ from canonical"
fi
out="$(probe "$SB")"
case "$out" in "OK|"*) ok "probe is OK after apply" ;; *) bad "probe after apply: $out" ;; esac

# =============================================================================
# 3. drift: an edited installed copy is detected and re-synced (with backup)
# =============================================================================
printf 'tampered\n' >>"$SB/skills/agent-browser/SKILL.md"
out="$(probe "$SB")"
case "$out" in "MISS|"*"skill:agent-browser"*) ok "drift detected" ;; *) bad "drift not detected: $out" ;; esac
out="$(apply "$SB")"
case "$out" in "0|"*"skill:agent-browser"*) ok "apply re-syncs drifted skill" ;; *) bad "re-sync unexpected: $out" ;; esac
ls "$SB/skills/agent-browser"/SKILL.md.bak-* >/dev/null 2>&1 &&
  cmp -s "$ROOT/skills/agent-browser/SKILL.md" "$SB/skills/agent-browser/SKILL.md" &&
  ok "drifted copy backed up and restored" ||
  bad "backup/restore of drifted copy failed"

# =============================================================================
# 4. foreign copy without the marker is replaced, not trusted
# =============================================================================
mkdir -p "$SB/skills/webapp-testing"
printf 'node playwright instructions\n' >"$SB/skills/webapp-testing/SKILL.md"
out="$(probe "$SB")"
case "$out" in "MISS|"*"skill:webapp-testing"*) ok "foreign copy (no marker) detected" ;; *) bad "foreign copy not detected: $out" ;; esac
apply "$SB" >/dev/null
grep -qF "managed-by: codemux skills module" "$SB/skills/webapp-testing/SKILL.md" &&
  ok "foreign copy replaced by managed one" ||
  bad "foreign copy survived apply"

# =============================================================================
# 5. missing canonical file is reported (fake CODEMUX_ROOT)
# =============================================================================
FAKE="$SANDBOX_ROOT/fakeroot"
mkdir -p "$FAKE/skills/agent-browser"
cp "$ROOT/skills/agent-browser/SKILL.md" "$FAKE/skills/agent-browser/"
out="$(probe "$SB" "$FAKE")"
case "$out" in
  "MISS|"*"skill:webapp-testing (canonical file missing)"*) ok "missing canonical file reported" ;;
  *) bad "missing canonical not reported: $out" ;;
esac

# =============================================================================
# 6. pip path: missing pyee -> apply installs it via pip (fake), playwright
#    missing -> apply calls the zplaywright installer (fake curl, no network)
# =============================================================================
SB2="$(new_sandbox deps)"
fake_python3 "$SB2"   # no module markers: both imports fail
cat >"$SB2/prefix/bin/pip" <<EOF
#!/usr/bin/env bash
# last -c style arg wins; tests only pass "pyee"
for a in "\$@"; do case "\$a" in pyee) touch "$SB2/modules/pyee" ;; esac; done
exit 0
EOF
chmod +x "$SB2/prefix/bin/pip"
cat >"$SB2/prefix/bin/curl" <<EOF
#!/usr/bin/env bash
touch "$SB2/curl-called" "$SB2/modules/playwright"
exit 0
EOF
chmod +x "$SB2/prefix/bin/curl"
out="$(apply "$SB2")"
[ -f "$SB2/curl-called" ] && ok "zplaywright installer invoked when playwright missing" ||
  bad "zplaywright installer not invoked: $out"
[ -f "$SB2/modules/pyee" ] && ok "pip install pyee invoked when missing" ||
  bad "pip not invoked: $out"
case "$out" in "0|"*) ok "apply succeeds with fake installers" ;; *) bad "apply rc/note: $out" ;; esac
out="$(probe "$SB2")"
case "$out" in "OK|"*) ok "probe OK after fake installs" ;; *) bad "probe after fake installs: $out" ;; esac

printf '\n%s: %d passed · %d failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
