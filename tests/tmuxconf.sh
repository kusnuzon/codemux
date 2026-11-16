#!/usr/bin/env bash
# tests/tmuxconf.sh — the managed ~/.tmux.conf block (lib/tmux-config.sh).
# Sandbox only: a temporary HOME, nothing outside $TMPDIR is touched.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1
SRC="$ROOT/lib/tmux-config.sh"

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX_ROOT="$BASE/codemux-tmuxconf-$$"
rm -rf "$SANDBOX_ROOT"
mkdir -p "$SANDBOX_ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

SANDBOX=""
new_sandbox() {
  local d="${SANDBOX_ROOT:?}/$1"
  rm -rf "$d"
  mkdir -p "$d/home"
  SANDBOX="$d"
  CONF="$d/home/.tmux.conf"
}

# Run a snippet with a clean environment and only this file sourced.
tmuxconf() { # <snippet>
  env -i HOME="$SANDBOX/home" PATH="$PATH" TMUXCONF_TEST=1 \
    bash -c "set -u; . '$SRC'; $1"
}

state() { tmuxconf "tmuxconf_state \"\$HOME/.tmux.conf\""; }
install_conf() { tmuxconf 'tmuxconf_install "$HOME/.tmux.conf"'; }

# =============================================================================
# 1. The block is self-contained (no awk/sed, no helper functions)
# =============================================================================
block="$(tmuxconf 'tmuxconf_block')"
if grep -qE '(^|[^a-z])awk([^a-z]|$)|(^|[^a-z])sed([^a-z]|$)' <<<"$block"; then
  bad "block: depends on awk/sed"
else
  ok "block: plain bash only (no awk/sed)"
fi
if grep -q 'extended-keys-format csi-u' <<<"$block" &&
  grep -q 'bg=#101010' <<<"$block" &&
  grep -q 'pane-active-border-style' <<<"$block"; then
  ok "block: carries extended-keys + dark theme"
else
  bad "block: incomplete"
fi
# A finger tap is a left click, so the block must turn the mouse on and shape
# the window list into a tab strip; otherwise tapping a tab does nothing.
if grep -qx 'set -g mouse on' <<<"$block" &&
  grep -qx 'set -g status-position top' <<<"$block" &&
  grep -q 'window-status-format' <<<"$block" &&
  grep -q 'window-status-current-format' <<<"$block" &&
  grep -q 'window-status-separator' <<<"$block"; then
  ok "block: tap-to-switch tab strip at the top (mouse on)"
else
  bad "block: no mouse/tab strip"
fi
# Fixed-width tabs keep the tap target big enough for a finger even when a
# title is short.
# Boxed, fixed-width tabs: 20 columns each, so a tap can be mapped to a tab
# and its own "x" (border on both sides, "+ new tab" on the right of the bar).
if [ "$(grep -o 'p16:#{window_index}' <<<"$block" | wc -l)" -eq 4 ] &&
  [ "$(grep -o '✕' <<<"$block" | wc -l)" -eq 4 ] &&
  grep -qx 'set -g status-left ""' <<<"$block"; then
  ok "block: fixed-width tabs with their own x and no status-left offset"
else
  bad "block: tab width/x missing"
fi
# A tab has no border glyphs: one background block for the active tab is
# enough, and drawing lines around every tab doubles them where tabs meet.
if ! grep -q '▏\|▕' <<<"$block"; then
  ok "block: tabs draw no box, so neighbouring borders cannot double up"
else
  bad "block: border glyphs are back in the tab format"
fi
# A comma inside a #{?...} branch ends that branch, so a style code there must
# write its commas as #, — otherwise the tab renders the literal text
# "bg=#2a2a2a" instead of a coloured tab.
badstyle=""
for line in $(grep -n 'set -g window-status.*-format "' <<<"$block" | cut -d: -f1); do
  while IFS= read -r code; do
    case "$code" in
      *", "*) ;;
    esac
    # strip escaped commas, then look for any comma left inside the code
    rest="${code//#,/}"
    case "$rest" in
      *","*) badstyle="$badstyle $code" ;;
    esac
  done <<<"$(sed -n "${line}p" <<<"$block" | grep -o '#\[[^]]*\]' | tr ' ' '\n' | grep -o '#\[[^]]*\]')"
done
if [ -z "$badstyle" ]; then
  ok "block: style codes inside the tab conditionals escape their commas"
else
  bad "block: unescaped comma in style code:$badstyle"
fi
# One page of three 20-column tabs: @tabstart is what a swipe moves, and a tab
# waiting for its close confirmation turns red.
if grep -q 'set -g window-status-format "#{?#{&&:#{>=:#{window_index},#{@tabstart}}' <<<"$block" &&
  grep -q 'set -g window-status-current-format "#{?#{&&:' <<<"$block" &&
  grep -qx 'set -g @tabstart 0' <<<"$block" &&
  [ "$(grep -o 'e|+|:#{@tabstart},3' <<<"$block" | wc -l)" -eq 2 ] &&
  [ "$(grep -o '=12:window_name' <<<"$block" | wc -l)" -eq 4 ] &&
  [ "$(grep -o 'ff6b6b' <<<"$block" | wc -l)" -eq 2 ]; then
  ok "block: one page of three tabs, names cut to their slot, red pending tab"
else
  bad "block: tab paging/conditional format missing"
fi
[ "$(grep -c 'codemux:tmux begin' <<<"$block")" = "1" ] && ok "block: one begin marker" || bad "block: marker count"

