#!/data/data/com.termux/files/usr/bin/bash
# tests/smoke.sh — quick test that does not touch the system.
# shellcheck shell=bash
set -Eeuo pipefail
export CODEMUX_ALLOW_NONANDROID=1  # so it can run in CI (not Android)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
pass=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# 1. syntax of every script
for f in bin/codemux lib/*.sh lib/modules/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "syntax $f"; else bad "syntax $f"; fi
done

# 2. help
if bash bin/codemux help | grep -q 'usage:'; then ok "help"; else bad "help"; fi

# 3. version
out="$(bash bin/codemux version)"
case "$out" in codemux*) ok "version" ;; *) bad "version" ;; esac

# 4. check: 12 module rows
rows="$(bash bin/codemux check 2>/dev/null | grep -c '^\[' || true)"
if [ "$rows" -eq 13 ]; then ok "check rows ($rows)"; else bad "check rows ($rows, expected 13)"; fi

# 5. check --json valid (the check exit code is ignored: MISS/WARN is normal)
json_out="$(bash bin/codemux check --json 2>/dev/null || true)"
if printf '%s' "$json_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["codemux"] == "codemux", d
assert len(d["modul"]) == 13, len(d["modul"])
r = d["ringkasan"]
assert r["ok"] + r["warn"] + r["miss"] + r["fail"] == 13, r
'; then
  ok "check --json"
else
  bad "check --json"
fi

# 6. install --dry-run: plan for 5 modules, changes nothing
out="$(bash bin/codemux install --dry-run 2>&1 || true)"
rows="$(printf '%s\n' "$out" | grep -cE '^  [0-9]+/11 ' || true)"
if [ "$rows" -eq 11 ] && printf '%s' "$out" | grep -q 'dry-run'; then
  ok "install --dry-run (11 modules)"
else
  bad "install --dry-run (plan rows=$rows)"
fi

# 7. status & repair --dry-run must not crash
if bash bin/codemux status >/dev/null 2>&1; then ok "status"; else bad "status"; fi
if bash bin/codemux repair --dry-run >/dev/null 2>&1; then ok "repair --dry-run"; else bad "repair --dry-run"; fi

# 8. an unknown command must fail cleanly (not crash)
if bash bin/codemux bogus-command >/dev/null 2>&1; then
  bad "unknown command should exit != 0"
else
  ok "unknown command rejected cleanly"
fi
out="$(bash bin/codemux upgrade --dry-run 2>&1 || true)"
case "$out" in
  *"apt-get update"*) ok "upgrade --dry-run (plan)" ;;
  *) bad "upgrade --dry-run" ;;
esac

# 9. shellcheck when available
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning bin/codemux lib/*.sh lib/modules/*.sh; then
    ok "shellcheck"
  else
    bad "shellcheck"
  fi
else
  printf 'skip shellcheck (not installed)\n'
fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
