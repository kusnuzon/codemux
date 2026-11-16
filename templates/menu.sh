# codemux menu (version 3) — the numbered menu every tmux tab shows.
# shellcheck shell=bash
# Installed to ~/.config/codemux/menu.sh by `codemux install`.
#
# Why it lives here and not in ~/.bashrc: the menu used to be a shell startup
# block, so a terminal a full-screen agent handed back in a bad state could
# swallow the startup code. Now Termux opens one tmux session, every tab runs
# `bash -ic '. ~/.config/codemux/menu.sh'`, and the shell below the menu is a
# normal interactive shell. The startup file keeps only a few lines.
#
# Rows are answered by typing a number, never by a single key: a one-key reader
# needs raw mode and spins on EOF when the terminal comes back raw.

CM_MENU_VERSION="3"

# Colours are empty when the output is not a terminal or NO_COLOR is set.
_cm_colors() {
  C1=''; C2=''; ACC=''; DIM=''; BOLD=''; R=''
  if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    C1=$'\033[38;5;243m'   # OPEN — dark grey
    C2=$'\033[38;5;231m'   # CODE — white
    ACC=$'\033[38;5;213m'
    DIM=$'\033[2m'
    BOLD=$'\033[1m'
    R=$'\033[0m'
  fi
}

# Installed version of one component, read from a file. `opencode --version`
# would start the 200 MB payload (1.2 s in front of every prompt), so the
# payload's own VERSION file is used and dpkg is the fallback.
_cm_ver() {
  local pre="${PREFIX:-/data/data/com.termux/files/usr}" v=""
  case "$1" in
    v1)
      v="$(cat "$pre/share/opencode/VERSION" 2>/dev/null)"
      [ -n "$v" ] || v="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null)"
      ;;
    v2) v="$(cat "$pre/share/opencode-v2/VERSION" 2>/dev/null)" ;;
    pi)
      v="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' \
        "$HOME"/.npm/_npx/*/node_modules/free-pi-cli/package.json 2>/dev/null | head -n 1)"
      ;;
  esac
  printf '%s' "${v:-?}"
}

_cm_banner() {
  printf '\n'
  # each line: first 4 glyphs (OPEN) grey, remaining 4 glyphs (CODE) white
  local a bits=""
  for a in "█▀▀█ █▀▀█ █▀▀▀ █▀▀▄ █▀▀▀ █▀▀█ █▀▀▄ █▀▀▀" \
           "█  █ █▀▀▀ █▀▀  █  █ █    █  █ █  █ █▀▀ " \
           "▀▀▀▀ ▀    ▀▀▀▀ ▀  ▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀"; do
    printf '   %s%s%s%s%s%s\n' "$C1" "${a:0:19}" "$R" "$C2" "${a:19}" "$R"
  done
  # only the agents that are actually installed
  command -v opencode >/dev/null 2>&1 && bits="v1 $(_cm_ver v1)"
  command -v opencode-v2 >/dev/null 2>&1 &&
    bits="${bits:+$bits  ·  }v2 $(_cm_ver v2)"
  command -v pi >/dev/null 2>&1 &&
    bits="${bits:+$bits  ·  }free-pi $(_cm_ver pi)"
  if [ -n "$bits" ]; then
    printf '   %sTermux · Android arm64%s   %s%s%s\n\n' "$DIM" "$R" "$DIM" "$bits" "$R"
  else
    printf '   %sTermux · Android arm64%s   %sno agent yet%s\n\n' "$DIM" "$R" "$DIM" "$R"
  fi
}

# Rows. Every row is always offered; a missing agent is marked and the choice
# explains how to install it (the menu never installs by itself).
_cm_items() {
  _CM_KEYS=()
  _CM_NAMES=()
  _CM_DESCS=()
  if command -v opencode >/dev/null 2>&1; then
    _CM_DESCS+=("$(_cm_ver v1) · stable")
  else
    _CM_DESCS+=("not installed")
  fi
  _CM_KEYS+=("v1"); _CM_NAMES+=("OpenCode V1")
  if command -v opencode-v2 >/dev/null 2>&1; then
    _CM_DESCS+=("$(_cm_ver v2) · separate DB")
  else
    _CM_DESCS+=("not installed")
  fi
  _CM_KEYS+=("v2"); _CM_NAMES+=("OpenCode V2")
  if command -v pi >/dev/null 2>&1; then
    _CM_DESCS+=("$(_cm_ver pi) · free-pi agent")
  else
    _CM_DESCS+=("not installed")
  fi
  _CM_KEYS+=("pi"); _CM_NAMES+=("Free-pi (Pi)")
  _CM_KEYS+=("shell"); _CM_NAMES+=("Shell only"); _CM_DESCS+=("no agent")
  _CM_KEYS+=("quit"); _CM_NAMES+=("Quit"); _CM_DESCS+=("close this tab")
  _CM_COUNT="${#_CM_KEYS[@]}"
}

_cm_list() {
  local i pad
  printf '  %s───────────────────────────────────────────%s\n' "$DIM" "$R"
  for ((i = 0; i < _CM_COUNT; i++)); do
    printf -v pad '%-19s' "${_CM_NAMES[$i]}"
    printf '  %s%d%s  %s%s%s  %s%s%s\n' \
      "$BOLD" "$((i + 1))" "$R" "$BOLD" "$pad" "$R" "$DIM" "${_CM_DESCS[$i]}" "$R"
  done
  printf '  %s───────────────────────────────────────────%s\n' "$DIM" "$R"
  printf '  %stype a number, then Enter%s   %sq quit%s   %sCtrl+b c new tab%s\n\n' \
    "$DIM" "$R" "$DIM" "$R" "$DIM" "$R"
}

