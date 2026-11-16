# codemux:launcher begin  (managed by codemux — do not edit by hand)
# codemux:launcher version 36
# Opening Termux goes straight into one tmux session: the tab strip sits on top,
# every tab runs the codemux menu (~/.config/codemux/menu.sh), `Ctrl+b c` adds a
# tab, `Ctrl+b d` detaches and the agent keeps running.
#
# The menu itself is NOT in this file. A shell startup file is sourced in front
# of every prompt, and a full-screen agent can hand the terminal back in a state
# where startup code misbehaves — so this block stays a handful of lines and all
# of the menu lives in its own script.
#
# Skip everything: OPENCODE_NO_AUTO=1 bash

_oc_menu_script="${HOME:-/data/data/com.termux/files/home}/.config/codemux/menu.sh"
# The script only defines the menu; it is started here, and the pane falls back
# to a plain interactive shell if the menu ever returns (a detached pane can see
# EOF before the client attaches).
_oc_menu_cmd="bash -ic '. \"$_oc_menu_script\"; _cm_menu_loop; exec bash -i'"

_oc_tmux_enter() {
  if tmux has-session -t main 2>/dev/null; then
    exec tmux attach-session -t main
  fi
  tmux new-session -d -s main "$_oc_menu_cmd" 2>/dev/null || return 1
  tmux set-option -t main default-command "$_oc_menu_cmd" 2>/dev/null
  tmux set-option -t main automatic-rename off 2>/dev/null
  tmux rename-window -t main:0 'menu' 2>/dev/null
  exec tmux attach-session -t main
}

if [ -z "${TMUX:-}" ] && [ -z "${OPENCODE_NO_AUTO:-}" ] && [ -t 0 ] && [ -t 1 ]; then
  if command -v tmux >/dev/null 2>&1; then
    _oc_tmux_enter
  elif [ -r "$_oc_menu_script" ]; then
    . "$_oc_menu_script"
  fi
fi

# Blind repair for a frozen pane: `fixterm` + Enter. `_oc_tty_fix` is the silent
# form other blocks call after an agent exits outside tmux.
_oc_tty_fix() { [ -r "$_oc_menu_script" ] && bash "$_oc_menu_script" --repair; }
fixterm() { [ -r "$_oc_menu_script" ] && bash "$_oc_menu_script" --fixterm; }
menu() { [ -r "$_oc_menu_script" ] && bash "$_oc_menu_script"; }
version() { [ -r "$_oc_menu_script" ] && bash "$_oc_menu_script" --versions; }
# codemux:launcher end
