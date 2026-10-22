#!/data/data/com.termux/files/usr/bin/bash
# tests/maintenance.sh — uji update-check, doctor, upgrade, uninstall (M5).
# Sandbox penuh: HOME, PREFIX, CODEMUX_HOME sendiri. Sistem TIDAK disentuh.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX_ROOT="$BASE/codemux-mt-$$"
rm -rf "$SANDBOX_ROOT"
mkdir -p "$SANDBOX_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

new_sandbox() {
  local name="$1" d="$SANDBOX_ROOT/$1"
  rm -rf "$d"
  mkdir -p "$d/home" "$d/state" "$d/prefix/bin" "$d/prefix/share"
  printf '%s' "$d"
}

run_cm() { # <sandbox> <perintah...>
  local sb="$1"
  shift
  env HOME="$sb/home" CODEMUX_HOME="$sb/state" PREFIX="$sb/prefix" TMPDIR="$BASE" \
    CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
    CODEMUX_FAKE_LOCAL_CODEMUX=0.4.0 CODEMUX_FAKE_LOCAL_V1=1.19.3 CODEMUX_FAKE_LOCAL_V2=2.1.2 \
    CODEMUX_FAKE_TAG_CODEMUX=v0.5.0 \
    CODEMUX_FAKE_TAG_OPENCODE_TERMUX=opencode-termux-1.20.0 \
    CODEMUX_FAKE_TAG_OPENCODE_TERMUX_V2=opencode-termux-v2-2.2.0 \
    bash "$ROOT/bin/codemux" "$@"
}

# =============================================================================
# 1. update-check: mendeteksi 3 komponen baru + cache 24 jam
# =============================================================================
SB="$(new_sandbox update)"
run_cm "$SB" update-check --json >"$SB/uc.json" 2>"$SB/uc.err"
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/uc.json"))
assert d["update"] == 3, d
st = {k["nama"]: k["status"] for k in d["komponen"]}
assert st["codemux"] == "update", st
assert st["opencode-v1"] == "update", st
assert st["opencode-v2"] == "update", st
PY
then
  ok "update-check: 3 komponen terdeteksi baru"
else
  bad "update-check: deteksi salah ($(cat "$SB/uc.err" | head -3))"
fi
[ -f "$SB/state/update-cache.tsv" ] && ok "update-check: cache ditulis" || bad "update-check: cache tidak ada"

# check: modul updatecache harus OK
run_cm "$SB" check --json >"$SB/check.json" 2>/dev/null || true
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/check.json"))
st = {m["modul"]: m["status"] for m in d["modul"]}
assert st["update-cache"] == "OK", st["update-cache"]
PY
then
  ok "check: update-cache OK setelah cek"
else
  bad "check: update-cache belum OK"
fi

# versi sama → tidak ada update
env HOME="$SB/home" CODEMUX_HOME="$SB/state" PREFIX="$SB/prefix" TMPDIR="$BASE" \
  CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
  CODEMUX_FAKE_LOCAL_CODEMUX=0.9.9 CODEMUX_FAKE_LOCAL_V1=1.20.0 CODEMUX_FAKE_LOCAL_V2=2.2.0 \
  CODEMUX_FAKE_TAG_CODEMUX=v0.9.9 \
  CODEMUX_FAKE_TAG_OPENCODE_TERMUX=opencode-termux-1.20.0 \
  CODEMUX_FAKE_TAG_OPENCODE_TERMUX_V2=opencode-termux-v2-2.2.0 \
  bash "$ROOT/bin/codemux" update-check --json >"$SB/uc2.json" 2>/dev/null
if python3 - <<PY 2>/dev/null
import json
d = json.load(open("$SB/uc2.json"))
assert d["update"] == 0, d
PY
then
  ok "update-check: versi sama → 0 update"
else
  bad "update-check: salah menganggap ada update"
fi

# =============================================================================
# 2. upgrade --dry-run tidak mengubah apa pun
# =============================================================================
SB2="$(new_sandbox dry)"
run_cm "$SB2" upgrade --dry-run >"$SB2/out.log" 2>&1
if grep -q 'dry-run' "$SB2/out.log" && [ ! -f "$SB2/home/.bashrc" ]; then
  ok "upgrade --dry-run: rencana saja, tanpa perubahan"
else
  bad "upgrade --dry-run mengubah sistem"
fi

# =============================================================================
# 3. upgrade --only launcher: adopsi blok lama + wrapper digest
# =============================================================================
SB3="$(new_sandbox up)"
cat >"$SB3/home/.bashrc" <<'EOS'
# bashrc lama
export EDITOR="nano"

