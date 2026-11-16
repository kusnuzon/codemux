# codemux:launcher begin  (managed by codemux — do not edit by hand)
# codemux:launcher version 24
# Termux startup banner + menu block. Change it via the codemux repo template,
# then run `codemux install`. Skip the menu: OPENCODE_NO_AUTO=1 bash
# The menu uses arrow keys (↑/↓) + Enter, or the row number and q.
# Every row is always offered: a component that is not installed is marked
# "not installed", and choosing it asks for confirmation before installing.
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
    pi)
      # free-pi writes no VERSION file into its agent dir, so the number comes
      # from the package npx actually installed (read straight from the
      # manifest: `free-pi-cli --version` boots node and is too slow for a
      # menu redraw).
      v="$(cat "$HOME/.free-pi/agent/VERSION" 2>/dev/null)"
      if [ -z "$v" ]; then
        local pj
        for pj in "$HOME"/.npm/_npx/*/node_modules/free-pi-cli/package.json; do
          [ -f "$pj" ] || continue
          v="$(grep -m1 -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$pj" 2>/dev/null |
               sed 's/.*"\([^"]*\)"$/\1/')"
          [ -n "$v" ] && break
        done
      fi
      if [ -z "$v" ] && command -v free-pi-cli >/dev/null 2>&1; then
        v="$(timeout 5 free-pi-cli --version 2>/dev/null | head -n 1 | tr -d '[:space:]')"
        v="${v#free-pi-cli}"
      fi
      ;;
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
  if command -v pi >/dev/null 2>&1; then
    bits="${bits:+$bits  ·  }free-pi $(_oc_ver pi)"
  fi
  if [ -n "$bits" ]; then
    printf '   %sTermux · Android arm64%s   %s%s%s\n\n' "$DIM" "$R" "$DIM" "$bits" "$R"
  else
    printf '   %sTermux · Android arm64%s   %sno agent yet%s\n\n' "$DIM" "$R" "$DIM" "$R"
  fi
}

# Every component row is always shown. A missing one is marked "not installed"
# and choosing it offers to install it (see _oc_launch_component).
_oc_items() {
  _OC_KEYS=()
  _OC_NAMES=()
  _OC_DESCS=()
  _OC_STATE=()
  if command -v opencode >/dev/null 2>&1; then
    _OC_KEYS+=("v1"); _OC_NAMES+=("OpenCode V1")
    _OC_DESCS+=("$(_oc_ver v1) · stable · legacy DB"); _OC_STATE+=("installed")
  else
    _OC_KEYS+=("v1"); _OC_NAMES+=("OpenCode V1")
    _OC_DESCS+=("not installed · Enter to install"); _OC_STATE+=("missing")
  fi
  if command -v opencode-v2 >/dev/null 2>&1; then
    _OC_KEYS+=("v2"); _OC_NAMES+=("OpenCode V2")
    _OC_DESCS+=("$(_oc_ver v2) · new · separate DB"); _OC_STATE+=("installed")
  else
    _OC_KEYS+=("v2"); _OC_NAMES+=("OpenCode V2")
    _OC_DESCS+=("not installed · Enter to install"); _OC_STATE+=("missing")
  fi
  # Two rows for the same agent: plain pi, and pi inside a tmux session (so it
  # can be detached with Ctrl+b d and reattached later). The version probe runs
  # once and feeds both rows.
  local pidesc="not installed · Enter to install" pistate="missing"
  if command -v pi >/dev/null 2>&1; then
    pidesc="$(_oc_ver pi) · free-pi agent"; pistate="installed"
  fi
  _OC_KEYS+=("pi"); _OC_NAMES+=("Free-pi (Pi)")
  _OC_DESCS+=("$pidesc"); _OC_STATE+=("$pistate")
  _OC_KEYS+=("pitmux"); _OC_NAMES+=("Free-pi (Pi) · tmux")
  if [ "$pistate" = "installed" ]; then
    _OC_DESCS+=("$(_oc_ver pi) · inside tmux")
  else
    _OC_DESCS+=("not installed · Enter to install")
  fi
  _OC_STATE+=("$pistate")
  # `bashrc` is not a row: the block is edited with `b` (see the hint line).
  _OC_KEYS+=("shell"); _OC_NAMES+=("Shell only"); _OC_DESCS+=("no agent"); _OC_STATE+=("installed")
  _OC_KEYS+=("quit"); _OC_NAMES+=("Quit"); _OC_DESCS+=("close Termux"); _OC_STATE+=("installed")
  _OC_COUNT="${#_OC_KEYS[@]}"
  # Column width follows the longest name: adding a row must not misalign the
  # descriptions (a hardcoded width did exactly that once).
  local n w=13
  for n in "${_OC_NAMES[@]}"; do
    [ "${#n}" -gt "$w" ] && w="${#n}"
  done
  _OC_NAMEW=$((w + 1))
}

# One menu row: <index> <selected index>
_oc_row() {
  local idx="$1" sel="$2" arrow pad namepad
  if [ "$idx" = "$sel" ]; then
    arrow="$ACC❯$R"; pad="$HL"
  else
    arrow=" "; pad=""
  fi
  printf -v namepad '%-*s' "${_OC_NAMEW:-14}" "${_OC_NAMES[$idx]}"
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
  printf '  %s↑/↓ select%s   %sEnter run/install%s   %s1-%d/q%s   %sb .bashrc%s   %sCtrl+C cancel%s\n\n' \
    "$DIM" "$R" "$DIM" "$R" "$DIM" "$_OC_COUNT" "$R" "$DIM" "$R" "$DIM" "$R"
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
  #
  # A component that exits can leave stdin at EOF (a terminal that a full-screen
  # UI handed back, or a closed fd): `read` then fails instantly and forever, so
  # a plain retry loop spins at 100% CPU and the menu never comes back. Count the
  # failures, reopen the terminal once, and give up with `eof` if it is gone.
  local empty=0 rc
  _oc_eof=0
  while :; do
    IFS= read -rsn1 -t 0.2 KEY && break
    rc=$?
    if [ "${_oc_int:-0}" = "1" ]; then KEY="cancel"; return 0; fi
    # rc > 128 means the timeout expired (128+SIGALRM): the fd is still fine,
    # so the empty-failure counter has to start over.
    if [ "$rc" -gt 128 ]; then
      empty=0
      continue
    fi
    empty=$((empty + 1))
    if [ "$empty" -ge 5 ]; then
      if [ -r /dev/tty ] && exec 0</dev/tty 2>/dev/null; then
        empty=0
        continue
      fi
      # No terminal left to read from: report EOF so the caller can leave the
      # menu instead of redrawing it in a loop that no key can ever end.
      KEY="eof"
      _oc_eof=1
      return 0
    fi
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

# Quota warning (one short line, only when `quota` is installed and the free
# model usage is close to the daily limit). Read-only, no network, ~0.1 s.
_oc_quota_notice() {
  command -v quota >/dev/null 2>&1 || return 0
  local line
  line="$(quota --warn 2>/dev/null)" || true
  [ -n "$line" ] && printf '   %s%s%s\n\n' "$ACC" "$line" "$R"
  return 0
}

# Meta of one row: <key> -> "<binary>|<label>|<missing text>".
# Every row that can be installed goes through the same confirmation path, so
# Pi and V1/V2 cannot drift apart.
_oc_meta() {
  case "$1" in
    v1) printf 'opencode|OpenCode V1|V1' ;;
    v2) printf 'opencode-v2|OpenCode V2|V2' ;;
    pi) printf 'pi|Free-pi (Pi)|Pi' ;;
    # Same binary and same install path as `pi`; only the launcher differs.
    pitmux) printf 'pi|Free-pi (Pi) · tmux|Pi' ;;
    *) return 1 ;;
  esac
}

# One question for every installable row: "… is not installed yet. Install it
# now? [y/N]". Enter alone is a no, and the answer never changes anything else.
_oc_confirm_install() {
  local label="$1" ans=""
  printf '\n  %s%s is not installed yet.%s\n' "$BOLD" "$label" "$R"
  printf '  Install it now? [y/N] '
  _oc_cursor_show
  IFS= read -r ans || ans=""
  _oc_cursor_hide
  case "$ans" in
    y | Y | yes | YES | Ya | ya) return 0 ;;
  esac
  printf '  %snot installed — nothing changed.%s\n\n' "$DIM" "$R"
  return 1
}

# free-pi has no session tabs of its own. OpenCode V2 shows open sessions as
# tabs and switches them with ctrl+tab / alt+down (session.tab.next) and
# ctrl+shift+tab / alt+up (session.tab.previous). The closest equivalent is one
# tmux window per pi inside a single session named `pi`: the tmux status line
# becomes the tab strip. The keys below only act inside that session and are
# passed through everywhere else, so the rest of tmux keeps its defaults.
# ctrl+shift+tab is not reachable here (tmux never decodes that chord from a
# plain terminal), so shift+tab stands in for it; both are echoed as-is.
_oc_pi_tmux_tabs() {
  # A new window (C-b c) starts a NEW pi session instead of a bare shell, and
  # every tab keeps the name "pi" until pi renames it to the current prompt.
  tmux set-option -t pi default-command 'OPENCODE_NO_AUTO=1 bash -ic pi' 2>/dev/null || true
  tmux set-option -t pi automatic-rename off 2>/dev/null || true
  tmux rename-window -t pi:0 pi 2>/dev/null || true
  # "pi:" is the session, not the window that is also called pi: without the
  # colon tmux would aim at that window and `new-window` would refuse the index.
  tmux bind-key -T prefix c if-shell -F '#{==:#{session_name},pi}' 'new-window -t pi: -n pi' new-window 2>/dev/null || true
  # Touch: a finger tap on the status bar is a left click and a swipe is a
  # drag. The strip shows a page of three 20-column tabs, so the tap can be
  # mapped to its tab: the name switches to it, the tab's own "x" asks first
  # and the answer sits on a SECOND status line, right under that same tab.
  # A click on an extra status line is only delivered when the area carries a
  # #[range=user|...] marker, so keep/close are user ranges and the handler
  # reads #{mouse_status_range}. Swiping the bar pages by one tab per 20
  # columns dragged (#{@tabstart}); the drag baseline is the press column, so
  # short motion events still add up. Only run-shell can read #{mouse_x}.
  tmux set-option -t pi status 2 2>/dev/null || true
  tmux set-option -t pi 'status-format[1]' ' ' 2>/dev/null || true
  tmux set-option -t pi @tabstart 0 2>/dev/null || true
  tmux set-option -t pi status-right ' + new tab ' 2>/dev/null || true
  tmux bind-key -n MouseDown1Status "run-shell -b 'x=#{mouse_x}; s=\"#{session_name}\"; l=#{mouse_status_line}; r=#{mouse_status_range}; f=\${TMPDIR:-\${PREFIX:-/data/data/com.termux/files/usr}/tmp}/codemux-tab-drag.\$s; if [ \"\$l\" = 1 ]; then p=\$(tmux show-options -t \"\$s:\" -qv @closepending); [ -n \"\$p\" ] || exit 0; tmux set-option -t \"\$s:\" -u @closepending; tmux set-option -t \"\$s:\" 'status-format[1]' ' '; if [ \"\$r\" = close ]; then n=\$(tmux list-windows -t \"\$s:\" 2>/dev/null | grep -c .); if [ \"\$n\" -gt 1 ]; then tmux kill-window -t \"\$s:\$p\"; tmux move-window -r -t \"\$s:\"; n=\$(tmux list-windows -t \"\$s:\" 2>/dev/null | grep -c .); k=\$((n - 3)); [ \"\$k\" -lt 0 ] && k=0; st=\$(tmux show-options -t \"\$s:\" -qv @tabstart); st=\${st:-0}; [ \"\$st\" -gt \"\$k\" ] && tmux set-option -t \"\$s:\" @tabstart \"\$k\"; fi; fi; exit 0; fi; printf %s \"\$x\" > \"\$f\"; st=\$(tmux show-options -t \"\$s:\" -qv @tabstart); st=\${st:-0}; i=\$((st + x / 20)); o=\$((x % 20)); n=\$(tmux list-windows -t \"\$s:\" 2>/dev/null | grep -c .); [ \"\$i\" -lt \"\$n\" ] || exit 0; if [ \"\$o\" -ge 17 ] && [ \"\$o\" -le 19 ] && [ \"\$s\" = pi ] && [ \"\$n\" -gt 1 ]; then tmux set-option -t \"\$s:\" @closepending \"\$i\"; b=\$(( (i - st) * 20 )); [ \"\$b\" -lt 0 ] && b=0; pad=\$(printf '%*s' \"\$b\" ''); tmux set-option -t \"\$s:\" 'status-format[1]' \"\${pad}##[range=user|keep fg=##c0c0c0]  keep  ##[norange default]##[range=user|close fg=##ff6b6b##,bold]  close  ##[norange default]\"; else tmux select-window -t \"\$s:\$i\"; fi; exit 0'" 2>/dev/null || true
  tmux bind-key -n MouseDown1StatusRight "run-shell -b 'x=#{mouse_x}; w=#{client_width}; s=\"#{session_name}\"; tmux set-option -t \"\$s:\" -u @closepending; tmux set-option -t \"\$s:\" 'status-format[1]' ' '; tmux new-window -t \"\$s:\" -n pi; n=\$(tmux list-windows -t \"\$s:\" 2>/dev/null | grep -c .); k=\$((n - 3)); [ \"\$k\" -lt 0 ] && k=0; tmux set-option -t \"\$s:\" @tabstart \"\$k\"; exit 0'" 2>/dev/null || true
  tmux bind-key -n MouseDrag1Status "run-shell -b 'x=#{mouse_x}; s=\"#{session_name}\"; l=#{mouse_status_line}; [ \"\$l\" = 1 ] && exit 0; f=\${TMPDIR:-\${PREFIX:-/data/data/com.termux/files/usr}/tmp}/codemux-tab-drag.\$s; d=\$(cat \"\$f\" 2>/dev/null); [ -n \"\$d\" ] || exit 0; st=\$(tmux show-options -t \"\$s:\" -qv @tabstart); st=\${st:-0}; n=\$(tmux list-windows -t \"\$s:\" 2>/dev/null | grep -c .); k=\$((n - 3)); [ \"\$k\" -lt 0 ] && k=0; h=\$(( (x - d) / 20 )); if [ \"\$h\" -ne 0 ]; then st=\$((st + h)); [ \"\$st\" -lt 0 ] && st=0; [ \"\$st\" -gt \"\$k\" ] && st=\"\$k\"; tmux set-option -t \"\$s:\" @tabstart \"\$st\"; printf %s \"\$((d + h * 20))\" > \"\$f\"; fi; exit 0'" 2>/dev/null || true
  tmux bind-key -n C-Tab if-shell -F '#{==:#{session_name},pi}' next-window 'send-keys C-Tab' 2>/dev/null || true
  tmux bind-key -n BTab if-shell -F '#{==:#{session_name},pi}' previous-window 'send-keys BTab' 2>/dev/null || true
  tmux bind-key -n M-Down if-shell -F '#{==:#{session_name},pi}' next-window 'send-keys M-Down' 2>/dev/null || true
  tmux bind-key -n M-Up if-shell -F '#{==:#{session_name},pi}' previous-window 'send-keys M-Up' 2>/dev/null || true
}

# Run a component. When its payload is missing, ask first, then install it.
# Returns 0 when the component ran, 1 when it is still missing/cancelled.
_oc_launch_component() {
  local key="$1" meta bin label short rc install_key
  meta="$(_oc_meta "$key")" || return 1
  # `pitmux` is not a component name: it installs exactly like `pi`.
  install_key="$key"
  [ "$install_key" = "pitmux" ] && install_key="pi"
  bin="${meta%%|*}"
  meta="${meta#*|}"
  label="${meta%%|*}"
  short="${meta#*|}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    _oc_confirm_install "$label" || return 1
    printf '  %s→ installing %s (this can take a while)…%s\n\n' "$DIM" "$label" "$R"
    if command -v codemux >/dev/null 2>&1; then
      codemux install --only "$install_key"
    elif [ -x "$CODEMUX_ROOT/bin/codemux" ]; then
      "$CODEMUX_ROOT/bin/codemux" install --only "$install_key"
    else
      printf '  %scodemux not found — cannot install.%s\n\n' "$DIM" "$R"
      return 1
    fi
    rc=$?
    hash -r 2>/dev/null || true
    _oc_cursor_hide
    if [ "$rc" -ne 0 ] || ! command -v "$bin" >/dev/null 2>&1; then
      printf '\n  %sinstall failed (rc=%s) — see the log above.%s\n\n' "$DIM" "$rc" "$R"
      return 1
    fi
  fi
  printf '\n'
  _oc_cursor_show
  printf '  %s→ %s%s\n\n' "$DIM" "$label" "$R"
  case "$key" in
    v1) opencode ;;
    v2) opencode-v2 ;;
    pi)
      # the pi alias should already exist; fall back to the official entry
      if alias pi >/dev/null 2>&1 || command -v pi >/dev/null 2>&1; then
        pi
      else
        npx -y free-pi-cli@latest
      fi
      ;;
    pitmux)
      if [ -n "$TMUX" ]; then
        # Already inside a tmux session: nesting one only garbles the terminal.
        printf '  %salready inside tmux — running pi in this session%s\n\n' "$DIM" "$R"
        pi
      elif command -v tmux >/dev/null 2>&1; then
        # One tab = one tmux window. The command string runs an interactive bash
        # so the `pi` alias applies, and OPENCODE_NO_AUTO keeps that bash from
        # drawing the codemux menu first. The first tab resumes the last session
        # for this directory and falls back to a fresh one; tabs opened later
        # start a new session. The session is created detached so the tab keys
        # and default-command can be set before the first attach.
        tmux has-session -t pi: 2>/dev/null ||
          tmux new-session -d -s pi "OPENCODE_NO_AUTO=1 bash -ic 'pi --continue || pi'"
        _oc_pi_tmux_tabs
        tmux attach-session -t pi
      else
        printf '  %stmux is not installed — running pi without tmux%s\n' "$DIM" "$R"
        printf '  %sinstall it with: pkg install tmux%s\n\n' "$DIM" "$R"
        pi
      fi
      ;;
    *) return 1 ;;
  esac
  # A full-screen agent (pi, opencode) can leave the shared stdin at EOF when it
  # exits with /quit: the shell then has a terminal that answers nothing, so the
  # menu would never read another key. Reopen the controlling terminal here.
  if [ -t 1 ] && [ -r /dev/tty ]; then
    exec 0</dev/tty 2>/dev/null || true
  fi
  _oc_cursor_hide
  return 0
}

# `~/.bashrc` is a real choice on this menu: the block lives in that file, so a
# user must be able to open, back up, adopt or remove it from the menu itself.
_oc_bashrc() {
  local ans
  if [ -x "$CODEMUX_ROOT/bin/launcher.sh" ]; then
    printf '\n'
    _oc_cursor_show
    "$CODEMUX_ROOT/bin/launcher.sh" --bashrc
    _oc_cursor_hide
    return 0
  fi
  if ! command -v codemux >/dev/null 2>&1; then
    printf '\n  %scodemux not found — cannot manage ~/.bashrc.%s\n\n' "$DIM" "$R"
    return 1
  fi
  printf '\n  %s~/.bashrc%s\n' "$BOLD" "$R"
  printf '    %s1%s open in an editor\n' "$ACC" "$R"
  printf '    %s2%s back up to ~/.bashrc.bak\n' "$ACC" "$R"
  printf '    %s3%s reinstall the codemux block\n' "$ACC" "$R"
  printf '    %s4%s remove the codemux block\n' "$ACC" "$R"
  printf '    %s5%s show the block\n' "$ACC" "$R"
  printf '  %s[1-5, Enter to cancel]%s ' "$DIM" "$R"
  _oc_cursor_show
  ans=""
  IFS= read -r ans || ans=""
  case "$ans" in
    1) if command -v nano >/dev/null 2>&1; then nano "$HOME/.bashrc"; else vi "$HOME/.bashrc"; fi ;;
    2) cp "$HOME/.bashrc" "$HOME/.bashrc.bak.$(date +%s)" && printf '  %sbackup written%s\n' "$DIM" "$R" ;;
    3) codemux install --only launcher ;;
    4) codemux uninstall --keep-bashrc >/dev/null 2>&1 || printf '  %sremove the block by hand%s\n' "$DIM" "$R" ;;
    5) awk '/codemux:launcher b(egin)/{f=1} f{print} /codemux:launcher e(nd)/{f=0}' "$HOME/.bashrc" ;;
    *) printf '  %snothing changed.%s\n' "$DIM" "$R" ;;
  esac
  _oc_cursor_hide
  return 0
}

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
      _oc_quota_notice
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
          v1|v2|pi|pitmux)
            if _oc_launch_component "$key"; then
              mkdir -p "$HOME/.local/state" 2>/dev/null
              printf '%s\n' "$key" >"$choice_file" 2>/dev/null
            fi
            # the install may have changed the rows: rebuild before redrawing
            _oc_items
            [ "$sel" -ge "$_OC_COUNT" ] && sel=$((_OC_COUNT - 1))
            full=1
            ;;
          shell) printf '\n'; return 0 ;;
          quit) printf '\n'; return 1 ;;
        esac
        # a redraw is needed whatever happened (an install changes the rows)
        _oc_items
        [ "$sel" -ge "$_OC_COUNT" ] && sel=$((_OC_COUNT - 1))
        full=1
        ;;
      [bB]) key="bashrc" ; sel=0; ;;
      [1-9])
        # number keys select a row directly (1..N); Enter starts the selection
        if [ "$KEY" -le "$_OC_COUNT" ]; then
          sel=$((KEY - 1))
          # draw the new selection first, so the answer is visible
          if [ "$full" = "1" ]; then :; else _oc_redraw "$sel"; full=1; fi
          KEY=enter
          case "${_OC_KEYS[$sel]}" in
            v1|v2|pi|pitmux)
              if _oc_launch_component "${_OC_KEYS[$sel]}"; then
                mkdir -p "$HOME/.local/state" 2>/dev/null
                printf '%s\n' "${_OC_KEYS[$sel]}" >"$choice_file" 2>/dev/null
              fi
              ;;
            shell) printf '\n'; return 0 ;;
            quit) printf '\n'; return 1 ;;
          esac
          _oc_items
          [ "$sel" -ge "$_OC_COUNT" ] && sel=$((_OC_COUNT - 1))
          full=1
        fi
        ;;
      q|Q) sel=$((_OC_COUNT - 1)); return 1 ;;
      esc|cancel|ctrl-c) ;;
      # stdin is gone (the terminal that a full-screen agent handed back is at
      # EOF): leave the menu so the shell prompt comes back.
      eof) return 1 ;;
    esac
  done
}

# One command guide row.
_oc_cmd_row() {
  printf '    %s%-13s%s%s\n' "$ACC" "$1" "$R" "$2"
}

# Short guide shown after choosing "Shell only".
_oc_guide() {
  printf '  %sShell only selected — no agent was started.%s\n\n' "$DIM" "$R"
  printf '  %sAvailable commands:%s\n' "$BOLD" "$R"
  _oc_cmd_row menu          'back to the choice menu'
  command -v opencode >/dev/null 2>&1 &&
    _oc_cmd_row opencode    'run OpenCode V1 directly'
  command -v opencode-v2 >/dev/null 2>&1 &&
    _oc_cmd_row opencode-v2 'run OpenCode V2 directly'
  command -v pi >/dev/null 2>&1 &&
    _oc_cmd_row pi          'run free-pi directly'
  command -v pi >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1 &&
    _oc_cmd_row 'tmux new -A -s pi' 'free-pi in tmux (Ctrl+b d detaches)'
  command -v tmux >/dev/null 2>&1 &&
    _oc_cmd_row 'Ctrl+b c' 'new tab in the pi session'
  command -v tmux >/dev/null 2>&1 &&
    _oc_cmd_row 'Ctrl+b ,' 'rename the tab (yours is never overwritten)'
  [ -f "$PREFIX/share/opencode-v2/doctor.sh" ] &&
    _oc_cmd_row doctor      'health check for the OpenCode V2 install'
  _oc_cmd_row version       'show the installed agent versions'
  command -v quota >/dev/null 2>&1 &&
    _oc_cmd_row quota       'estimated remaining free-model quota'
  _oc_cmd_row codemux       'check & maintain Termux (check / install / status)'
  _oc_cmd_row 'keluar|exit' 'close Termux'
  printf '\n  %sType %smenu%s at any time to return to this menu.%s\n' "$DIM" "$BOLD" "$R" "$R"
  printf '  %sInside an agent, type exit or press Ctrl+C → back to the menu.%s\n\n' "$DIM" "$R"
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
  if command -v pi >/dev/null 2>&1; then
    printf 'Pi (free-pi): %s\n' "$(_oc_ver pi)"
    found=1
  fi
  [ "$found" -eq 1 ] || printf 'no agent installed — run: codemux install\n'
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
