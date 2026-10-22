#!/data/data/com.termux/files/usr/bin/bash
# tests/resume.sh — buktikan install tahan mati di tengah.
# Sandbox: HOME, CODEMUX_HOME, apt-get & dpkg-query palsu. Sistem TIDAK disentuh.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# CI (ubuntu) tidak punya $PREFIX Termux → pakai TMPDIR.
BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
BASH_BIN="$(command -v bash)"
SANDBOX="$BASE/codemux-test-$$"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/installed" "$SANDBOX/state"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- apt-get palsu -----------------------------------------------------------
cat >"$SANDBOX/bin/apt-get" <<'EOS'
#!/usr/bin/env bash
# CM_TEST_SLEEP: lama proses (untuk ditembak mati)
# CM_TEST_FAIL : paksa gagal
sleep "${CM_TEST_SLEEP:-0}"
[ -n "${CM_TEST_FAIL:-}" ] && exit 100
for a in "$@"; do
  case "$a" in fakepkg*) : >"$CM_TEST_INSTALLED/$a" ;; esac
done
exit 0
EOS
sed -i "1s|.*|#!$BASH_BIN|" "$SANDBOX/bin/apt-get"
chmod 700 "$SANDBOX/bin/apt-get"

# --- dpkg-query palsu --------------------------------------------------------
cat >"$SANDBOX/bin/dpkg-query" <<'EOS'
#!/usr/bin/env bash
pkg="${!#}"
if [ -e "$CM_TEST_INSTALLED/$pkg" ]; then
  echo "install ok installed"
else
  echo "deinstall ok config-files"
fi
EOS
sed -i "1s|.*|#!$BASH_BIN|" "$SANDBOX/bin/dpkg-query"
chmod 700 "$SANDBOX/bin/dpkg-query"

export CODEMUX_ALLOW_NONANDROID=1
export CM_TEST_INSTALLED="$SANDBOX/installed"
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export CODEMUX_HOME="$SANDBOX/state"
export CODEMUX_APT_PACKAGES="fakepkg1 fakepkg2"
export CM_TEST_SLEEP=0

CODEXUX="$ROOT/bin/codemux"

TEST_FAIL=""
run_install() { # <sleep> [opsi install...]
  local sleep_s="$1"
  shift
  env CM_TEST_SLEEP="$sleep_s" CM_TEST_FAIL="$TEST_FAIL" bash "$CODEXUX" install "$@" \
    --skip deps,mirror,storage,glibc >>"$SANDBOX/out.log" 2>&1
}

run_state() { awk -F'\t' -v m="$1" '!/^#/ && $1==m {s=$2} END{print s}' "$CODEMUX_HOME/run.tsv"; }

# =============================================================================
# 1. run normal: toolset dipasang lewat apt palsu
# =============================================================================
if run_install 0 --fresh; then ok "install dasar selesai (exit 0)"; else bad "install dasar gagal"; fi
if [ -e "$SANDBOX/installed/fakepkg1" ] && [ -e "$SANDBOX/installed/fakepkg2" ]; then
  ok "apt palsu benar-benar dipanggil"
else
  bad "apt palsu tidak terpanggil"
fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "run.tsv: toolset DONE"; else bad "run.tsv: toolset $(run_state toolset)"; fi

# =============================================================================
# 2. induk dibunuh saat apt jalan → anak tetap hidup → run berikutnya menunggu
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2"
CM_TEST_SLEEP=8 bash "$CODEXUX" install --fresh \
  --skip deps,mirror,storage,glibc >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 3

if [ "$(run_state toolset)" = "RUNNING" ]; then ok "langkah tercatat RUNNING sebelum selesai"; else bad "status awal $(run_state toolset)"; fi
kill -9 "$parent" 2>/dev/null

# lock basi harus dibuang otomatis, install kedua boleh jalan
if run_install 10; then ok "run kedua melanjutkan setelah induk dibunuh"; else bad "run kedua gagal"; fi
if [ -e "$SANDBOX/installed/fakepkg1" ]; then ok "anak yang selamat menyelesaikan pekerjaan"; else bad "anak tidak menyelesaikan"; fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "run kedua menutup langkah jadi DONE"; else bad "status akhir $(run_state toolset)"; fi

# =============================================================================
# 3. induk + anak dibunuh → status INTERRUPTED → run berikutnya ulang
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2" "$SANDBOX/state/run/toolset.rc"
CM_TEST_SLEEP=30 bash "$CODEXUX" install --fresh \
  --skip deps,mirror,storage,glibc >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 3
child="$(cat "$SANDBOX/state/run/toolset.pid" 2>/dev/null || true)"
kill -9 "$parent" 2>/dev/null
[ -n "$child" ] && kill -9 "$child" 2>/dev/null

rep_out="$(bash "$CODEXUX" repair --dry-run 2>&1 || true)"
if printf '%s' "$rep_out" | grep -q 'tandai terputus'; then
  ok "repair mendeteksi langkah terputus"
else
  bad "repair tidak mendeteksi langkah terputus"
  printf '%s\n' "$rep_out" | sed 's/^/     | /'
  awk -F'\t' '{print "     > "$1" "$2}' "$CODEMUX_HOME/run.tsv" 2>/dev/null
fi

if run_install 0; then ok "run ketiga menyelesaikan sisa pekerjaan"; else bad "run ketiga gagal"; fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "status pulih ke DONE"; else bad "status akhir $(run_state toolset)"; fi

# =============================================================================
# 4. lock aktif menolak install kedua (tidak ada dua apt bersamaan)
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2" "$SANDBOX/state/run/toolset.rc"
CM_TEST_SLEEP=6 bash "$CODEXUX" install --fresh \
  --skip deps,mirror,storage,glibc >>"$SANDBOX/out.log" 2>&1 &
parent=$!
sleep 2
run_install 0 >/dev/null 2>&1
rc=$?
wait "$parent" 2>/dev/null
if [ "$rc" -eq 3 ]; then ok "install kedua ditolak saat ada yang berjalan (exit 3)"; else bad "install kedua rc=$rc (harus 3)"; fi

# =============================================================================
# 5. apt gagal → FAILED tercatat, lalu run berikutnya memperbaiki
# =============================================================================
rm -f "$SANDBOX/installed/fakepkg1" "$SANDBOX/installed/fakepkg2"
TEST_FAIL=1
run_install 0 --fresh >/dev/null 2>&1
rc=$?
TEST_FAIL=""
if [ "$rc" -eq 1 ]; then ok "apt gagal → install exit 1 (bukan crash)"; else bad "apt gagal → rc=$rc"; fi
if [ "$(run_state toolset)" = "FAILED" ]; then ok "run.tsv: toolset FAILED"; else bad "run.tsv: $(run_state toolset)"; fi
if run_install 0; then ok "run berikutnya memperbaiki langkah gagal"; else bad "run perbaikan gagal"; fi
if [ "$(run_state toolset)" = "DONE" ]; then ok "status akhir DONE setelah perbaikan"; else bad "status akhir $(run_state toolset)"; fi

# =============================================================================
# 6. penulisan state atomik: tidak ada file .new tertinggal
# =============================================================================
left="$(find "$CODEMUX_HOME" -name '*.new' -o -name '.codemux.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$left" = "0" ]; then ok "tidak ada file sementara tertinggal"; else bad "$left file sementara tertinggal"; fi

printf '\n%s lulus · %s gagal\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf '\n--- 20 baris log terakhir ---\n'
  tail -n 20 "$SANDBOX/out.log" 2>/dev/null
fi
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
