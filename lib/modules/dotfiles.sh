# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/globals are shared across files
# module: dotfiles — .bash_profile and .hushlogin.

m_dotfiles_probe() {
  local missing=()
  [ -f "$HOME/.bash_profile" ] || missing+=(".bash_profile")
  [ -f "$HOME/.hushlogin" ] || missing+=(".hushlogin")

  if [ "${#missing[@]}" -eq 0 ]; then
    PROBE=OK; NOTE=".bash_profile + .hushlogin"
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

  if [ "${#made[@]}" -eq 0 ]; then
    APPLY_NOTE="already present"
  else
    APPLY_NOTE="created: ${made[*]}"
  fi
  return 0
}