# --- banner + menu launcher (2026-10-22) ---
_oc_banner() { printf 'lama\n'; }
_oc_launcher() { _oc_banner; }
if [ -z "${OPENCODE_NO_AUTO:-}" ]; then _oc_launcher; fi
EOS
run_cm "$SB3" upgrade --yes --only launcher >"$SB3/out.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c 'codemux:launcher begin' "$SB3/home/.bashrc")" -eq 1 ] &&
  grep -q '_oc_refresh_digest()' "$SB3/home/.bashrc" && bash -n "$SB3/home/.bashrc" 2>/dev/null; then
  ok "upgrade --only launcher: blok baru + wrapper, valid"
else
  bad "upgrade --only launcher gagal (rc=$rc)"
  tail -5 "$SB3/out.log" | sed 's/^/     /'
fi
grep -q 'export EDITOR="nano"' "$SB3/home/.bashrc" &&
  ok "upgrade: isi bashrc lain dipertahankan" || bad "upgrade: isi bashrc hilang"

# =============================================================================
# 4. uninstall: payload dilepas, memori & bashrc pribadi tetap
# =============================================================================
SB4="$(new_sandbox un)"
mkdir -p "$SB4/prefix/share/opencode" "$SB4/prefix/share/opencode-v2"
printf 'v1 payload\n' >"$SB4/prefix/share/opencode/opencode.real"
printf 'v2 payload\n' >"$SB4/prefix/share/opencode-v2/opencode.real"
printf 'launcher v1\n' >"$SB4/prefix/bin/opencode"
printf 'launcher v2\n' >"$SB4/prefix/bin/opencode-v2"
mkdir -p "$SB4/home/.config/opencode"
printf -- '- MEMORY-PRIBADI\n' >"$SB4/home/.config/opencode/MEMORY.md"
cat >"$SB4/home/.bashrc" <<'EOS'
export EDITOR="nano"
# codemux:launcher begin  (dikelola codemux)
_oc_banner() { :; }
# codemux:launcher end
# codemux:memory begin  (dikelola codemux)
_oc_refresh_digest() { :; }
# codemux:memory end
alias ll='ls -l'
EOS
mod_before="$(cksum <"$SB4/home/.config/opencode/MEMORY.md")"
run_cm "$SB4" uninstall --yes >"$SB4/out.log" 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then ok "uninstall: selesai (exit 0)"; else
  bad "uninstall: exit $rc"; tail -6 "$SB4/out.log" | sed 's/^/     /'
fi
if [ ! -e "$SB4/prefix/share/opencode" ] && [ ! -e "$SB4/prefix/share/opencode-v2" ] &&
  [ ! -e "$SB4/prefix/bin/opencode" ] && [ ! -e "$SB4/prefix/bin/opencode-v2" ]; then
  ok "uninstall: payload V1/V2 dilepas dari PREFIX"
else
  bad "uninstall: payload masih ada"
fi
bak_dir="$(ls -d "$SB4/state"/backup/*-uninstall 2>/dev/null | head -1)"
if [ -n "$bak_dir" ] && [ -f "$bak_dir/share-opencode/opencode.real" ]; then
  ok "uninstall: payload disimpan di backup (bisa dipulihkan)"
else
  bad "uninstall: payload tidak di-backup"
fi
if ! grep -q 'codemux:launcher' "$SB4/home/.bashrc" &&
  ! grep -q 'codemux:memory' "$SB4/home/.bashrc" &&
  grep -q 'export EDITOR' "$SB4/home/.bashrc" &&
  grep -q "alias ll" "$SB4/home/.bashrc" && bash -n "$SB4/home/.bashrc" 2>/dev/null; then
  ok "uninstall: blok codemux dilepas, isi pribadi utuh"
else
  bad "uninstall: .bashrc tidak sebagaimana mestinya"
fi
if [ "$(cksum <"$SB4/home/.config/opencode/MEMORY.md")" = "$mod_before" ]; then
  ok "uninstall: MEMORY.md tidak disentuh"
else
  bad "uninstall: MEMORY.md berubah"
fi

# =============================================================================
# 5. doctor tidak crash & memberi bagian tambahan
# =============================================================================
SB5="$(new_sandbox doc)"
run_cm "$SB5" doctor >"$SB5/out.log" 2>&1 || true
if grep -q 'Pemeriksaan tambahan' "$SB5/out.log" && grep -q 'LD_PRELOAD' "$SB5/out.log"; then
  ok "doctor: bagian pemeriksaan tambahan tampil"
else
  bad "doctor: keluaran tidak lengkap"
fi

rm -rf "$SANDBOX_ROOT"
printf '\n%s lulus · %s gagal\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