# =============================================================================
# 2. Fresh file: created with the block, state ok, idempotent afterwards
# =============================================================================
new_sandbox fresh
[ "$(state)" = "missing" ] && ok "fresh: state missing without a file" || bad "fresh: state $(state)"
install_conf && ok "fresh: install returns 0" || bad "fresh: install failed"
[ -f "$CONF" ] && ok "fresh: file created" || bad "fresh: no file"
[ "$(state)" = "ok" ] && ok "fresh: state ok" || bad "fresh: state $(state)"
grep -qxF "$(tmuxconf 'printf %s "$TMUXCONF_BEGIN"')" "$CONF" &&
  ok "fresh: begin marker written" || bad "fresh: begin marker missing"
grep -qxF "$(tmuxconf 'printf %s "$TMUXCONF_END"')" "$CONF" &&
  ok "fresh: end marker written" || bad "fresh: end marker missing"

before="$(cat "$CONF")"
install_conf || bad "fresh: second install failed"
[ "$(cat "$CONF")" = "$before" ] && ok "fresh: second install is a no-op" || bad "fresh: content changed"
n_bak=$(find "$SANDBOX/home" -maxdepth 1 -name '.tmux.conf.bak-tmuxconf-*' | wc -l)
[ "$n_bak" -eq 0 ] && ok "fresh: no backup needed for a new file" || bad "fresh: $n_bak backups"

# =============================================================================
# 3. Existing user file without markers: appended, user lines kept
# =============================================================================
new_sandbox user
printf 'set -g mouse on\nbind-key r source-file ~/.tmux.conf\n' >"$CONF"
[ "$(state)" = "missing" ] && ok "user: state missing for an unmanaged file" || bad "user: state $(state)"
install_conf && ok "user: install returns 0" || bad "user: install failed"
grep -qxF 'set -g mouse on' "$CONF" && ok "user: own setting preserved" || bad "user: own setting lost"
grep -qxF 'bind-key r source-file ~/.tmux.conf' "$CONF" && ok "user: own binding preserved" || bad "user: own binding lost"
[ "$(state)" = "ok" ] && ok "user: state ok" || bad "user: state $(state)"
n_bak=$(find "$SANDBOX/home" -maxdepth 1 -name '.tmux.conf.bak-tmuxconf-*' | wc -l)
[ "$n_bak" -eq 1 ] && ok "user: previous file backed up" || bad "user: $n_bak backups"
before="$(cat "$CONF")"
install_conf
[ "$(cat "$CONF")" = "$before" ] && ok "user: no duplicate block on re-run" || bad "user: block duplicated"

# =============================================================================
# 4. Drifted block: state stale, install rewrites it, surroundings untouched
# =============================================================================
new_sandbox stale
printf '# my own header\n' >"$CONF"
install_conf || bad "stale: seed install failed"
printf 'set -g status-style "bg=green,fg=black"\n' >"$SANDBOX/bad"
python3 - "$CONF" "$SANDBOX/bad" <<'PY' 2>/dev/null
import sys
conf, bad = sys.argv[1], sys.argv[2]
lines = open(conf).read().splitlines()
lines = [l for l in lines if l != 'set -g status-style "bg=#101010,fg=#c0c0c0"']
lines.insert(lines.index([l for l in lines if l.startswith('# --- codemux:tmux begin')][0]) + 1,
             open(bad).read().strip())
open(conf, 'w').write('\n'.join(lines) + '\n')
PY
printf 'set -g mouse on\n' >>"$CONF"
[ "$(state)" = "stale" ] && ok "stale: drift detected" || bad "stale: state $(state)"
install_conf && ok "stale: install returns 0" || bad "stale: install failed"
[ "$(state)" = "ok" ] && ok "stale: rewritten to canonical" || bad "stale: state $(state)"
grep -qxF 'set -g status-style "bg=green,fg=black"' "$CONF" &&
  bad "stale: drifted line survived" || ok "stale: drifted line replaced"
grep -qxF '# my own header' "$CONF" && ok "stale: header outside the block kept" || bad "stale: header lost"
grep -qxF 'set -g mouse on' "$CONF" && ok "stale: trailing user line kept" || bad "stale: trailing line lost"
[ "$(grep -c 'codemux:tmux begin' "$CONF")" = "1" ] && ok "stale: still one block" || bad "stale: block count"

# =============================================================================
# 5. Unwritable location: returns 1 instead of dying
# =============================================================================
new_sandbox blocked
mkdir -p "$SANDBOX/home/.tmux.conf"
if install_conf; then
  bad "blocked: install claimed success on a directory"
else
  ok "blocked: install returns 1 when the path is not a file"
fi
rmdir "$SANDBOX/home/.tmux.conf"

# =============================================================================
# 6. Every target repo carries the same block and calls it
# =============================================================================
# <repo>:<file holding the synced block>:<file with the call site>
for t in "opencode-termux:install.sh:install.sh" \
  "opencode-termux-v2:lib/common.sh:install.sh"; do
  repo="${t%%:*}"; rest="${t#*:}"
  blk="$ROOT/../$repo/${rest%%:*}"
  call="$ROOT/../$repo/${rest#*:}"
  label="$repo"
  if [ ! -f "$blk" ] || [ ! -f "$call" ]; then
    ok "$label: not checked out (skip)"
    continue
  fi
  grep -qF '# --- tmux-config begin (synced from codemux/lib/tmux-config.sh) ---' "$blk" &&
    ok "$label: synced block present" || bad "$label: no synced block"
  grep -q 'tmuxconf_install "\$HOME/.tmux.conf"' "$call" &&
    ok "$label: calls tmuxconf_install" || bad "$label: call site missing"
done

rm -rf "$SANDBOX_ROOT"
printf '\n%d passed · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
