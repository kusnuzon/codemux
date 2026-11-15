# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/APPLY_NOTE/globals are shared across files
# module: pi — the free-pi coding agent (npx free-pi-cli), plus the `pi` alias.
# The package itself is fetched by npx on first start, so this module only makes
# sure the command is reachable and that `pi` survives a fresh shell.

# Where free-pi keeps its state when it is installed normally.
CODEMUX_PI_DIR="${PI_CODING_AGENT_DIR:-$HOME/.free-pi/agent}"

# The command must be free-pi-cli, not `pi`. free-pi-cli depends on
# @earendil-works/pi-coding-agent and the npx cache also exposes that package's
# own `pi` bin next to it. `command -v pi` finds whichever comes first on PATH,
# and the plain `pi` bin starts the upstream agent without the free-pi provider:
# it asks for an API key and shows no free models. Only free-pi-cli is correct.
codemux_pi_bin() {
  if command -v free-pi-cli >/dev/null 2>&1; then
    command -v free-pi-cli 2>/dev/null | head -n 1
    return
  fi
  # npx keeps its install under ~/.npm/_npx/<hash>; a free-pi-cli bin there is
  # the npx copy and survives until the npm cache is cleared.
  local candidate
  for candidate in "$HOME"/.npm/_npx/*/node_modules/.bin/free-pi-cli; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return; }
  done
  return 0
}

# Rewrite the managed pi block so the alias points at the given command. Only
# the block between the codemux:pi markers is touched; every other line of
# .bashrc is left byte-for-byte alone.
codemux_pi_repoint() {
  local rc="$1" want="$2" tmp
  tmp="$(mktemp "${TMPDIR:-$PREFIX/tmp}/codemux-pi.XXXXXX")" || return 1
  WANT_ALIAS="$want" awk '
    /^# codemux:pi begin/ { inside = 1; print; print ENVIRON["WANT_ALIAS"]; next }
    /^# codemux:pi end/   { inside = 0; print; next }
    inside               { next }
                         { print }
  ' "$rc" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
}

m_pi_probe() {
  local bin alias_line="alias pi="
  bin="$(codemux_pi_bin)"

  if [ -z "$bin" ]; then
    PROBE=MISS
    if grep -qF "$alias_line" "$HOME/.bashrc" 2>/dev/null; then
      NOTE="the pi alias exists but the free-pi-cli command does not (npx cache was cleared)"
    else
      NOTE="pi (free-pi) is not installed yet"
    fi
    return
  fi
  if ! grep -qF "$alias_line" "$HOME/.bashrc" 2>/dev/null; then
    PROBE=WARN; NOTE="pi is installed but the alias in \$HOME/.bashrc is missing"
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
    APPLY_NOTE="\$HOME/.bashrc fails bash -n — the pi alias was not added"
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
  # An older codemux pointed `alias pi` at the npx cache's own `pi` bin, which is
  # the plain upstream agent (no free models). Rewrite such an alias in place.
  bin="$(codemux_pi_bin)"
  want="alias pi=${bin:-npx -y free-pi-cli@latest}"
  have="$(grep -m 1 -F "alias pi=" "$rc" 2>/dev/null)"
  if [ -n "$have" ] && [ "$have" != "$want" ]; then
    if ! codemux_pi_repoint "$rc" "$want"; then
      APPLY_NOTE="failed to rewrite the pi alias in \$HOME/.bashrc"; return 1
    fi
    made+=("alias pi (repointed)")
  elif [ -z "$have" ]; then
    printf '\n# codemux:pi begin  (managed by codemux — free-pi launcher)\n%s\n# codemux:pi end\n' \
      "$want" >>"$rc" || {
      APPLY_NOTE="failed to add the pi alias to \$HOME/.bashrc"; return 1
    }
    made+=("alias pi")
  fi

  if ! bash -n "$rc" 2>/dev/null; then
    APPLY_NOTE="\$HOME/.bashrc fails bash -n after adding the pi alias"
    return 1
  fi

  if [ "${#made[@]}" -eq 0 ]; then
    APPLY_NOTE="already complete"
  else
    APPLY_NOTE="added: ${made[*]}"
  fi
  return 0
}
