#!/data/data/com.termux/files/usr/bin/bash
# tests/launcher-memory.sh — uji modul launcher, dotfiles, memory (M4).
# Sandbox penuh: HOME, PREFIX, CODEMUX_HOME sendiri. Sistem TIDAK disentuh.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX_ROOT="$BASE/codemux-lm-$$"
rm -rf "$SANDBOX_ROOT"
mkdir -p "$SANDBOX_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- fixture mekanisme memori (pengganti unduhan dari GitHub) ----------------
FIXTURE="$SANDBOX_ROOT/fixture"
mkdir -p "$FIXTURE"
cat >"$FIXTURE/plugin.js" <<'EOS'
// memory.js (fixture uji)
export default { id: "memory", setup() {} };
EOS
cat >"$FIXTURE/digest.py" <<'EOS'
#!/usr/bin/env python3
import os
base = os.path.join(os.path.expanduser("~"), ".config", "opencode")
os.makedirs(base, exist_ok=True)
with open(os.path.join(base, "RECENT.md"), "w", encoding="utf-8") as fh:
    fh.write("# RECENT\n\n- dibuat oleh digest fixture\n")
EOS
chmod 700 "$FIXTURE/digest.py"

new_sandbox() {
  local name="$1" d="$SANDBOX_ROOT/$1"
  rm -rf "$d"
  mkdir -p "$d/home" "$d/state" "$d/prefix"
  printf '%s' "$d"
}

run_cm() { # <sandbox> <perintah...>
  local sb="$1"
  shift
  env HOME="$sb/home" CODEMUX_HOME="$sb/state" PREFIX="$sb/prefix" TMPDIR="$BASE" \
    CODEMUX_ALLOW_NONANDROID=1 \
    CODEMUX_MEMORY_PLUGIN_URL="$FIXTURE/plugin.js" \
    CODEMUX_MEMORY_DIGEST_URL="$FIXTURE/digest.py" \
    bash "$ROOT/bin/codemux" "$@"
}

SKIP_ALL_BUT_M4="deps,mirror,storage,toolset,glibc,v1,v2"
SKIP_ONLY_LAUNCHER="deps,mirror,storage,toolset,glibc,v1,v2,dotfiles,memory"

# =============================================================================
# 1. Fresh: seluruh modul M4 dipasang dari nol
# =============================================================================
SB="$(new_sandbox fresh)"
run_cm "$SB" install --skip "$SKIP_ALL_BUT_M4" >"$SB/install.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "fresh: install selesai (exit 0)"; else
  bad "fresh: install exit $rc"
  sed 's/^/     /' "$SB/install.log" | tail -20
fi

rc_file="$SB/home/.bashrc"
if bash -n "$rc_file" 2>/dev/null; then ok "fresh: .bashrc lolos bash -n"; else bad "fresh: .bashrc rusak"; fi
if [ "$(grep -c 'codemux:launcher begin' "$rc_file")" -eq 1 ] &&
  [ "$(grep -c 'codemux:launcher end' "$rc_file")" -eq 1 ]; then
  ok "fresh: penanda blok launcher tepat satu pasang"
else
  bad "fresh: penanda blok launcher tidak tepat"
fi
if grep -q '_oc_banner()' "$rc_file" && grep -q '_oc_menu_loop()' "$rc_file"; then
  ok "fresh: fungsi banner + menu ada"
else
  bad "fresh: fungsi banner/menu tidak lengkap"
fi
if grep -q '_oc_refresh_digest()' "$rc_file"; then ok "fresh: wrapper digest ada"; else bad "fresh: wrapper digest tidak ada"; fi

[ -f "$SB/home/.bash_profile" ] && ok "fresh: .bash_profile dibuat" || bad "fresh: .bash_profile tidak ada"
[ -f "$SB/home/.hushlogin" ] && ok "fresh: .hushlogin dibuat" || bad "fresh: .hushlogin tidak ada"

cfg="$SB/home/.config/opencode/opencode.jsonc"
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$cfg"))
ins = d["instructions"]
assert any(p.endswith("MEMORY.md") for p in ins), ins
assert any(p.endswith("RECENT.md") for p in ins), ins
PY
then
  ok "fresh: opencode.jsonc valid + instructions lengkap"
else
  bad "fresh: opencode.jsonc tidak valid / entri kurang"
fi

if grep -q 'Memori lintas sesi' "$SB/home/.config/opencode/MEMORY.md" 2>/dev/null; then
  ok "fresh: MEMORY.md dari template"
else
  bad "fresh: MEMORY.md tidak dibuat dari template"
fi
[ -f "$SB/home/.config/opencode/RECENT.md" ] && ok "fresh: RECENT.md dibuat" || bad "fresh: RECENT.md tidak ada"
[ -s "$SB/home/.config/opencode/plugins/memory.js" ] && ok "fresh: plugins/memory.js terunduh" || bad "fresh: plugins/memory.js tidak ada"
[ -x "$SB/home/.config/opencode/bin/session-digest.py" ] && ok "fresh: session-digest.py executable" || bad "fresh: session-digest.py tidak executable"

# check: tiga modul M4 harus OK
if run_cm "$SB" check --json >"$SB/check.json" 2>/dev/null; then :; fi
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/check.json"))
st = {m["modul"]: m["status"] for m in d["modul"]}
for k in ("launcher", "dotfiles", "memory"):
    assert st[k] == "OK", (k, st[k])
PY
then
  ok "fresh: check → launcher/dotfiles/memory OK"
else
  bad "fresh: check masih tidak OK ($(python3 -c '
