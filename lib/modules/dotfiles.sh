# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: dotfiles — .bash_profile, .hushlogin and ~/.tmux.conf.

m_dotfiles_probe() {
  local missing=()
  local tstate="ok"
  [ -f "$HOME/.bash_profile" ] || missing+=(".bash_profile")
  [ -f "$HOME/.hushlogin" ] || missing+=(".hushlogin")
  if declare -F tmuxconf_state >/dev/null 2>&1; then
    tstate="$(tmuxconf_state "$HOME/.tmux.conf")"
    [ "$tstate" = ok ] || missing+=(".tmux.conf")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    PROBE=OK; NOTE=".bash_profile + .hushlogin + .tmux.conf (dark theme)"
  else
    PROBE=MISS; NOTE="missing: ${missing[*]}"
  fi
}

m_dotfiles_verify() { m_dotfiles_probe; }

m_dotfiles_apply() {
  local rc="$HOME/.bashrc" made=()

  mkdir -p "$HOME" || { APPLY_NOTE="cannot write \$HOME"; return 1; }

  # .bash_profile: just load .bashrc (Termux login shell)
  if [ ! -f "$HOME/.bash_profile" ]; then
    printf '%s\n' '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' |
      codemux_atomic_write "$HOME/.bash_profile" || {
      APPLY_NOTE="failed to write ~/.bash_profile"; return 1
    }
    made+=(".bash_profile")
  fi

  # .hushlogin: hide the stock Termux MOTD (the banner lives in bashrc)
  if [ ! -f "$HOME/.hushlogin" ]; then
    : | codemux_atomic_write "$HOME/.hushlogin" || {
      APPLY_NOTE="failed to write ~/.hushlogin"; return 1
    }
    made+=(".hushlogin")
  fi

  # ~/.tmux.conf: managed dark-theme block (shared with the V1/V2 repos).
  # tmuxconf_install appends to or replaces only the marked region and backs
  # up whatever was there, so a user's own settings survive.
  if declare -F tmuxconf_install >/dev/null 2>&1; then
    if tmuxconf_install "$HOME/.tmux.conf"; then
      [ -f "$HOME/.tmux.conf" ] && made+=(".tmux.conf")
    else
      APPLY_NOTE="failed to write ~/.tmux.conf"; return 1
    fi
  fi

  if [ "${#made[@]}" -eq 0 ]; then
    APPLY_NOTE="already present"
  else
    APPLY_NOTE="updated: ${made[*]}"
  fi
  return 0
}
