# codemux:launcher begin  (managed by codemux — do not edit by hand)
# Termux startup banner + menu block. Change it via the codemux repo template,
# then run `codemux install`. Skip the menu: OPENCODE_NO_AUTO=1 bash
# The menu uses arrow keys (↑/↓) + Enter, or the row number and q.
# Components that are not installed are not offered by the menu.
# Skip everything: OPENCODE_NO_AUTO=1 bash
_oc_ver() {
  local v=""
  case "$1" in
    v1)
      # real payload version; dpkg-query can lag behind the payload
      if command -v opencode >/dev/null 2>&1; then
        v="$(timeout 8 opencode --version 2>/dev/null | head -n 1 | tr -d '[:space:]')"
      fi
      [ -n "$v" ] || v="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null)"
      ;;
    v2) v="$(cat "$PREFIX/share/opencode-v2/VERSION" 2>/dev/null)" ;;
  esac
  printf '%s' "${v:-?}"
}

_oc_colors() {
  C1=''; C2=''; ACC=''; DIM=''; BOLD=''; HL=''; R=''
  if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    C1=$'\033[38;5;243m'   # OPEN — dark grey
    C2=$'\033[38;5;231m'   # CODE — white
    ACC=$'\033[38;5;213m'; DIM=$'\033[2m'
    BOLD=$'\033[1m'; HL=$'\033[48;5;236m'; R=$'\033[0m'
  fi
}

_oc_banner() {
  printf '\n'
  # each line: first 4 glyphs (OPEN) grey, remaining 4 glyphs (CODE) white
  local a
  for a in "█▀▀█ █▀▀█ █▀▀▀ █▀▀▄ █▀▀▀ █▀▀█ █▀▀▄ █▀▀▀" \
           "█  █ █▀▀▀ █▀▀  █  █ █    █  █ █  █ █▀▀ " \
           "▀▀▀▀ ▀    ▀▀▀▀ ▀  ▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀"; do
    printf '   %s%s%s%s%s%s\n' "$C1" "${a:0:19}" "$R" "$C2" "${a:19}" "$R"
  done
  # Only the installed components are listed (V1 only / V2 only / both).
  local bits=""
  if command -v opencode >/dev/null 2>&1; then
    bits="v1 $(_oc_ver v1)"
  fi
  if command -v opencode-v2 >/dev/null 2>&1; then
    bits="${bits:+$bits  ·  }v2 $(_oc_ver v2)"
  fi
  if [ -n "$bits" ]; then
    printf '   %sTermux · Android arm64%s   %s%s%s\n\n' "$DIM" "$R" "$DIM" "$bits" "$R"
  else
    printf '   %sTermux · Android arm64%s   %sno OpenCode yet%s\n\n' "$DIM" "$R" "$DIM" "$R"
  fi
}

# Menu items depend on what is installed: a component that is not installed is
# not offered, so a V1-only or V2-only install shows only what it can run.
_oc_items() {
  _OC_KEYS=()
  _OC_NAMES=()
  _OC_DESCS=()
  if command -v opencode >/dev/null 2>&1; then
    _OC_KEYS+=("v1"); _OC_NAMES+=("OpenCode V1"); _OC_DESCS+=("stable · legacy DB")
  fi
  if command -v opencode-v2 >/dev/null 2>&1; then
    _OC_KEYS+=("v2"); _OC_NAMES+=("OpenCode V2"); _OC_DESCS+=("new · separate DB")
  fi
  _OC_KEYS+=("shell"); _OC_NAMES+=("Shell only"); _OC_DESCS+=("no opencode")
  _OC_KEYS+=("quit"); _OC_NAMES+=("Quit"); _OC_DESCS+=("close Termux")
  _OC_COUNT="${#_OC_KEYS[@]}"
}

