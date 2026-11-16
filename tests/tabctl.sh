#!/usr/bin/env bash
# tests/tabctl.sh — the click handler behind the .tmux.conf tab strip.
#
# The strip itself is drawn by tmux (tested in tmuxconf.sh); this suite checks
# the decisions made when a range is tapped. tmux is replaced by a stub that
# records its arguments, so nothing real is touched and no terminal is needed.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX="$BASE/codemux-tabctl-$$"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/bin" "$SANDBOX/work"

SRC="$SANDBOX/work/tabctl.sh"
LOG="$SANDBOX/work/calls.log"

STUB_WINDOWS=3
# The handler ships inside lib/tmux-config.sh (so V1/V2 install it too); the
# suite tests the text that will be written to ~/.config/codemux/tabctl.sh.
bash -c "set -u; . '$ROOT/lib/tmux-config.sh'; tmuxconf_tabctl" >"$SRC" || {
  printf 'FAIL cannot extract the handler\n'
  exit 1
}

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- stub tmux ---------------------------------------------------------------
# Every call is appended to $LOG. `list-windows` prints $STUB_WINDOWS lines so
# the script can count tabs, `display-message -p` answers the session name.
cat >"$SANDBOX/bin/tmux" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG"
case "${1:-}" in
  display-message)
    if [ "${2:-}" = "-p" ]; then printf 'main\n'; fi
    exit 0 ;;
  list-windows)
    n="${STUB_WINDOWS:-3}"
    i=0
    while [ "$i" -lt "$n" ]; do printf '%d: tab\n' "$i"; i=$((i + 1)); done
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/tmux"

# run <args...> [with STUB_WINDOWS] — returns the handler's exit code, log in $LOG
run_tabctl() {
  : >"$LOG"
  STUB_LOG="$LOG" PATH="$SANDBOX/bin:$PATH" STUB_WINDOWS="$STUB_WINDOWS" \
    sh "$SRC" "$@" 2>"$SANDBOX/work/err"
}

logged() { grep -qxF "$1" "$LOG"; }
logged_any() { grep -q "$1" "$LOG"; }

# =============================================================================
# 1. Syntax + shape
# =============================================================================
if sh -n "$SRC" 2>/dev/null; then
  ok "handler: parses as POSIX sh"
else
  bad "handler: does not parse as sh"
fi
mkdir -p "$SANDBOX/work/home"
inst="$(HOME="$SANDBOX/work/home" bash -c "set -u; . '$ROOT/lib/tmux-config.sh'; tmuxconf_tabctl_install && tmuxconf_tabctl_state" 2>/dev/null)"
if [ "$inst" = "ok" ] && [ -x "$SANDBOX/work/home/.config/codemux/tabctl.sh" ]; then
  ok "install: handler written to ~/.config/codemux/tabctl.sh, executable, state ok"
else
  bad "install: handler state '$inst'"
fi
again="$(HOME="$SANDBOX/work/home" bash -c "set -u; . '$ROOT/lib/tmux-config.sh'; tmuxconf_tabctl_install && tmuxconf_tabctl_state" 2>/dev/null)"
[ "$again" = "ok" ] && ok "install: second install is a no-op" || bad "install: second install state '$again'"

# =============================================================================
# 2. Tapping a tab name switches to it, and cancels a pending close
# =============================================================================
if run_tabctl tap t2 && logged 'select-window -t main:2' && logged 'set-option -u -t main @closepending'; then
  ok "tap t2: select-window main:2 and the confirmation is cleared"
else
  bad "tap t2: did not switch ($(cat "$LOG"))"
fi
if run_tabctl tap t0 && logged 'select-window -t main:0'; then
  ok "tap t0: the first tab is reachable"
else
  bad "tap t0: did not switch"
fi

# =============================================================================
# 3. ✕ asks first: the tab becomes keep | close
# =============================================================================
STUB_WINDOWS=3
run_tabctl tap c1
[ "$?" -eq 0 ] && ok "tap c1: exits 0" || bad "tap c1: non-zero exit"
if logged 'set-option -t main @closepending 1' && ! logged_any 'kill-window'; then
  ok "tap c1: sets @closepending, closes nothing yet"
else
  bad "tap c1: wrong calls ($(cat "$LOG"))"
fi

# =============================================================================
# 4. keep / close answers
# =============================================================================
if run_tabctl tap k1 && logged 'set-option -u -t main @closepending' && ! logged_any 'kill-window'; then
  ok "tap k1: keep clears the confirmation and keeps the tab"
else
  bad "tap k1: wrong calls ($(cat "$LOG"))"
fi
if run_tabctl tap x1 && logged 'kill-window -t main:1' && logged 'move-window -r -t main:'; then
  ok "tap x1: closes that tab and keeps the indexes dense"
else
  bad "tap x1: wrong calls ($(cat "$LOG"))"
fi
if run_tabctl tap x1 && logged 'set-option -u -t main @closepending'; then
  ok "tap x1: clears the confirmation state"
else
  bad "tap x1: confirmation left behind"
fi

# =============================================================================
# 5. The last tab is never closed
# =============================================================================
STUB_WINDOWS=1
run_tabctl tap x0
if ! logged_any 'kill-window' && logged_any 'Last tab'; then
  ok "tap x0 with one tab: refuses and says why"
else
  bad "tap x0 with one tab: $(cat "$LOG")"
fi
STUB_WINDOWS=1
run_tabctl tap c0
if ! grep -q '^set-option -t main @closepending' "$LOG" && logged_any 'Last tab'; then
  ok "tap c0 with one tab: no confirmation for a tab that cannot close"
else
  bad "tap c0 with one tab: $(cat "$LOG")"
fi

# =============================================================================
# 6. + new tab
# =============================================================================
if run_tabctl tap new && logged 'new-window -t main:'; then
  ok "tap new: opens a tab through the session default-command"
else
  bad "tap new: no new-window"
fi
if run_tabctl new && logged 'new-window -t main:'; then
  ok "action new: same as tapping the button"
else
  bad "action new: no new-window"
fi

# =============================================================================
# 7. Anything else is ignored, and the handler never fails
# =============================================================================
for r in window default ''; do
  if run_tabctl tap "$r"; then
    if logged_any 'kill-window\|select-window\|new-window\|@closepending'; then
      bad "tap '$r': acted on a range it does not own"
    else
      ok "tap '$r': ignored"
    fi
  else
    bad "tap '$r': non-zero exit (tmux would print the script over the bar)"
  fi
done
# A range is data from tmux, but a stray character must not reach a target.
if run_tabctl tap 'x1;reboot' && ! logged_any 'kill-window'; then
  ok "tap 'x1;reboot': not a window index, nothing runs"
else
  bad "tap 'x1;reboot': the index was passed on"
fi
# No tmux at all (a stripped install): still exit 0.
: >"$LOG"
PATH="$SANDBOX/work" /bin/sh "$SRC" tap c1 >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "no tmux on PATH: exits 0" || bad "no tmux on PATH: non-zero exit"

rm -rf "$SANDBOX"
printf '\n%d passed · %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
