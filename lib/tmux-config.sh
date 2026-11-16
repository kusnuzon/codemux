# shellcheck shell=bash
# tmux-config.sh — the one tmux configuration written by codemux,
# opencode-termux and opencode-termux-v2.
#
# This file is the single source of truth. Do not edit the copies in the
# other repos: change this file, then run tools/sync-tmux-config.sh in
# codemux, which copies the block between the markers below into each repo
# and fails when a copy drifts.
#
# The block is copied verbatim, so it must not depend on anything outside
# itself: no colour variables, no helper functions, no awk/sed — plain bash
# builtins and the few core utilities Termux always has (grep, cp, mv).

# ---8<--- tmux-config begin ---8<---
# Managed tmux config: dark status bar (tmux 3.8 defaults to green on black),
# a 20-column tab strip you can tap, plus the extended keys the pi TUI needs.
# Everything outside the markers belongs to the user and is never touched.
#
# The strip is one tmux window per tab:
#   " 0:menu          ✕ │ "  tap the name to switch, tap ✕ to close it
#   "  keep    │ close   "  the same tab while a close waits for an answer
# and " + new tab " sits at the right end of the bar.
#
# Clicks are read from #{mouse_status_range}, never from #{mouse_x}: tmux scrolls
# the window list by itself when the tabs do not fit, so a column count would
# point at the wrong tab. Every tap area is a #[range=user|...] region instead,
# which survives scrolling and any change of width.
#
# The handler is a script (codemux installs it next to the menu) because a
# .tmux.conf cannot define a function. Each binding ends with `exit 0`: tmux
# prints "'<script>' returned 1" on the message line for a failing run-shell,
# and that looks like a broken strip.
TMUXCONF_BEGIN='# --- codemux:tmux begin (managed; edits inside this block are overwritten) ---'
TMUXCONF_END='# --- codemux:tmux end ---'

# tmuxconf_block — print the managed block, markers included.
tmuxconf_block() {
  cat <<TMUXCONF
$TMUXCONF_BEGIN
# pi relies on extended keys so Shift+Enter and friends reach the TUI.
set -g extended-keys on
set -g extended-keys-format csi-u

# Tap a tab on the status bar to switch to it (tmux's own binding).
set -g mouse on

# Dark status bar on top: tmux 3.8 defaults to green on black. The window list
# stays the plain "index: name" strip — no custom formats to mis-render.
set -g status-position top
set -g status-style "bg=#101010,fg=#c0c0c0"
set -g status-left ""
set -g window-status-separator ""
# The menu names each tab, so tmux must not rename it back to the command.
set -g automatic-rename off

# One tab = 20 columns, always: a space, the index + a name cut to 12 columns
# (p15 pads the slot, so a short name never shrinks the target under a finger),
# then the ✕ button and the separator of that tab.
set -g window-status-format "#{?#{==:#{window_index},#{@closepending}},#[range=user|k#{window_index}]#[fg=#c0c0c0]  keep    #[range=user|x#{window_index}]#[fg=#5f6368]│#[fg=#ff6b6b#,bold] close   #[default], #[range=user|t#{window_index}]#{p15:#{window_index}:#{=12:window_name}}#[range=user|c#{window_index}] ✕ #[range=user|t#{window_index}]#[fg=#5f6368]│#[default]}"
set -g window-status-current-format "#{?#{==:#{window_index},#{@closepending}},#[range=user|k#{window_index}]#[fg=#c0c0c0]  keep    #[range=user|x#{window_index}]#[fg=#5f6368]│#[fg=#ff6b6b#,bold] close   #[default],#[fg=#ffffff#,bg=#2a2a2a#,bold] #[range=user|t#{window_index}]#{p15:#{window_index}:#{=12:window_name}}#[range=user|c#{window_index}] ✕ #[range=user|t#{window_index}] #[default]}"
set -g window-status-current-style "default"
set -g status-right "#[range=user|new] + new tab #[default]"

bind-key -n MouseDown1Status "run-shell \"sh \$HOME/.config/codemux/tabctl.sh tap '#{mouse_status_range}' >/dev/null 2>&1; exit 0\""
bind-key -n MouseDown1StatusRight "run-shell \"sh \$HOME/.config/codemux/tabctl.sh new >/dev/null 2>&1; exit 0\""
set -g pane-border-style "fg=#2a2a2a"
set -g pane-active-border-style "fg=#5f6368"
set -g message-style "bg=#1a1a1a,fg=#e0e0e0"
set -g message-command-style "bg=#1a1a1a,fg=#e0e0e0"
$TMUXCONF_END
TMUXCONF
}

