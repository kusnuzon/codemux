# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/APPLY_NOTE/globals are shared across files
# module: pi — the free-pi coding agent (npx free-pi-cli), plus the `pi` alias.
# The package itself is fetched by npx on first start, so this module only makes
# sure the command is reachable and that `pi` survives a fresh shell.

# Where free-pi keeps its state when it is installed normally.
CODEMUX_PI_DIR="${PI_CODING_AGENT_DIR:-$HOME/.free-pi/agent}"

# A `pi` binary may come from a global npm install, a local one, or npx cache.
codemux_pi_bin() {
  command -v pi 2>/dev/null | head -n 1
}

m_pi_probe() {
  local bin alias_line="alias pi="
  bin="$(codemux_pi_bin)"

  if [ -z "$bin" ]; then
    PROBE=MISS
    if grep -qF "$alias_line" "$HOME/.bashrc" 2>/dev/null; then
      NOTE="the pi alias exists but the pi command does not (npx cache was cleared)"
    else
      NOTE="pi (free-pi) is not installed yet"
    fi
    return
  fi
  if ! grep -qF "$alias_line" "$HOME/.bashrc" 2>/dev/null; then
    PROBE=WARN; NOTE="pi is installed but the alias in ~/.bashrc is missing"
    return
  fi
  if [ -d "$CODEMUX_PI_DIR" ]; then
    PROBE=OK; NOTE="pi + alias · $CODEMUX_PI_DIR"
  else
    PROBE=WARN; NOTE="pi + alias · no agent dir yet (created on first start)"
  fi
}

m_pi_verify() { m_pi_probe; }

m_pi_apply() {
  local rc="$HOME/.bashrc" bin made=()

  mkdir -p "$HOME" || { APPLY_NOTE="cannot write \$HOME"; return 1; }
  [ -f "$rc" ] || : >"$rc" || { APPLY_NOTE="cannot write ~/.bashrc"; return 1; }

  # Never append to a .bashrc that is already broken: the extra lines would
  # spread the damage and hide which change caused it. The launcher module
  # reports the broken file; this module stays out of the way.
  if ! bash -n "$rc" 2>/dev/null; then
    APPLY_NOTE="~/.bashrc fails bash -n — the pi alias was not added"
    return 1
  fi

  if [ -z "$(codemux_pi_bin)" ] && [ ! -f "$HOME/.bashrc.pi.bak" ]; then
    # Installing free-pi non-interactively would download ~40 MB and then sit
    # waiting for a login, which an installer must not do. Print the exact
    # command instead; the menu asks for confirmation before running it.
    APPLY_NOTE="run it once to install: npx -y free-pi-cli@latest"
    return 0
  fi

  # The alias has to be a plain `alias`, not a function: free-pi re-execs itself
  # through the shell and a function wrapper loses the terminal handover.
  if ! grep -qF "alias pi=" "$rc" 2>/dev/null; then
    bin="$(codemux_pi_bin)"
    printf '\n# codemux:pi begin  (managed by codemux — free-pi launcher)\nalias pi=%q\n# codemux:pi end\n' \
      "${bin:-npx -y free-pi-cli@latest}" >>"$rc" || {
      APPLY_NOTE="failed to add the pi alias to ~/.bashrc"; return 1
    }
    made+=("alias pi")
  fi

  if ! bash -n "$rc" 2>/dev/null; then
    APPLY_NOTE="~/.bashrc fails bash -n after adding the pi alias"
    return 1
  fi

  if [ "${#made[@]}" -eq 0 ]; then
    APPLY_NOTE="already complete"
  else
    APPLY_NOTE="added: ${made[*]}"
  fi
  return 0
}