# One menu row: <index> <selected index>
_oc_row() {
  local idx="$1" sel="$2" arrow pad namepad
  if [ "$idx" = "$sel" ]; then
    arrow="$ACC❯$R"; pad="$HL"
  else
    arrow=" "; pad=""
  fi
  printf -v namepad '%-13s' "${_OC_NAMES[$idx]}"
  printf '  %s %s%s%s%s %s%s%s%s  %s%s%s\033[K\n' \
    "$arrow" "$pad" "$BOLD" "$((idx + 1))" "$R" \
    "$pad" "$BOLD" "$namepad" "$R" \
    "$pad" "$DIM" "${_OC_DESCS[$idx]}$R"
}

# Only the option rows (no rules or hints) — used to redraw the selection
# while arrow keys are pressed, so the screen does not flicker.
_oc_rows() {
  local sel="$1" i
  for ((i = 0; i < _OC_COUNT; i++)); do
    _oc_row "$i" "$sel"
  done
}

_oc_menu() {
  printf '  %s───────────────────────────────────────────────%s\n' "$DIM" "$R"
  _oc_rows "$1"
  printf '  %s───────────────────────────────────────────────%s\n' "$DIM" "$R"
  printf '  %s↑/↓ select%s   %sEnter run%s   %s1-%d/q%s   %sCtrl+C cancel%s\n\n' \
    "$DIM" "$R" "$DIM" "$R" "$DIM" "$_OC_COUNT" "$R" "$DIM" "$R"
}

# Redraw only the option rows: from the blank line below the menu move up
# (rows + rule + hint) lines, write the rows, then move down 3 lines.
_oc_redraw() {
  printf '\033[%dA' "$((_OC_COUNT + 3))"
  _oc_rows "$1"
  printf '\033[3B'
}

_oc_read_key() {
  KEY=""
  _oc_int=0
  # Wait at most 0.2 s per round for a key: that way a Ctrl+C signal is handled
  # before the next key, so no key gets swallowed (and the cursor is never left
  # hidden).
  while :; do
    IFS= read -rsn1 -t 0.2 KEY && break
    if [ "${_oc_int:-0}" = "1" ]; then KEY="cancel"; return 0; fi
  done
  case "$KEY" in
    $'\033')
      local rest="" ch=""
      # Read the rest of the escape sequence byte by byte: if the bytes arrive
      # separately (e.g. right after Ctrl+C), the arrow key must not be lost.
      while [ "${#rest}" -lt 2 ]; do
        IFS= read -rsn1 -t 0.25 ch || break
        rest+="$ch"
      done
      case "$rest" in
        '[A') KEY="up" ;;
        '[B') KEY="down" ;;
        '[C') KEY="right" ;;
        '[D') KEY="left" ;;
        *) KEY="esc" ;;
      esac
      ;;
    ''|$'\r'|$'\n') KEY="enter" ;;
    k|K) KEY="up" ;;
    j|J) KEY="down" ;;
  esac
}

# Version that is actually installed right now (empty when undetectable).
# Used to filter out stale cache rows.
_oc_live_ver() {
  local pre="${PREFIX:-/data/data/com.termux/files/usr}"
  case "$1" in
    opencode-v1) cat "$pre/share/opencode/VERSION" 2>/dev/null ;;
    opencode-v2) cat "$pre/share/opencode-v2/VERSION" 2>/dev/null ;;
    *) : ;;
  esac
}

