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
  grep -q 'bg=#000000' <<<"$block" &&
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
# The strip is not a plain window list: every tab carries a ✕, the tab that is
# waiting for an answer turns into "keep | close", and a plain " + " button
# follows the last tab.
if grep -q ' ✕ ' <<<"$block" &&
  grep -q 'keep ' <<<"$block" &&
  grep -q 'close  ' <<<"$block" &&
  grep -q 'range=user|new' <<<"$block" &&
  grep -q '@closepending' <<<"$block"; then
  ok "block: ✕ per tab, keep/close confirmation and a + button"
else
  bad "block: tab strip incomplete"
fi
# The " + " button rides on the last tab (index = session_windows - 1) instead of
# sitting at the right end of the bar, and the label is just "+ ": no words.
fmt_line="$(grep '^set -g window-status-format ' <<<"$block")"
cur_line="$(grep '^set -g window-status-current-format ' <<<"$block")"
last_tab='#{e|-|:#{session_windows},1}'
if grep -qF '╋' <<<"$fmt_line" &&
  grep -q "range=user|new" <<<"$fmt_line" &&
  grep -q "range=user|new" <<<"$cur_line" &&
  grep -qF "==:#{window_index},$last_tab" <<<"$fmt_line" &&
  grep -qF "==:#{window_index},$last_tab" <<<"$cur_line" &&
  ! grep -qi 'new tab' <<<"$block"; then
  ok "block: heavy + button follows the last tab (no label text)"
else
  bad "block: + button is not pinned to the last tab"
fi
# The right end of the bar stays empty: two "+" buttons on one bar would be
# confusing and the right one never moves with the tabs.
if grep -qx 'set -g status-right ""' <<<"$block"; then
  ok "block: status-right is empty (+ lives on the last tab)"
else
  bad "block: status-right still carries a button"
fi
# Taps are resolved by status ranges, not by counting columns: tmux scrolls the
# window list by itself, so x/20 points at the wrong tab once the tabs overflow.
if grep -q 'range=user|c#{window_index}' <<<"$block" &&
  grep -q 'range=user|k#{window_index}' <<<"$block" &&
  grep -q 'range=user|x#{window_index}' <<<"$block" &&
  grep -q 'mouse_status_range' <<<"$block" &&
  ! grep -q 'mouse_x' <<<"$block"; then
  ok "block: taps resolve through mouse_status_range (no column maths)"
else
  bad "block: taps do not use status ranges"
fi
# Every binding runs the handler script and ends with `exit 0`; a run-shell that
# fails makes tmux print the whole script over the status bar.
for key in MouseDown1Status MouseDown1StatusRight; do
  line="$(grep "^bind-key -n $key " <<<"$block" || true)"
  if grep -q 'codemux/tabctl.sh' <<<"$line" && grep -q 'exit 0' <<<"$line"; then
    ok "block: $key runs tabctl.sh and exits 0"
  else
    bad "block: $key binding is wrong"
  fi
done
# A comma inside a #{?...} branch ends that branch, so style commas must be
# written as `#,` — an unescaped one truncates the format and prints it raw.
unescaped="${block//#,/}"
if grep -qE '#\[[^]]*,' <<<"$unescaped"; then
  bad "block: unescaped comma inside a style code"
else
  ok "block: style commas escaped inside the conditionals"
fi
# #{?cond,then,else,} (four fields) expands to an empty string and the whole
# strip disappears; a missing closing brace does the same.
if grep -q ',}' <<<"$block"; then
  bad "block: a conditional ends with an empty field"
else
  ok "block: no conditional ends with an empty field"
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
lines = [l for l in lines if l != 'set -g status-style "bg=#000000,fg=#c0c0c0"']
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
# 6. With tmux available: the block parses, and every tab state is 20 columns
# =============================================================================
# The width is what makes a tap land on the tab under the finger; a name that
# is one column too long shifts the whole strip. Skipped where tmux is missing.
if command -v tmux >/dev/null 2>&1; then
  sock="codemux-tabs-$$"
  conf="$SANDBOX/block.conf"
  tmuxconf 'tmuxconf_block' >"$conf"
  if tmux -L "$sock" -f "$conf" new-session -d -s chk -x 100 -y 12 'sleep 20' 2>/dev/null; then
    ok "tmux: the block parses"
  else
    bad "tmux: the block does not parse"
  fi
  tmux -L "$sock" new-window -t chk: -n 'judul yang panjang sekali' 'sleep 20' 2>/dev/null
  tmux -L "$sock" new-window -t chk: -n opencode 'sleep 20' 2>/dev/null
  width() { # <option>
    tmux -L "$sock" display -p -t chk:1 "$(tmux -L "$sock" show -gv "$1")" 2>/dev/null |
      sed -e 's/#\[[^]]*\]//g' | awk '{ print length($0) }'
  }
  [ "$(width window-status-format)" -eq 20 ] &&
    ok "tmux: an inactive tab is 20 columns" || bad "tmux: inactive tab width $(width window-status-format)"
  [ "$(width window-status-current-format)" -eq 20 ] &&
    ok "tmux: the active tab is 20 columns" || bad "tmux: active tab width $(width window-status-current-format)"
  [ "$(width window-status-format)" = 20 ] &&
    grep -q 'judul yang p' <<<"$(tmux -L "$sock" display -p -t chk:1 \
      "$(tmux -L "$sock" show -gv window-status-format)")" &&
    ok "tmux: a long name is cut instead of overflowing" ||
    bad "tmux: a long name is not cut"
  tmux -L "$sock" set-option -t chk @closepending 1 2>/dev/null
  [ "$(width window-status-format)" -eq 20 ] &&
    ok "tmux: the keep/close tab is 20 columns" || bad "tmux: keep/close width $(width window-status-format)"
  tmux -L "$sock" set-option -u -t chk @closepending 2>/dev/null
  tmux -L "$sock" kill-server 2>/dev/null
else
  ok "tmux: not installed (width checks skipped)"
fi

# =============================================================================
# 7. Every target repo carries the same block and calls it
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
