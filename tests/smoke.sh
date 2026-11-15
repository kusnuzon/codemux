#!/usr/bin/env bash
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
assert r["ok"] + r["warn"] + r["miss"] + r["fail"] + r["skip"] == 13, r
assert d["komponen"] in ("v1", "v2", "v1 v2"), d
'; then
  ok "check --json"
else
  bad "check --json"
fi

# 6. install --dry-run: default is V2 only, changes nothing
out="$(bash bin/codemux install --dry-run 2>&1 || true)"
rows="$(printf '%s\n' "$out" | grep -cE '^  [0-9]+/10 ' || true)"
if [ "$rows" -eq 10 ] && printf '%s' "$out" | grep -q 'dry-run' &&
  printf '%s\n' "$out" | grep -q 'install \[v2\]'; then
  ok "install --dry-run (default v2, 10 modules)"
else
  bad "install --dry-run (plan rows=$rows)"
fi

# 6b. component choice: V1 only / V2 only / both
#     A plain CI runner has no $PREFIX; fall back to $TMPDIR rather than
#     dying on an unbound variable in the sandbox setup.
BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SB="$BASE/codemux-smoke-$$"
rm -rf "$SB"
mkdir -p "$SB/home" "$SB/state"
sel() { # <args...> → stdout of `codemux install --dry-run` in the sandbox
  env HOME="$SB/home" CODEMUX_HOME="$SB/state" PREFIX="$SB/prefix" TMPDIR="$BASE" \
    CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 \
    bash bin/codemux install --dry-run "$@" 2>&1 || true
}
out="$(sel --only v1)"
rows="$(printf '%s\n' "$out" | grep -cE '^  [0-9]+/10 ' || true)"
if [ "$rows" -eq 10 ] &&
  printf '%s\n' "$out" | grep -qE '^  [0-9]+/10 v1 ' &&
  ! printf '%s\n' "$out" | grep -qE '^  [0-9]+/10 v2 '; then
  ok "install --only v1 (10 modules, V2 skipped)"
else
  bad "install --only v1 (plan rows=$rows)"
fi
out="$(sel --only v2)"
rows="$(printf '%s\n' "$out" | grep -cE '^  [0-9]+/10 ' || true)"
if [ "$rows" -eq 10 ] &&
  printf '%s\n' "$out" | grep -qE '^  [0-9]+/10 v2 ' &&
  ! printf '%s\n' "$out" | grep -qE '^  [0-9]+/10 v1 '; then
  ok "install --only v2 (10 modules, V1 skipped)"
else
  bad "install --only v2 (plan rows=$rows)"
fi
out="$(sel --only both)"
rows="$(printf '%s\n' "$out" | grep -cE '^  [0-9]+/11 ' || true)"
if [ "$rows" -eq 11 ]; then ok "install --only both (11 modules)"; else bad "install --only both (plan rows=$rows)"; fi
if sel --only v3 | grep -q 'unknown component list'; then
  ok "install --only v3 rejected"
else
  bad "install --only v3 was not rejected"
fi

# 6c. the saved choice is reused; check reports the other component as SKIP
printf 'v1\n' >"$SB/state/components"
out="$(env HOME="$SB/home" CODEMUX_HOME="$SB/state" PREFIX="$SB/prefix" \
  CODEMUX_ALLOW_NONANDROID=1 CODEMUX_NO_APT_CHECK=1 bash bin/codemux check --json 2>/dev/null || true)"
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["komponen"] == "v1", d
assert d["ringkasan"]["skip"] == 1, d["ringkasan"]
st = {m["modul"]: m["status"] for m in d["modul"]}
assert st["opencode-v2"] == "SKIP", st
assert st["opencode-v1"] != "SKIP", st
'; then
  ok "check: unselected component reported as SKIP"
else
  bad "check: SKIP for the unselected component"
fi
out="$(sel)"
rows="$(printf '%s\n' "$out" | grep -cE '^  [0-9]+/10 ' || true)"
if [ "$rows" -eq 10 ] && printf '%s\n' "$out" | grep -q 'install \[v1\]'; then
  ok "install reuses the saved choice (v1)"
else
  bad "install did not reuse the saved choice"
fi
rm -rf "$SB"

# 6d. progress feedback: silent without a TTY (logs/CI stay clean), live with one
out="$(env CODEMUX_HOME="$SB/prog" bash -c '
  . lib/common.sh
  codemux_colors
  codemux_spin_start "[1/2] deps " installing
  codemux_spin_msg "downloading x"
  codemux_spin_stop
  printf done