# Name the tab after what is running in it (the tab strip is the only place the
# user sees which agent a tab holds). No tmux → nothing to do.
_cm_tab_title() {
  [ -n "${TMUX:-}" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  local id
  id="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)" || return 0
  [ -n "$id" ] && tmux rename-window -t "$id" "$1" 2>/dev/null
  return 0
}

# A full-screen agent can hand the pane back inside the alternate screen, in the
# middle of an OSC/DCS string, with flow control paused or the termios flags
# still raw. tmux repairs most of it, the pane does not: close a dangling control
# string (BEL/ST), send XON, leave every screen mode, show the cursor, then clear.
# RIS is not sent here — inside tmux it would throw away the pane's own history.
_cm_tty_fix() {
  # Only touch a terminal that is really ours: with stdout redirected (a test, a
  # pipe, `menu | tee`) there is nothing to repair and touching /dev/tty can
  # block on a terminal nobody is reading.
  local out=""
  if [ -t 1 ]; then
    out=/dev/stdout
  elif [ -t 2 ]; then
    out=/dev/stderr
  else
    return 0
  fi
  printf '\007\033\\\033\\\017' >"$out"
  if command -v stty >/dev/null 2>&1; then
    stty sane <"$out" 2>/dev/null || true
  fi
  printf '\033[?2026l\033[?2031l\033[?1049l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?1016l\033[?1004l\033[?2004l\033[?1l\033[!p\033[r\033[?6l\033[?7h\033(B\033[0m\033[?25h\033[2J\033[H' >"$out"
  return 0
}

# Blind escape hatch: if a pane ever stays frozen, typing `fixterm` + Enter
# repairs it. Reached through ~/.bashrc, which calls this script with --fixterm.
fixterm() { _cm_tty_fix; printf '  terminal repaired\n'; }

# free-pi is a function in ~/.bashrc only in an interactive shell; the menu may
# be sourced from one, but keep the fallback so a plain script still works.
_cm_pi_bin() {
  local b=""
  b="$(command -v free-pi-cli 2>/dev/null)" && { printf '%s' "$b"; return 0; }
  b="$(ls -1 "$HOME"/.npm/_npx/*/node_modules/.bin/free-pi-cli 2>/dev/null | head -n 1)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  return 1
}

# Run one component. A missing agent is reported, never installed from here.
_cm_launch() {
  local key="$1" cmd="" name="" rc=0
  case "$key" in
    v1) cmd="opencode"; name="OpenCode V1" ;;
    v2) cmd="opencode-v2"; name="OpenCode V2" ;;
    pi) cmd="$(_cm_pi_bin || true)"; name="Free-pi (Pi)" ;;
    *) return 1 ;;
  esac
  if [ -z "$cmd" ] || ! command -v "$cmd" >/dev/null 2>&1; then
    printf '\n  %s%s is not installed%s — run: %scodemux install%s\n\n' \
      "$BOLD" "$name" "$R" "$ACC" "$R"
    return 1
  fi
  _cm_tab_title "$key"
  printf '  %s→ %s%s\n\n' "$DIM" "$name" "$R"
  "$cmd"
  rc=$?
  # repair the pane whatever the exit code was, then mark the tab as a menu again
  _cm_tty_fix
  _cm_tab_title "menu"
  return "$rc"
}

_cm_quit() {
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "$(tmux display-message -p '#S' 2>/dev/null)" 2>/dev/null
  fi
  return 1
}

# Print the rows, read one line, act. A dead stdin (EOF) or `q` leaves the menu;
# Ctrl+C (rc > 128) only cancels the answer.
_cm_menu_loop() {
  local choice rc key
  _cm_tab_title "menu"
  while :; do
    _cm_items
    _cm_colors
    printf '\033[2J\033[H'
    _cm_banner
    _cm_list
    printf '  %sChoice%s: ' "$BOLD" "$R"
    choice=""
    IFS= read -r choice
    rc=$?
    if [ "$rc" -gt 128 ]; then
      printf '\n'
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      printf '\n'
      return 1
    fi
    choice="${choice//[[:space:]]/}"
    case "$choice" in
      '') continue ;;
      q | Q | quit | exit) printf '\n'; return 1 ;;
    esac
    case "$choice" in
      *[!0-9]*) choice=0 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$_CM_COUNT" ]; then
      printf '  %stype a number from 1 to %d, or q%s\n' "$DIM" "$_CM_COUNT" "$R"
      continue
    fi
    key="${_CM_KEYS[$((choice - 1))]}"
    case "$key" in
      v1 | v2 | pi) _cm_launch "$key" ;;
      shell)
        _cm_tab_title "shell"
        _cm_tty_fix
        # inside a tmux pane an interactive shell keeps the tab alive
        if [ -t 0 ] && [ -t 1 ]; then exec bash -i; fi
        return 0
        ;;
      quit) _cm_quit; return 1 ;;
    esac
  done
}

# Sourced (`bash -ic '. menu.sh'`) → leave the definitions to the caller.
# Executed (`bash menu.sh`) → run the menu, or a one-shot --fixterm.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --fixterm) fixterm ;;
    --repair) _cm_tty_fix ;;
    --versions)
      printf 'OpenCode V1: %s\n' "$(_cm_ver v1)"
      printf 'OpenCode V2: %s\n' "$(_cm_ver v2)"
      printf 'Free-pi (Pi): %s\n' "$(_cm_ver pi)"
      ;;
    --version) printf 'codemux menu %s\n' "$CM_MENU_VERSION" ;;
    *) _cm_menu_loop ;;
  esac
fi
