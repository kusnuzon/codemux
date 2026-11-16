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

CM_MENU_VERSION="5"

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

# ---------------------------------------------------------------------------
# launch log
# ---------------------------------------------------------------------------
# Every row you pick is recorded, so an error (a broken ad card, an agent that
# exits at once, a missing binary) can be audited afterwards instead of guessed:
#
#   ~/.config/codemux/logs/menu.log             one line per launch, rotated
#   ~/.config/codemux/logs/menu-<stamp>.log     the whole story of a failed run
#
# While the agent runs its pane output is copied with `tmux pipe-pane`, which
# touches no terminal mode and still records what was printed. A successful run
# deletes its detail file (the summary line stays); a failed one keeps the last
# CM_LOG_TAIL lines, because by then the pane is usually already wiped.
# CODEMUX_LOG_DIR overrides the directory (the tests use it).
CM_LOG_MAX=64     # KiB of menu.log kept before it is rotated
CM_LOG_KEEP=40    # detail files kept (the oldest are pruned)
CM_LOG_TAIL=120   # lines of pane output copied into a failed-run log
# A counter keeps two launches in the same second apart: without it the second
# launch would reuse the first file name and a success would delete its evidence.
CM_LOG_SEQ=0
CM_LOG_ERRPAT='error|fatal|panic|traceback|exception|failed|denied|refused|timeout|no such file|not found|\bads?\b|advert'

_cm_logdir() { # → directory, created
  local d="${CODEMUX_LOG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/codemux/logs}"
  mkdir -p "$d" 2>/dev/null || return 1
  printf '%s' "$d"
}

