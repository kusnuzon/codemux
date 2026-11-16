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
# a tab strip you can tap, plus the extended keys the pi TUI needs. Everything
# outside the markers belongs to the user and is never touched.
TMUXCONF_BEGIN='# --- codemux:tmux begin (managed; edits inside this block are overwritten) ---'
TMUXCONF_END='# --- codemux:tmux end ---'

# tmuxconf_block — print the managed block, markers included.
tmuxconf_block() {
  cat <<TMUXCONF
$TMUXCONF_BEGIN
# pi relies on extended keys so Shift+Enter and friends reach the TUI.
set -g extended-keys on
set -g extended-keys-format csi-u

# A finger tap on the status bar is a left click in tmux, so tapping a tab
# switches to it. The "+ new tab" button at the right end of the bar is added
# by the codemux launcher and only exists inside the pi session.
set -g mouse on

# Dark theme: status bar on top, boxed tabs, borders and messages. The tab
# strip starts at column 0 (status-left is empty) and every tab is exactly 20
# columns wide, which is what lets a tap be mapped to a tab and its "x".
set -g status-position top
set -g status-style "bg=#101010,fg=#c0c0c0"
set -g status-left ""
set -g window-status-separator ""
set -g window-status-style "fg=#8a8f98,bg=#101010"
set -g window-status-format " #[fg=#5f6368]▏#[fg=#8a8f98]#{p15:#{window_index}:#{window_name}}#[fg=#5f6368]✕▕ "
set -g window-status-current-style "fg=#ffffff,bg=#2a2a2a,bold"
set -g window-status-current-format " #[fg=#8a8f98]▏#[fg=#ffffff,bg=#2a2a2a,bold]#{p15:#{window_index}:#{window_name}}#[fg=#5f6368,bg=#2a2a2a]✕▕ "
set -g window-status-activity-style "fg=#d0d0d0,bg=#101010"
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

# tmuxconf_state <file> — print ok, stale or missing.
tmuxconf_state() {
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

# tmuxconf_install [file] — make the managed block present and current.
# Creates the file, appends the block to a user file, or replaces the block
# in place; the previous content is backed up before any change. Returns 0
# when the file is up to date afterwards, 1 when it could not be written.
tmuxconf_install() {
  local conf="${1:-$HOME/.tmux.conf}" state block tmp line skip bak
  state="$(tmuxconf_state "$conf")"
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
# ---8<--- tmux-config end ---8<---