# Update notice line (reads the codemux cache; never blocks the prompt).
_oc_update_notice() {
  local dir="$HOME/.config/codemux"
  local cache="$dir/update-cache.tsv" stamp="$dir/.update-check.stamp"
  local age=-1 s_age=999999 n=0 v1 v2 rows stale=0 unknown=0 wait_h=6
  v1="$(_oc_live_ver opencode-v1)"
  v2="$(_oc_live_ver opencode-v2)"
  if [ -f "$cache" ]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ) / 3600 ))
    # A row is stale when the "local" version in the cache differs from the
    # installed one (e.g. the payload was replaced outside the menu). Stale
    # rows are hidden and the cache is forced to re-check.
    # "na" = upstream check failed (network down/timeout). Do not trust it for
    # 24 h: retry at most once per hour.
    { read -r n; read -r rows; read -r stale; read -r unknown; } < <(awk -F'\t' -v v1="$v1" -v v2="$v2" '
      $4=="update" {
        if (($1=="opencode-v1" && v1!="" && $2!=v1) ||
            ($1=="opencode-v2" && v2!="" && $2!=v2)) { stale=1; next }
        out = out sep (($1=="apt") ? $2 " apt packages" : $1 " " $3); sep = " · "
        n++
      }
      $4=="na" { unknown++ }
      END { print n+0; print out; print (stale?1:0); print unknown+0 }' "$cache" 2>/dev/null)
    n="${n// /}"
    if [ "${n:-0}" -gt 0 ] && [ -n "$rows" ]; then
      printf '   %supdate available:%s %s\n' "$ACC" "$R" "$rows"
      printf '   %srun: codemux upgrade%s\n\n' "$DIM" "$R"
    fi
    [ "${stale:-0}" = "1" ] && age=999999 # cache mismatch → re-check
    if [ "${unknown:-0}" -gt 0 ]; then
      age=999999 # incomplete result → retry sooner
      wait_h=1
    fi
  fi
  # check in the background when the cache is stale; at most once every 6 h
  command -v codemux >/dev/null 2>&1 || return 0
  if [ -f "$stamp" ]; then
    s_age=$(( ( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ) / 3600 ))
  fi
  if { [ ! -f "$cache" ] || [ "$age" -ge 24 ]; } && [ "$s_age" -ge "$wait_h" ]; then
    mkdir -p "$dir" 2>/dev/null
    : >"$stamp" 2>/dev/null
    ( codemux update-check --quiet >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
}

_oc_cursor_hide() { printf '\033[?25l'; }
_oc_cursor_show() { printf '\033[?25h'; }

# Returns 0 = continue to the shell, 1 = exit Termux.
_oc_menu_loop() {
  local sel=0 full=1 i saved key choice_file="$HOME/.local/state/opencode-choice"
  _oc_items
  # Restore the last choice (accepts the old numeric format too).
  saved="$(cat "$choice_file" 2>/dev/null)"
  case "$saved" in
    1) saved="v1" ;;
    2) saved="v2" ;;
    3) saved="shell" ;;
    4) saved="quit" ;;
  esac
  for ((i = 0; i < _OC_COUNT; i++)); do
    [ "${_OC_KEYS[$i]}" = "$saved" ] && sel="$i"
  done

  # The cursor is hidden while the menu is open: otherwise it blinks on the
  # bottom row and looks like a glitch when moving up/down. Ctrl+C only
  # cancels the current key (it does not kill the menu), so the cursor is
  # never left hidden.
  trap '_oc_int=1' INT
  _oc_cursor_hide
  while :; do
    if [ "$full" = "1" ]; then
      printf '\033[2J\033[H'
      _oc_banner
      _oc_update_notice
      _oc_menu "$sel"
      full=0
    else
      _oc_redraw "$sel"
    fi
    _oc_read_key

    case "$KEY" in
      up|left)   sel=$(( (sel + _OC_COUNT - 1) % _OC_COUNT )) ;;
      down|right) sel=$(( (sel + 1) % _OC_COUNT )) ;;
      enter)
        key="${_OC_KEYS[$sel]}"
        case "$key" in
          v1|v2)
            mkdir -p "$HOME/.local/state" 2>/dev/null
            printf '%s\n' "$key" >"$choice_file" 2>/dev/null
            printf '\n'
            # opencode needs a visible cursor; hide it again when back in the menu
            _oc_cursor_show
            if [ "$key" = "v1" ]; then
              printf '  %s→ OpenCode V1%s\n\n' "$DIM" "$R"
              opencode
            else
              printf '  %s→ OpenCode V2%s\n\n' "$DIM" "$R"
              opencode-v2
            fi
            # after opencode closes (e.g. you type exit), return to the menu
            _oc_cursor_hide
            full=1
            ;;
          shell) printf '\n'; return 0 ;;
          quit) printf '\n'; return 1 ;;
        esac
        ;;
      [1-9])
        # number keys select a row directly (1..N)
        if [ "$KEY" -le "$_OC_COUNT" ]; then sel=$((KEY - 1)); fi
        ;;
      q|Q) sel=$((_OC_COUNT - 1)); return 1 ;;
      esc|cancel|ctrl-c) ;;
    esac
  done
}