import json;d=json.load(open("'"$SB"'/check.json"));print({m["modul"]:m["status"] for m in d["modul"]})' 2>/dev/null))"
fi

if run_cm "$SB" memory >"$SB/memory.log" 2>&1 && grep -q 'ingatan lintas sesi' "$SB/memory.log" &&
  grep -q 'MEMORY.md' "$SB/memory.log"; then
  ok "fresh: codemux memory menampilkan status"
else
  bad "fresh: codemux memory gagal"
fi

# idempoten: jalankan install lagi, tidak boleh menduplikasi
run_cm "$SB" install --skip "$SKIP_ALL_BUT_M4" >"$SB/install2.log" 2>&1
if [ "$(grep -c 'codemux:launcher begin' "$rc_file")" -eq 1 ] &&
  [ "$(grep -c '_oc_refresh_digest()' "$rc_file")" -eq 1 ] &&
  [ "$(grep -c 'RECENT.md' "$cfg")" -eq 1 ] && bash -n "$rc_file" 2>/dev/null; then
  ok "fresh: install kedua idempoten (tidak duplikat)"
else
  bad "fresh: install kedua menduplikasi blok/entri"
fi

# =============================================================================
# 2. Data pribadi tidak boleh ditimpa; config kurang entri → dilengkapi
# =============================================================================
SB2="$(new_sandbox personal)"
mkdir -p "$SB2/home/.config/opencode"
printf '# MEMORY pribadi\n- PRIBADI-JANGAN-HILANG\n' >"$SB2/home/.config/opencode/MEMORY.md"
cat >"$SB2/home/.config/opencode/opencode.jsonc" <<EOS
{
  "\$schema": "https://opencode.ai/config.json",
  "instructions": [
    "$SB2/home/.config/opencode/MEMORY.md"
  ]
}
EOS
before="$(wc -c <"$SB2/home/.config/opencode/MEMORY.md")"

run_cm "$SB2" install --skip "$SKIP_ALL_BUT_M4" >"$SB2/install.log" 2>&1
rc=$?
after="$(wc -c <"$SB2/home/.config/opencode/MEMORY.md")"

if [ "$rc" -eq 0 ] && [ "$before" -eq "$after" ] &&
  grep -q 'PRIBADI-JANGAN-HILANG' "$SB2/home/.config/opencode/MEMORY.md"; then
  ok "personal: MEMORY.md tidak ditimpa"
else
  bad "personal: MEMORY.md berubah/tertimpa (rc=$rc)"
fi

cfg2="$SB2/home/.config/opencode/opencode.jsonc"
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$cfg2"))
ins = d["instructions"]
assert len(ins) == 2, ins
assert ins[0].endswith("MEMORY.md") and ins[1].endswith("RECENT.md"), ins
PY
then
  ok "personal: config dilengkapi RECENT.md, entri lama tetap"
else
  bad "personal: config tidak dilengkapi dengan benar"
fi

# =============================================================================
# 3. Adopsi blok lama tanpa penanda
# =============================================================================
SB3="$(new_sandbox legacy)"
cat >"$SB3/home/.bashrc" <<'EOS'
# ~/.bashrc lama
export EDITOR="nano"

# --- banner + menu launcher (2026-10-22) ---
_oc_banner() { printf 'banner lama\n'; }
_oc_launcher() { _oc_banner; }
if [ -z "${OPENCODE_NO_AUTO:-}" ]; then
  _oc_launcher
fi
EOS
run_cm "$SB3" install --skip "$SKIP_ONLY_LAUNCHER" >"$SB3/install.log" 2>&1
rc=$?
rc3="$SB3/home/.bashrc"

if [ "$rc" -eq 0 ]; then ok "legacy: install launcher selesai"; else bad "legacy: install exit $rc"; fi
if ! grep -q '^# --- banner + menu launcher' "$rc3"; then
  ok "legacy: blok lama dibuang"
else
  bad "legacy: blok lama masih ada"
fi
if [ "$(grep -c '_oc_launcher()' "$rc3")" -eq 1 ] &&
  [ "$(grep -c 'codemux:launcher begin' "$rc3")" -eq 1 ] &&
  bash -n "$rc3" 2>/dev/null; then
  ok "legacy: blok baru tunggal + valid"
else
  bad "legacy: adopsi menghasilkan blok ganda/rusak"
fi
if grep -q 'export EDITOR="nano"' "$rc3"; then
  ok "legacy: isi non-launcher dipertahankan"
else
  bad "legacy: isi lama hilang"
fi

# =============================================================================
# 4. bashrc rusak → dipulihkan, tidak ditinggalkan dalam keadaan rusak
# =============================================================================
SB4="$(new_sandbox broken)"
printf 'if [ ; then\n' >"$SB4/home/.bashrc"
before_sum="$(cksum <"$SB4/home/.bashrc")"
run_cm "$SB4" install --skip "$SKIP_ONLY_LAUNCHER" >"$SB4/install.log" 2>&1 || true
if [ "$(cksum <"$SB4/home/.bashrc")" = "$before_sum" ]; then
  ok "broken: bashrc rusak tidak diubah (gagal rapi, bukan makin rusak)"
else
  if bash -n "$SB4/home/.bashrc" 2>/dev/null && grep -q 'codemux:launcher begin' "$SB4/home/.bashrc"; then
    ok "broken: bashrc rusak diperbaiki jadi valid"
  else
    bad "broken: bashrc ditinggalkan dalam keadaan rusak"
  fi
fi

rm -rf "$SANDBOX_ROOT"
printf '\n%s lulus · %s gagal\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