# tmuxconf_slice <file> — print the managed block found in <file>, markers
# included; prints nothing when the file has no markers. Never fails.
tmuxconf_slice() {
  local file="$1" line inside=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$TMUXCONF_BEGIN" ]; then
      inside=1
      printf '%s\n' "$line"
      continue
    fi
    if [ "$inside" -eq 1 ] && [ "$line" = "$TMUXCONF_END" ]; then
      printf '%s\n' "$line"
      inside=0
      continue
    fi
    [ "$inside" -eq 1 ] && printf '%s\n' "$line"
  done <"$file"
  return 0
}

# tmuxconf_tabctl <path> — print the click handler for the tab strip.
# A .tmux.conf cannot define a function and a strip button that does nothing is
# worse than no button, so the handler ships inside this block: the three repos
# install the same script and V1/V2 need no extra file of their own.
#   tap <range>   t<i> switch, c<i> ask, k<i> keep, x<i> close, new add a tab
# Any non-zero exit makes tmux print "'<script>' returned N" over the whole
# status bar, so every path ends with `exit 0`.
tmuxconf_tabctl() {
  cat <<'TABCTL'
#!/bin/sh
# codemux tabctl — the mouse actions of the .tmux.conf tab strip.
# Installed by codemux (lib/tmux-config.sh). Do not edit by hand.
#
# The confirmation state is the session option @closepending: the tab format
# draws that one tab as two buttons, and the buttons are ranges (k…/x…), so this
# script never has to know where a tab sits on the screen. Taps are resolved
# from #{mouse_status_range}, never from a column count: tmux scrolls the window
# list by itself once the tabs overflow a column count would be wrong anyway.

set -u
action="${1:-}"
range="${2:-}"

sess="$(tmux display-message -p '#S' 2>/dev/null)" || exit 0
[ -n "$sess" ] || exit 0

clear_pending() { tmux set-option -u -t "$sess" @closepending >/dev/null 2>&1; }
window_count() { tmux list-windows -t "$sess:" 2>/dev/null | wc -l; }
last_tab() { tmux display-message -t "$sess" 'Last tab - keeping it open' >/dev/null 2>&1; }

case "$action" in
  new)
    clear_pending
    tmux new-window -t "$sess:" >/dev/null 2>&1
    ;;
  tap)
    idx="${range#?}"
    # Only a plain index is ever passed on to tmux as a window target.
    case "$idx" in
      '' | *[!0-9]*) idx="" ;;
    esac
    case "$range" in
      new)
        clear_pending
        tmux new-window -t "$sess:" >/dev/null 2>&1
        ;;
      t*)
        clear_pending
        [ -n "$idx" ] && tmux select-window -t "$sess:$idx" >/dev/null 2>&1
        ;;
      c*)
        clear_pending
        if [ "$(window_count)" -le 1 ]; then
          last_tab
        elif [ -n "$idx" ]; then
          tmux set-option -t "$sess" @closepending "$idx" >/dev/null 2>&1
        fi
        ;;
      k*)
        clear_pending
        ;;
      x*)
        clear_pending
        if [ "$(window_count)" -le 1 ]; then
          last_tab
        elif [ -n "$idx" ]; then
          tmux kill-window -t "$sess:$idx" >/dev/null 2>&1
          # keep the indexes dense, so a tab number is always its position
          tmux move-window -r -t "$sess:" >/dev/null 2>&1
        fi
        ;;
    esac
    ;;
esac
exit 0
TABCTL
}

tmuxconf_tabctl_path() { printf '%s' "${HOME:-}/.config/codemux/tabctl.sh"; }