# Printable tail of the raw pane stream: escape sequences and control bytes are
# dropped so the log reads like a screen, not like a terminal dump.
_cm_pane_tail() { # <raw-file> <lines>
  local raw="$1" n="${2:-$CM_LOG_TAIL}"
  [ -f "$raw" ] && [ -s "$raw" ] || return 0
  tail -c 400000 "$raw" 2>/dev/null |
    sed -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' \
      -e 's/\x1b\[[0-9;?!<=>]*[a-zA-Z@`~]//g' \
      -e 's/\x1bP[^\x1b]*\x1b\\//g' \
      -e 's/\x1b[()][A-Z0-9]//g' -e 's/\x1b[=>]//g' \
      -e 's/\\\[[0-9;?!<=>]*[a-zA-Z@`~]//g' 2>/dev/null |
    tr -d '\r' 2>/dev/null |
    sed -e 's/[^[:print:][:space:]]//g' 2>/dev/null |
    grep -v '^[[:space:]]*$' 2>/dev/null |
    tail -n "$n" 2>/dev/null || true
  return 0
}

_cm_capture_start() { # copy the pane stream into $_CM_RAW
  _CM_PIPED=0; _CM_PIPE_OPEN=0
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  [ -n "${_CM_RAW:-}" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  # -o: do not replace a pipe somebody else already opened.
  tmux pipe-pane -o -t "$TMUX_PANE" "cat >> '$_CM_RAW'" 2>/dev/null && {
    _CM_PIPED=1
    _CM_PIPE_OPEN=1
  }
  return 0
}

_cm_capture_stop() {
  # _CM_PIPED stays set: it tells _cm_log_finish that tmux may still be flushing.
  [ "${_CM_PIPE_OPEN:-0}" = 1 ] || return 0
  tmux pipe-pane -t "${TMUX_PANE:-}" 2>/dev/null || true
  _CM_PIPE_OPEN=0
  return 0
}

_cm_log_start() { # <row-key> <name> <command>
  _CM_LOG=""; _CM_RAW=""; _CM_PIPED=0; _CM_PIPE_OPEN=0
  _CM_T0="$(date +%s 2>/dev/null || printf 0)"
  local key="$1" name="$2" cmd="$3" d term="plain shell"
  d="$(_cm_logdir)" || return 0
  _CM_LOGDIR="$d"
  # pid + counter: two shells (or two launches in one second) must never share a
  # name, otherwise a clean run deletes the evidence of the previous failure.
  CM_LOG_SEQ=$((CM_LOG_SEQ + 1))
  _CM_LOGID="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf %s 0)-$$-$CM_LOG_SEQ"
  _CM_LOG="$d/menu-$_CM_LOGID.log"
  _CM_RAW="$d/.raw.$$.$_CM_LOGID"
  : >"$_CM_RAW" 2>/dev/null || _CM_RAW=""
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    term="tmux $(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) · $(tmux -V 2>/dev/null)"
  elif [ -n "${TMUX:-}" ]; then
    term="tmux (tmux missing)"
  fi
  {
    printf 'codemux menu launch\n'
    printf 'status:   running\n'
    printf 'started:  %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
    printf 'row:      %s\n' "$key"
    printf 'name:     %s\n' "$name"
    printf 'command:  %s\n' "${cmd:-(not installed)}"
    printf 'cwd:      %s\n' "$PWD"
    printf 'term:     %s\n' "$term"
    printf 'columns:  %sx%s\n' "${COLUMNS:-?}" "${LINES:-?}"
    printf 'shell:    bash %s\n' "${BASH_VERSION%%(*}"
    printf 'versions: v1 %s · v2 %s · free-pi %s\n' \
      "$(_cm_ver v1)" "$(_cm_ver v2)" "$(_cm_ver pi)"
    printf -- '---\n'
  } >"$_CM_LOG" 2>/dev/null || _CM_LOG=""
  return 0
}

# Close the launch: a failure keeps the detail file, a clean run deletes it and
# leaves one line in menu.log. `missing` marks a row whose binary is not there.
_cm_log_finish() { # <rc> <ok|failed|missing>
  local rc="$1" status="$2" dur=0 tail_txt="" failed=0 keep=0 d
  local piped="${_CM_PIPED:-0}" tries=0
  _cm_capture_stop
  [ -n "${_CM_T0:-}" ] && dur=$(( $(date +%s 2>/dev/null || printf 0) - _CM_T0 ))
  # tmux closes the pipe asynchronously and `cat` only flushes when it sees EOF,
  # so the last lines are polled for a moment instead of read once and lost.
  while : ; do
    tail_txt="$(_cm_pane_tail "${_CM_RAW:-}" "$CM_LOG_TAIL")"
    [ -n "$tail_txt" ] && break
    [ "$piped" = 1 ] && [ "$tries" -lt 8 ] || break
    tries=$((tries + 1))
    sleep 0.1
  done
  [ "$rc" -ne 0 ] && failed=1
  [ "$status" = missing ] && failed=1
  if [ -n "$tail_txt" ]; then
    printf '%s' "$tail_txt" | grep -qiE "$CM_LOG_ERRPAT" && failed=1
  fi
  [ "$failed" -eq 1 ] && keep=1
  # ok only when nothing went wrong; missing keeps its own label so a row whose
  # binary is absent is not reported as a crash.
  [ "$keep" -eq 0 ] && status=ok
  [ "$status" = failed ] && [ "$rc" -eq 0 ] && [ "$keep" -eq 0 ] && status=ok
  d="${_CM_LOGDIR:-}"
  if [ -n "$d" ] && [ -n "${_CM_LOG:-}" ]; then
    {
      printf 'rc:       %s\n' "$rc"
      printf 'duration: %ss\n' "$dur"
      if [ "$keep" -eq 1 ]; then
        printf 'status:   %s\n' "${status^^}"
      else
        printf 'status:   OK\n'
      fi
      if [ -n "$tail_txt" ]; then
        printf -- '--- pane tail (last %s lines) ---\n' "$CM_LOG_TAIL"
        printf '%s\n' "$tail_txt"
      fi
    } >>"$_CM_LOG" 2>/dev/null || true
    printf '%s  %-5s %-14s rc=%s %ss %s %s\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "${_CM_ROW:-?}" \
      "${_CM_NAME:-?}" "$rc" "$dur" \
      "$([ "$keep" -eq 1 ] && printf '%s' "${status^^}" || printf OK)" \
      "$(basename "$_CM_LOG" 2>/dev/null)" >>"$d/menu.log" 2>/dev/null || true
    _cm_log_prune
    if [ "$keep" -eq 0 ]; then
      rm -f "$_CM_LOG" 2>/dev/null || true
      _CM_LOG=""
    fi
  fi
  [ -n "${_CM_RAW:-}" ] && rm -f "$_CM_RAW" 2>/dev/null
  return 0
}

_cm_log_prune() {
  local d="${_CM_LOGDIR:-}" f size
  [ -n "$d" ] || return 0
  # menu.log is one line per launch; keep two generations of it.
  size="$(wc -c <"$d/menu.log" 2>/dev/null | tr -d ' ')"
  if [ "${size:-0}" -gt $((CM_LOG_MAX * 1024)) ] 2>/dev/null; then
    mv -f "$d/menu.log" "$d/menu.log.1" 2>/dev/null || true
  fi
  # Detail files: newest CM_LOG_KEEP win (names sort by time).
  # shellcheck disable=SC2044,SC2012  # our own names, no spaces
  for f in $(ls -1d "$d"/menu-*.log 2>/dev/null | sort | head -n "-$CM_LOG_KEEP"); do
    rm -f "$f" 2>/dev/null || true
  done
  # Raw streams from a launch that was killed must not pile up.
  command -v find >/dev/null 2>&1 &&
    find "$d" -maxdepth 1 -name '.raw.*' -mmin +120 -exec rm -f {} + 2>/dev/null
  return 0
}

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
  _CM_ROW="$key"; _CM_NAME="$name"
  _cm_log_start "$key" "$name" "$cmd"
  if [ -z "$cmd" ] || ! command -v "$cmd" >/dev/null 2>&1; then
    _cm_log_finish 127 missing
    printf '\n  %s%s is not installed%s — run: %scodemux install%s\n' \
      "$BOLD" "$name" "$R" "$ACC" "$R"
    printf '  %slogged: %s%s\n\n' "$DIM" "$_CM_LOG" "$R"
    return 1
  fi
  _cm_tab_title "$key"
  printf '  %s→ %s%s\n\n' "$DIM" "$name" "$R"
  _cm_capture_start
  "$cmd"
  rc=$?
  _cm_capture_stop
  # Close the log before the pane is wiped: the tail is the only trace left.
  _cm_log_finish "$rc" failed
  # repair the pane whatever the exit code was, then mark the tab as a menu again
  _cm_tty_fix
  _cm_tab_title "menu"
  if [ "$rc" -ne 0 ] && [ -n "$_CM_LOG" ]; then
    printf '\n  %s%s exited with %s — log: %s%s\n\n' \
      "$DIM" "$name" "$rc" "$_CM_LOG" "$R"
  fi
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
