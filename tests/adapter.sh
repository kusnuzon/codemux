#!/data/data/com.termux/files/usr/bin/bash
# tests/adapter.sh — uji adapter V1/V2 (unduh → jalankan terpisah → verifikasi).
# Sandbox penuh: PREFIX, HOME, CODEMUX_HOME sendiri; hulu dipalsukan.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
BASH_BIN="$(command -v bash)"
SANDBOX="$BASE/codemux-adapter-$$"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/state" "$SANDBOX/prefix/bin" \
  "$SANDBOX/prefix/share" "$SANDBOX/upstream"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- hulu palsu --------------------------------------------------------------
cat >"$SANDBOX/upstream/v1.sh" <<'EOS'
#!/usr/bin/env bash
sleep "${CM_TEST_SLEEP:-0}"
[ -n "${CM_TEST_FAIL:-}" ] && exit 3
mkdir -p "$PREFIX/share/opencode" "$PREFIX/bin"
printf '#!/usr/bin/env bash\necho 1.19.3\n' >"$PREFIX/share/opencode/opencode.real"
printf '#!/usr/bin/env bash\necho 1.19.3\n' >"$PREFIX/bin/opencode"
chmod 700 "$PREFIX/share/opencode/opencode.real" "$PREFIX/bin/opencode"
exit 0
EOS

cat >"$SANDBOX/upstream/v2.sh" <<'EOS'
#!/usr/bin/env bash
sleep "${CM_TEST_SLEEP:-0}"
[ -n "${CM_TEST_FAIL:-}" ] && exit 3
mkdir -p "$PREFIX/share/opencode-v2/lib/compat" "$PREFIX/bin"
printf '#!/usr/bin/env bash\necho 2.1.2\n' >"$PREFIX/share/opencode-v2/opencode.real"
chmod 700 "$PREFIX/share/opencode-v2/opencode.real"
printf '2.1.2\n' >"$PREFIX/share/opencode-v2/VERSION"
: >"$PREFIX/share/opencode-v2/lib/compat/libc.so"
printf '#!/usr/bin/env bash\necho 2.1.2\n' >"$PREFIX/bin/opencode-v2"
chmod 700 "$PREFIX/bin/opencode-v2"
exit 0
EOS

# alat sistem palsu supaya hasil deterministik
cat >"$SANDBOX/bin/apt-mark" <<'EOS'
#!/usr/bin/env bash
echo opencode
EOS
cat >"$SANDBOX/bin/dpkg-query" <<'EOS'
#!/usr/bin/env bash
echo "deinstall ok config-files"
EOS
for f in "$SANDBOX/upstream/v1.sh" "$SANDBOX/upstream/v2.sh" \
  "$SANDBOX/bin/apt-mark" "$SANDBOX/bin/dpkg-query"; do
  sed -i "1s|.*|#!$BASH_BIN|" "$f"
  chmod 700 "$f"
done

export CODEMUX_ALLOW_NONANDROID=1
export HOME="$SANDBOX/home"
export CODEMUX_HOME="$SANDBOX/state"
export PREFIX="$SANDBOX/prefix"
export CODEMUX_UPSTREAM_V1="$SANDBOX/upstream/v1.sh"
export CODEMUX_UPSTREAM_V2="$SANDBOX/upstream/v2.sh"
export PATH="$SANDBOX/bin:$PREFIX/bin:$PATH"

CODEMUX="$ROOT/bin/codemux"
SKIP_ALL="deps,mirror,storage,toolset,glibc"

TEST_FAIL=""
run_install() { # <sleep>
  env CM_TEST_SLEEP="$1" CM_TEST_FAIL="$TEST_FAIL" bash "$CODEMUX" install \
    --skip "$SKIP_ALL" "${@:2}" >>"$SANDBOX/out.log" 2>&1
}
run_state() { awk -F'\t' -v m="$1" '!/^#/ && $1==m {s=$2} END{print s}' "$CODEMUX_HOME/run.tsv"; }