' 2>&1)"
if [ "$out" = "done" ]; then
  ok "progress: silent when stderr is not a terminal"
else
  bad "progress: unexpected output without a TTY ($out)"
fi
out="$(env CODEMUX_HOME="$SB/prog" CODEMUX_PROGRESS=1 bash -c '
  . lib/common.sh
  codemux_colors
  codemux_spin_start "[1/2] deps " installing
  sleep 0.4
  codemux_spin_stop
  printf done
' 2>&1)"
case "$out" in
  *"[1/2] deps "*) ok "progress: spinner + prefix drawn with a terminal" ;;
  *) bad "progress: spinner did not draw ($out)" ;;
esac
case "$out" in
  *"installing"*) ok "progress: the step message is shown" ;;
  *) bad "progress: step message missing" ;;
esac
rm -rf "$SB"

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

# 9. the shared progress bar renders a stable width, clamps out-of-range and
#    non-numeric input, and keeps the codemux_bar default width at 16.
#    It is a plain function from lib/progress-bar.sh (the plan and spinner call
#    it), so source common.sh here instead of going through bin/codemux.
# shellcheck disable=SC2034  # read by the sourced common.sh
CODEMUX_ROOT="$ROOT"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
bar_ok=1
for c in "0|24|[------------------------]   0%" "50|24|[############------------]  50%" \
  "100|24|[########################] 100%" "150|24|[########################] 100%" \
  "-5|24|[------------------------]   0%" "abc|24|[------------------------]   0%" \
  "50|0|[############------------]  50%"; do
  pct="${c%%|*}"; rest="${c#*|}"; width="${rest%%|*}"; want="${rest#*|}"
  got="$(progress_bar "$pct" "$width")"
  if [ "$got" != "$want" ]; then
    bad "progress_bar $pct/$width → '$got' (want '$want')"
    bar_ok=0
  fi
done
# a label is appended after two spaces, with no trailing newline from the bar
if [ "$(progress_bar 50 8 'half')" = "[####----]  50%  half" ]; then
  ok "progress_bar label"
else
  bad "progress_bar label → '$(progress_bar 50 8 half)'"
  bar_ok=0
fi
# codemux_bar keeps its own defaults (width 16) for the spinner and the plan
if [ "$(codemux_bar 100)" = "[################] 100%" ] &&
  [ "$(codemux_bar 50 12)" = "[######------]  50%" ]; then
  ok "codemux_bar defaults (width 16)"
else
  bad "codemux_bar defaults → '$(codemux_bar 100)' / '$(codemux_bar 50 12)'"
  bar_ok=0
fi
# progress_step writes a numbered line
if [ "$(progress_step 2 8 'Installing')" = "[######------------------]  25%  2/8 Installing" ]; then
  ok "progress_step line"
else
  bad "progress_step → '$(progress_step 2 8 Installing)'"
  bar_ok=0
fi
[ "$bar_ok" -eq 1 ] && ok "progress bar (width, clamping, label, defaults)"

# 9b. the same block lives in the two opencode-termux repos; a silent copy
#     that drifted is exactly the class of bug this file exists to stop.
if [ -d "$ROOT/../opencode-termux" ] || [ -d "$ROOT/../opencode-termux-v2" ]; then
  if out="$(bash "$ROOT/tools/sync-progress-bar.sh" --check 2>&1)"; then
    ok "progress bar synced with the sibling repos"
  else
    bad "$out"
  fi
else
  printf 'skip progress bar sync (sibling repos not checked out)\n'
fi

# 10. codemux_content_length: only a 2xx length counts, never an error page
#     (a 404 body has a length too, which would show a bogus 100% bar).
#     Network is optional: skipped when github.com is unreachable.
if curl -fsI --max-time 8 https://github.com >/dev/null 2>&1; then
  # cd out of the repo first: a 404 URL must not fall through to a file here.
  n="$(cd / && codemux_content_length https://github.com/kusnuzon/codemux/raw/main/VERSION)"
  if [ "$n" = "6" ]; then ok "content-length 200 ($n)"; else bad "content-length 200 ($n, want 6)"; fi
  n="$(cd / && codemux_content_length https://github.com/kusnuzon/codemux/raw/main/NOPE-$$.txt)"
  if [ -z "$n" ]; then ok "content-length 404 (empty)"; else bad "content-length 404 ($n, want empty)"; fi
else
  printf 'skip content-length (no network)\n'
fi

# 11. shellcheck when available
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
