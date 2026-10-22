# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: dotfiles — .bash_profile dan .hushlogin.

m_dotfiles_probe() {
  local missing=()
  [ -f "$HOME/.bash_profile" ] || missing+=(".bash_profile")
  [ -f "$HOME/.hushlogin" ] || missing+=(".hushlogin")

  if [ "${#missing[@]}" -eq 0 ]; then
    PROBE=OK; NOTE=".bash_profile + .hushlogin"
  else
    PROBE=MISS; NOTE="kurang: ${missing[*]}"
  fi
}

m_dotfiles_verify() { m_dotfiles_probe; }

m_dotfiles_apply() {
  local rc="$HOME/.bashrc" made=()

  mkdir -p "$HOME" || { APPLY_NOTE="tidak bisa menulis \$HOME"; return 1; }

  # .bash_profile: cukup memuat .bashrc (login shell Termux)
  if [ ! -f "$HOME/.bash_profile" ]; then
    printf '%s\n' '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' |
      codemux_atomic_write "$HOME/.bash_profile" || {
      APPLY_NOTE="gagal menulis ~/.bash_profile"; return 1
    }
    made+=(".bash_profile")
  fi

  # .hushlogin: sembunyikan MOTD bawaan Termux (banner ada di bashrc)
  if [ ! -f "$HOME/.hushlogin" ]; then
    : | codemux_atomic_write "$HOME/.hushlogin" || {
      APPLY_NOTE="gagal menulis ~/.hushlogin"; return 1
    }
    made+=(".hushlogin")
  fi

  if [ "${#made[@]}" -eq 0 ]; then
    APPLY_NOTE="sudah ada"
  else
    APPLY_NOTE="dibuat: ${made[*]}"
  fi
  return 0
}