# =============================================================================
# 1. adapter normal: V1 + V2 terpasang lewat hulu
# =============================================================================
if run_install 0 --fresh; then ok "install adapter selesai (exit 0)"; else bad "install adapter gagal"; fi
if [ -x "$PREFIX/share/opencode/opencode.real" ]; then ok "V1 payload dibuat hulu"; else bad "V1 payload tidak ada"; fi
if [ -x "$PREFIX/share/opencode-v2/opencode.real" ]; then ok "V2 payload dibuat hulu"; else bad "V2 payload tidak ada"; fi
if [ "$(run_state v1)" = "DONE" ] && [ "$(run_state v2)" = "DONE" ]; then
  ok "run.tsv: v1 & v2 DONE"
else
  bad "run.tsv: v1=$(run_state v1) v2=$(run_state v2)"
fi
if [ -s "$CODEMUX_HOME/cache/v1-install.sh.sha256" ]; then ok "sha256 skrip hulu dicatat"; else bad "sha256 tidak dicatat"; fi

# =============================================================================
# 2. induk dibunuh saat adapter V1 jalan → lanjut tanpa intervensi
# =============================================================================
rm -rf "$PREFIX/share/opencode" "$PREFIX/bin/opencode" "$PREFIX/share/opencode-v2" "$PREFIX/bin/opencode-v2"
rm -f "$CODEMUX_HOME/run/v1.rc" "$CODEMUX_HOME/run/v2.rc"
CM_TEST_SLEEP=8 bash "$CODEMUX" install --fresh --skip "$SKIP_ALL" >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 3
if [ "$(run_state v1)" = "RUNNING" ]; then ok "adapter V1 tercatat RUNNING"; else bad "status adapter $(run_state v1)"; fi
kill -9 "$parent" 2>/dev/null
if run_install 10; then ok "run kedua melanjutkan adapter"; else bad "run kedua gagal"; fi
if [ "$(run_state v1)" = "DONE" ] && [ "$(run_state v2)" = "DONE" ]; then
  ok "kedua adapter DONE setelah pemulihan"
else
  bad "setelah pemulihan: v1=$(run_state v1) v2=$(run_state v2)"
fi

# =============================================================================
# 3. hulu gagal → FAILED tercatat, install tidak crash (exit 1)
# =============================================================================
rm -rf "$PREFIX/share/opencode" "$PREFIX/bin/opencode" "$PREFIX/share/opencode-v2" "$PREFIX/bin/opencode-v2"
TEST_FAIL=1
run_install 0 --fresh
rc=$?
TEST_FAIL=""
if [ "$rc" -eq 1 ]; then ok "hulu gagal → install exit 1 (bukan crash)"; else bad "hulu gagal → rc=$rc"; fi
if [ "$(run_state v1)" = "FAILED" ]; then ok "run.tsv: v1 FAILED"; else bad "run.tsv: v1=$(run_state v1)"; fi
if [ "$(run_state v2)" = "FAILED" ]; then ok "run.tsv: v2 FAILED (tetap dicoba)"; else bad "run.tsv: v2=$(run_state v2)"; fi

# =============================================================================
# 4. skrip hulu bukan skrip shell (HTML) → ditolak sebelum dieksekusi
# =============================================================================
printf '<html><body>rate limited</body></html>\n' >"$SANDBOX/upstream/bad.sh"
CODEMUX_UPSTREAM_V1="$SANDBOX/upstream/bad.sh" \
  CM_TEST_SLEEP=0 bash "$CODEMUX" install --skip "$SKIP_ALL" >>"$SANDBOX/out.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'gagal mengunduh install.sh hulu V1' "$SANDBOX/out.log"; then
  ok "HTML/rate-limit ditolak, bukan dieksekusi"
else
  bad "HTML tidak ditolak (rc=$rc)"
fi

printf '\n%s lulus · %s gagal\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf '\n--- 25 baris log terakhir ---\n'
  tail -n 25 "$SANDBOX/out.log" 2>/dev/null
fi
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
