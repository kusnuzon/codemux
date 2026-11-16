# codemux:launcher begin  (managed by codemux — do not edit by hand)
# codemux:launcher version 31
# Termux banner + a numbered menu. Every interactive shell sources this block,
# so it stays small and fast:
#   * no agent binary is ever started to read a version (files only),
#   * the menu is answered with a typed number — there is no single-key reader,
#     because a full-screen agent can hand the terminal back in raw mode, where
#     one-key reads spin on EOF, swallow keys or leave the cursor hidden.
# Skip the menu: OPENCODE_NO_AUTO=1 bash

# Colours (empty when the output is not a terminal or NO_COLOR is set).
_oc_colors() {
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
_oc_ver() {
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

_oc_banner() {
  printf '\n'
  # each line: first 4 glyphs (OPEN) grey, remaining 4 glyphs (CODE) white
  local a bits=""
  for a in "█▀▀█ █▀▀█ █▀▀▀ █▀▀▄ █▀▀▀ █▀▀█ █▀▀▄ █▀▀▀" \
           "█  █ █▀▀▀ █▀▀  █  █ █    █  █ █  █ █▀▀ " \
           "▀▀▀▀ ▀    ▀▀▀▀ ▀  ▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀"; do
    printf '   %s%s%s%s%s%s\n' "$C1" "${a:0:19}" "$R" "$C2" "${a:19}" "$R"
  done
  # only the agents that are actually installed
  command -v opencode >/dev/null 2>&1 && bits="v1 $(_oc_ver v1)"
  command -v opencode-v2 >/dev/null 2>&1 &&
    bits="${bits:+$bits  ·  }v2 $(_oc_ver v2)"
  command -v pi >/dev/null 2>&1 &&
    bits="${bits:+$bits  ·  }free-pi $(_oc_ver pi)"
  if [ -n "$bits" ]; then
    printf '   %sTermux · Android arm64%s   %s%s%s\n\n' "$DIM" "$R" "$DIM" "$bits" "$R"
  else
    printf '   %sTermux · Android arm64%s   %sno agent yet%s\n\n' "$DIM" "$R" "$DIM" "$R"
  fi
}

# Menu rows. Every row is always offered; a missing agent is marked and the
# choice explains how to install it (the menu never installs by itself).
_oc_items() {
  _OC_KEYS=()
  _OC_NAMES=()
  _OC_DESCS=()
  local v
  if command -v opencode >/dev/null 2>&1; then
    _OC_DESCS+=("$(_oc_ver v1) · stable")
  else
    _OC_DESCS+=("not installed")
  fi
  _OC_KEYS+=("v1"); _OC_NAMES+=("OpenCode V1")
  if command -v opencode-v2 >/dev/null 2>&1; then
    _OC_DESCS+=("$(_oc_ver v2) · separate DB")
  else
    _OC_DESCS+=("not installed")
  fi
  _OC_KEYS+=("v2"); _OC_NAMES+=("OpenCode V2")
  if command -v pi >/dev/null 2>&1; then
    _OC_DESCS+=("$(_oc_ver pi) · free-pi agent")
  else
    _OC_DESCS+=("not installed")
  fi
  _OC_KEYS+=("pi"); _OC_NAMES+=("Free-pi (Pi)")
  _OC_KEYS+=("shell"); _OC_NAMES+=("Shell only"); _OC_DESCS+=("no agent")
  _OC_KEYS+=("quit"); _OC_NAMES+=("Quit"); _OC_DESCS+=("close Termux")
  _OC_COUNT="${#_OC_KEYS[@]}"
}

_oc_menu() {
  local i pad
  printf '  %s───────────────────────────────────────────%s\n' "$DIM" "$R"
  for ((i = 0; i < _OC_COUNT; i++)); do
    printf -v pad '%-15s' "${_OC_NAMES[$i]}"
    printf '  %s%d%s  %s%s%s  %s%s%s\n' \
      "$BOLD" "$((i + 1))" "$R" "$BOLD" "$pad" "$R" "$DIM" "${_OC_DESCS[$i]}$R"
  done
  printf '  %s───────────────────────────────────────────%s\n' "$DIM" "$R"
  printf '  %stype a number, then Enter%s   %sq quit%s\n\n' "$DIM" "$R" "$DIM" "$R"
}

# A full-screen agent can hand the terminal back inside the alternate screen (or
# in the middle of an OSC string), and Termux then keeps showing the last frame
# while the shell below is alive — keys do nothing and only `exit` works. Reset
# every mode a TUI can switch on, then clear and home so the prompt is redrawn.
_oc_tty_fix() {
  [ -t 1 ] || return 0
  if [ -r /dev/tty ]; then
    command -v stty >/dev/null 2>&1 && stty sane </dev/tty 2>/dev/null
  fi
  printf '\007\033\\\033\\\033[?2026l\033[?2031l\033[?1049l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?1016l\033[?1004l\033[?2004l\033[?1l\033>\033[!p\033[r\033[?6l\033[?7h\033(B\033[0m\033[?25h\033[2J\033[H'
  return 0
}

# Run one component. Missing agents are reported, never installed from here.
_oc_launch_component() {
  local key="$1" cmd="" name=""
  case "$key" in
    v1) cmd="opencode"; name="OpenCode V1" ;;
    v2) cmd="opencode-v2"; name="OpenCode V2" ;;
    pi) cmd="pi"; name="Free-pi (Pi)" ;;
    *) return 1 ;;
  esac
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '\n  %s%s is not installed%s — run: %scodemux install%s\n\n' \
      "$BOLD" "$name" "$R" "$ACC" "$R"
    return 1
  fi
  printf '  %s→ %s%s\n\n' "$DIM" "$name" "$R"
  "$cmd"
  # repair the terminal whatever the exit code was
  _oc_tty_fix
  if [ -t 1 ] && [ -r /dev/tty ]; then
    exec 0</dev/tty 2>/dev/null || true
  fi
  return 0
}

# The menu: print the rows, read one line, act. A dead stdin (EOF) or `q`
# leaves the menu; Ctrl+C (rc > 128) only cancels the answer.
_oc_menu_loop() {
  local choice rc key
  while :; do
    _oc_items
    _oc_colors
    printf '\033[2J\033[H'
    _oc_banner
    _oc_menu
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
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$_OC_COUNT" ]; then
      printf '  %stype a number from 1 to %d, or q%s\n' "$DIM" "$_OC_COUNT" "$R"
      continue
    fi
    key="${_OC_KEYS[$((choice - 1))]}"
    case "$key" in
      v1 | v2 | pi) _oc_launch_component "$key" ;;
      shell) printf '\n'; _oc_tty_fix; return 0 ;;
      quit) printf '\n'; return 1 ;;
    esac
  done
}

menu() { _oc_menu_loop; }

version() {
  printf 'OpenCode V1: %s\n' "$(_oc_ver v1)"
  printf 'OpenCode V2: %s\n' "$(_oc_ver v2)"
  printf 'Free-pi (Pi): %s\n' "$(_oc_ver pi)"
}

# Welcome a fresh interactive shell with the menu (skip: OPENCODE_NO_AUTO=1).
if [ -z "${OPENCODE_NO_AUTO:-}" ] && [ -t 0 ] && [ -t 1 ] && [ -z "${OPENCODE_AUTO_LAUNCHED:-}" ]; then
  export OPENCODE_AUTO_LAUNCHED=1
  if _oc_menu_loop; then
    printf '  %sBack to the shell.%s\n\n' "$DIM" "$R"
  else
    printf '  %sGoodbye.%s\n\n' "$DIM" "$R"
    exit 0
  fi
fi
# codemux:launcher end
