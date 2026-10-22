#!/data/data/com.termux/files/usr/bin/bash
# tests/smoke.sh — uji cepat tanpa menyentuh sistem.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
pass=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# 1. sintaks semua skrip
for f in bin/codemux lib/*.sh lib/modules/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "syntax $f"; else bad "syntax $f"; fi
done

# 2. help
if bash bin/codemux help | grep -q 'penggunaan:'; then ok "help"; else bad "help"; fi

# 3. version
out="$(bash bin/codemux version)"
case "$out" in codemux*) ok "version" ;; *) bad "version" ;; esac

# 4. check: 12 baris modul
rows="$(bash bin/codemux check 2>/dev/null | grep -c '^\[' || true)"
if [ "$rows" -eq 12 ]; then ok "check rows ($rows)"; else bad "check rows ($rows, harus 12)"; fi

# 5. check --json valid (exit code check diabaikan: MISS/WARN wajar)
json_out="$(bash bin/codemux check --json 2>/dev/null || true)"
if printf '%s' "$json_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["codemux"] == "codemux", d
assert len(d["modul"]) == 12, len(d["modul"])
r = d["ringkasan"]
assert r["ok"] + r["warn"] + r["miss"] + r["fail"] == 12, r
'; then
  ok "check --json"
else
  bad "check --json"
fi

# 6. perintah belum tersedia harus gagal rapi (bukan crash)
if bash bin/codemux install >/dev/null 2>&1; then
  bad "install seharusnya belum tersedia"
else
  ok "install belum tersedia (exit != 0)"
fi

# 7. shellcheck kalau tersedia
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning bin/codemux lib/*.sh lib/modules/*.sh; then
    ok "shellcheck"
  else
    bad "shellcheck"
  fi
else
  printf 'skip shellcheck (tidak terpasang)\n'
fi

printf '\n%s lulus · %s gagal\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
