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