# tmuxconf_tabctl_state — ok, stale or missing for the installed handler.
tmuxconf_tabctl_state() {
  local dst want
  dst="$(tmuxconf_tabctl_path)"
  [ -f "$dst" ] || { printf 'missing'; return 0; }
  want="$(tmuxconf_tabctl)"
  if [ "$(cat "$dst" 2>/dev/null)" = "$want" ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_tabctl_install — write the handler, idempotent.
tmuxconf_tabctl_install() {
  local dst tmp
  dst="$(tmuxconf_tabctl_path)"
  [ -n "$dst" ] || return 1
  [ "$(tmuxconf_tabctl_state)" = ok ] && return 0
  mkdir -p "${dst%/*}" 2>/dev/null || return 1
  tmp="$dst.tmp.$$"
  tmuxconf_tabctl >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 700 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# tmuxconf_conf_state <file> — ok, stale or missing for the managed block alone.
tmuxconf_conf_state() {
  local file="${1:-$HOME/.tmux.conf}" want have
  if [ ! -f "$file" ]; then
    printf 'missing'
    return 0
  fi
  grep -qxF "$TMUXCONF_BEGIN" "$file" 2>/dev/null || {
    printf 'missing'
    return 0
  }
  want="$(tmuxconf_block)"
  have="$(tmuxconf_slice "$file")"
  if [ "$want" = "$have" ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_state <file> — the block AND the click handler it binds to. A strip
# whose buttons cannot run anything is not "ok", so that counts as stale.
tmuxconf_state() {
  local file="${1:-$HOME/.tmux.conf}" cstate
  cstate="$(tmuxconf_conf_state "$file")"
  if [ "$cstate" != "ok" ]; then
    printf '%s' "$cstate"
    return 0
  fi
  if [ "$(tmuxconf_tabctl_state)" = ok ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_conf_write <file> — make the managed block present and current.
# Creates the file, appends the block to a user file, or replaces the block
# in place; the previous content is backed up before any change. Returns 0
# when the block is up to date afterwards, 1 when it could not be written.
tmuxconf_conf_write() {
  local conf="${1:-$HOME/.tmux.conf}" state block tmp line skip bak
  state="$(tmuxconf_conf_state "$conf")"
  [ "$state" = "ok" ] && return 0

  mkdir -p "${conf%/*}" 2>/dev/null || return 1
  block="$(tmuxconf_block)" || return 1

  if [ -f "$conf" ]; then
    bak="$conf.bak-tmuxconf-$(date +%Y%m%d%H%M%S)"
    cp "$conf" "$bak" 2>/dev/null || true
  fi

  case "$state" in
    missing)
      if [ -s "$conf" ]; then
        # keep the user's file intact, add a blank line as separator
        [ -z "$(tail -c 1 "$conf" 2>/dev/null)" ] || { printf '\n' >>"$conf"; } 2>/dev/null || return 1
        { printf '%s\n' "$block" >>"$conf"; } 2>/dev/null || return 1
      else
        { printf '%s\n' "$block" >"$conf"; } 2>/dev/null || return 1
      fi
      return 0 ;;
    stale)
      tmp="$conf.tmuxconf.$$"
      skip=0
      : >"$tmp" || return 1
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$TMUXCONF_BEGIN" ]; then
          printf '%s\n' "$block" >>"$tmp"
          skip=1
          continue
        fi
        if [ "$skip" -eq 1 ] && [ "$line" = "$TMUXCONF_END" ]; then
          skip=0
          continue
        fi
        [ "$skip" -eq 1 ] && continue
        printf '%s\n' "$line" >>"$tmp"
      done <"$conf"
      mv -f "$tmp" "$conf" || {
        rm -f "$tmp"
        return 1
      }
      return 0 ;;
  esac
  return 1
}

# tmuxconf_install [file] — write the block and the click handler it binds to.
tmuxconf_install() {
  tmuxconf_conf_write "${1:-$HOME/.tmux.conf}" || return 1
  tmuxconf_tabctl_install || return 1
  return 0
}
# ---8<--- tmux-config end ---8<---