# One command guide row.
_oc_cmd_row() {
  printf '    %s%-13s%s%s\n' "$ACC" "$1" "$R" "$2"
}

# Short guide shown after choosing "Shell only".
_oc_guide() {
  printf '  %sShell only selected — opencode was not started.%s\n\n' "$DIM" "$R"
  printf '  %sAvailable commands:%s\n' "$BOLD" "$R"
  _oc_cmd_row menu          'back to the choice menu'
  command -v opencode >/dev/null 2>&1 &&
    _oc_cmd_row opencode    'run OpenCode V1 directly'
  command -v opencode-v2 >/dev/null 2>&1 &&
    _oc_cmd_row opencode-v2 'run OpenCode V2 directly'
  [ -f "$PREFIX/share/opencode-v2/doctor.sh" ] &&
    _oc_cmd_row doctor      'health check for the OpenCode V2 install'
  _oc_cmd_row version       'show the installed OpenCode versions'
  command -v kuota >/dev/null 2>&1 &&
    _oc_cmd_row kuota       'estimated remaining free-model quota'
  _oc_cmd_row codemux       'check & maintain Termux (check / install / status)'
  _oc_cmd_row 'keluar|exit' 'close Termux'
  printf '\n  %sType %smenu%s at any time to return to this menu.%s\n' "$DIM" "$BOLD" "$R" "$R"
  printf '  %sInside opencode, type exit or press Ctrl+C → back to the menu.%s\n\n' "$DIM" "$R"
}

# Run the launcher; used at startup and by the `menu` command.
_oc_launcher() {
  _oc_colors
  if _oc_menu_loop; then
    trap - INT
    _oc_cursor_show
    printf '  %sBack to the shell.%s\n\n' "$DIM" "$R"
    _oc_guide
  else
    trap - INT
    _oc_cursor_show
    printf '  %sGoodbye.%s\n\n' "$DIM" "$R"
    exit 0
  fi
  unset C1 C2 ACC DIM BOLD HL R KEY
}

menu() { _oc_launcher; }
version() {
  local found=0
  if command -v opencode >/dev/null 2>&1; then
    printf 'OpenCode V1 : %s\n' "$(_oc_ver v1)"
    found=1
  fi
  if command -v opencode-v2 >/dev/null 2>&1; then
    printf 'OpenCode V2 : %s\n' "$(_oc_ver v2)"
    found=1
  fi
  [ "$found" -eq 1 ] || printf 'no OpenCode installed — run: codemux install\n'
}
doctor() {
  if [ -f "$PREFIX/share/opencode-v2/doctor.sh" ]; then
    bash "$PREFIX/share/opencode-v2/doctor.sh" "$@"
  else
    printf 'doctor.sh not found (OpenCode V2 is not installed).\n'
  fi
}
keluar() { exit 0; }

if [ -z "$OPENCODE_NO_AUTO" ] && [ -t 0 ] && [ -t 1 ] && [ -z "$OPENCODE_AUTO_LAUNCHED" ]; then
  export OPENCODE_AUTO_LAUNCHED=1
  _oc_launcher
fi
# codemux:launcher end
