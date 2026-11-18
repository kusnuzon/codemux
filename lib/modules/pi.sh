# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/APPLY_NOTE/globals are shared across files
# module: pi — the free-pi coding agent (npx free-pi-cli), plus the `pi` command.
# The package itself is fetched by npx on first start, so this module only makes
# sure the command is reachable, that `pi` survives a fresh shell, and that the
# terminal is repaired after pi exits (see the block below).

# Where free-pi keeps its state when it is installed normally.
CODEMUX_PI_DIR="${PI_CODING_AGENT_DIR:-$HOME/.free-pi/agent}"

# Managed free-pi config, canonical copies in $CODEMUX_ROOT/templates/pi.
# - default-model.json is written ONLY when missing: the user's own choice
#   (Ctrl+S in /model) must never be overwritten by an install.
# - extensions/ and themes/ are managed: rewritten when they differ from the
#   canonical copy (they carry a managed marker comment).
CODEMUX_PI_MANAGED=("extensions/thinking-medium.ts" "extensions/theme-amoled-calm.ts" "extensions/tmux-tab-title.ts" "themes/amoled-calm.json")

# Prints the managed config entries that are missing or stale (relative paths,
# plus the literal "default-model.json" when the model choice is absent).
codemux_pi_config_missing() {
  local rel src dst
  [ -f "$CODEMUX_ROOT/templates/pi/default-model.json" ] || return 0
  [ -f "$CODEMUX_PI_DIR/default-model.json" ] || printf '%s\n' "default-model.json"
  for rel in "${CODEMUX_PI_MANAGED[@]}"; do
    src="$CODEMUX_ROOT/templates/pi/$rel"
    dst="$CODEMUX_PI_DIR/$rel"
    [ -f "$src" ] || continue
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then printf '%s\n' "$rel"; fi
  done
}

# Copy one canonical config file into the agent dir.
codemux_pi_config_put() { # <relative-path>
  local rel="$1" dir
  dir="$CODEMUX_PI_DIR/$(dirname "$rel")"
  mkdir -p "$dir" 2>/dev/null || return 1
  cp "$CODEMUX_ROOT/templates/pi/$rel" "$CODEMUX_PI_DIR/$rel" 2>/dev/null || return 1
}

# Version of the managed wrapper block. Bumped whenever the block below changes:
# the probe compares the marker inside ~/.bashrc with this number, so an older
# block is rewritten on the next install instead of being left in place.
CODEMUX_PI_BLOCK_VERSION="2"

# The work runner: `~/bin/work.sh "<desc>" -- <cmd>` runs a command inside a
# visible tmux pane (a bottom split by default, KERJA_SPLIT=0 for a separate
# tab) and appends a full copy to ~/work.log, so anyone watching the terminal
# can follow what the agent executes. Canonical copy: lib/work.sh. Installed
# and restored like the managed config above — cmp-based, no version marker:
# any byte difference is rewritten on the next install.
CODEMUX_PI_WORK_SRC="lib/work.sh"
CODEMUX_PI_WORK_DST="bin/work.sh"

# Prints "work.sh" when the installed runner is missing or drifted from the
# canonical copy; prints nothing when it is up to date (or when codemux does
# not ship a canonical copy at all).
codemux_pi_work_missing() {
  [ -f "$CODEMUX_ROOT/$CODEMUX_PI_WORK_SRC" ] || return 0
  if [ -f "$HOME/$CODEMUX_PI_WORK_DST" ] &&
    cmp -s "$CODEMUX_ROOT/$CODEMUX_PI_WORK_SRC" "$HOME/$CODEMUX_PI_WORK_DST"; then
    return 0
  fi
  printf '%s\n' "work.sh"
}

# Copy the canonical runner into ~/bin and make it executable.
codemux_pi_work_put() {
  mkdir -p "$HOME/bin" 2>/dev/null || return 1
  cp "$CODEMUX_ROOT/$CODEMUX_PI_WORK_SRC" "$HOME/$CODEMUX_PI_WORK_DST" 2>/dev/null || return 1
  chmod 755 "$HOME/$CODEMUX_PI_WORK_DST" 2>/dev/null || return 1
}

# The `pi` wrapper. It is a shell FUNCTION, not an alias, so something still runs
# after the TUI exits: a full-screen agent can hand the terminal back inside the
# alternate screen (mouse, focus and paste modes still on) or in the middle of
# an OSC/DCS string. Termux then keeps the last frame while the shell below is
# alive — Ctrl+C, Ctrl+L and Esc do nothing and only `exit` works. `_oc_tty_fix`
# (defined by the launcher block, loaded earlier in .bashrc) resets every mode.
codemux_pi_block_text() {
  local bin="$1"
  printf '%s\n' \
    "# codemux:pi begin  (managed by codemux — free-pi launcher, version $CODEMUX_PI_BLOCK_VERSION)" \
    '# pi is a FUNCTION, not an alias, so the terminal is repaired after exit.' \
    '# A TUI can leave it in the alternate screen or in a half-written control' \
    '# string; _oc_tty_fix (launcher block) resets those modes. Do not replace' \
    '# this block by hand — run `codemux install` instead.' \
    'pi() {' \
    "  local _pi_bin=\"$bin\" _pi_rc=0" \
    '  "$_pi_bin" "$@" || _pi_rc=$?' \
    '  command -v _oc_tty_fix >/dev/null 2>&1 && _oc_tty_fix' \
    '  return "$_pi_rc"' \
    '}' \
    '# codemux:pi end'
}

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

# Replace the managed pi block with a fresh copy pointing at the given command.
# Only the block between the codemux:pi markers is touched; every other line of
# .bashrc is left byte-for-byte alone. An existing block is rewritten in place,
# a missing one is appended at the end.
codemux_pi_write_block() {
  local rc="$1" bin="$2" tmp line inside=0 placed=0
  tmp="$(mktemp "${TMPDIR:-${PREFIX:-/tmp}}/codemux-pi.XXXXXX")" || return 1
  {
    if [ -f "$rc" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          '# codemux:pi begin'*)
            inside=1
            if [ "$placed" -eq 0 ]; then
              codemux_pi_block_text "$bin"
              placed=1
            fi
            continue
            ;;
          '# codemux:pi end'*)
            inside=0
            continue
            ;;
        esac
        [ "$inside" -eq 1 ] && continue
        printf '%s\n' "$line"
      done <"$rc"
    fi
    if [ "$placed" -eq 0 ]; then codemux_pi_block_text "$bin"; fi
    : # the block's status must be 0: a false `[` here would delete the temp file
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
}

m_pi_probe() {
  # `blk`, not `have`: a local variable named like the `have()` helper would
  # shadow the function inside this scope.
  local bin rc="$HOME/.bashrc" blk=""
  bin="$(codemux_pi_bin)"
  [ -f "$rc" ] && blk="$(grep -m 1 -F '# codemux:pi begin' "$rc" 2>/dev/null)"

  if [ -z "$bin" ]; then
    PROBE=MISS
    if [ -n "$blk" ]; then
      NOTE="the pi wrapper exists but the free-pi-cli command does not (npx cache was cleared)"
    else
      NOTE="pi (free-pi) is not installed yet"
      # free-pi is fetched by `npx free-pi-cli` on first run; until then the
      # step is not a failure, only something left to do. install.sh re-probes
      # after apply and only looks at PROBE, so WARN (never MISS) keeps it out
      # of the failed count.
      PROBE=WARN
      # npx comes from the nodejs package; without it the fetch command above
      # cannot run at all. The toolset module installs nodejs since it became
      # part of CODEMUX_APT_PACKAGES.
      command -v npx >/dev/null 2>&1 || NOTE="$NOTE · npx missing — install nodejs (codemux toolset)"
    fi
    return
  fi
  if [ -z "$blk" ]; then
    PROBE=WARN; NOTE="pi is installed but the pi wrapper in \$HOME/.bashrc is missing"
    return
  fi
  case "$blk" in
    *"version $CODEMUX_PI_BLOCK_VERSION"*) ;;
    *) PROBE=WARN; NOTE="the pi wrapper in \$HOME/.bashrc is outdated"; return ;;
  esac
  if ! grep -qF "_pi_bin=\"$bin\"" "$rc" 2>/dev/null; then
    PROBE=WARN; NOTE="the pi wrapper points at a different command"; return
  fi
  if [ -d "$CODEMUX_PI_DIR" ]; then
    local miss
    miss="$(codemux_pi_config_missing; codemux_pi_work_missing | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "$miss" ]; then
      PROBE=WARN
      NOTE="pi + wrapper · managed config missing/stale: $miss"
      return
    fi
    local model="?"
    model="$(sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CODEMUX_PI_DIR/default-model.json" 2>/dev/null | head -n 1)"
    PROBE=OK; NOTE="pi + wrapper · model ${model:-?} · $CODEMUX_PI_DIR"
  else
    PROBE=WARN; NOTE="pi + wrapper · no agent dir yet (created on first start)"
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
    APPLY_NOTE="\$HOME/.bashrc fails bash -n — the pi wrapper was not added"
    return 1
  fi

  # Managed free-pi config comes FIRST: it must exist before the very first
  # `pi` start, so session #1 already uses the preferred model and extensions.
  # default-model.json is written only when missing — the user's own choice
  # (Ctrl+S in /model) is never overwritten.
  if [ -d "$CODEMUX_ROOT/templates/pi" ]; then
    if [ ! -f "$CODEMUX_PI_DIR/default-model.json" ] &&
      [ -f "$CODEMUX_ROOT/templates/pi/default-model.json" ]; then
      if codemux_pi_config_put "default-model.json"; then
        made+=("default model")
      else
        APPLY_NOTE="cannot write $CODEMUX_PI_DIR/default-model.json"
        return 1
      fi
    fi
    local rel
    for rel in "${CODEMUX_PI_MANAGED[@]}"; do
      [ -f "$CODEMUX_ROOT/templates/pi/$rel" ] || continue
      if [ ! -f "$CODEMUX_PI_DIR/$rel" ] || ! cmp -s "$CODEMUX_ROOT/templates/pi/$rel" "$CODEMUX_PI_DIR/$rel"; then
        if codemux_pi_config_put "$rel"; then
          made+=("$rel")
        else
          APPLY_NOTE="cannot write $CODEMUX_PI_DIR/$rel"
          return 1
        fi
      fi
    done
  fi

  # The work runner is installed even when free-pi itself has not been fetched
  # yet: it is a plain shell script with no dependency on the agent.
  if [ -n "$(codemux_pi_work_missing)" ]; then
    if codemux_pi_work_put; then
      made+=("work runner")
    else
      APPLY_NOTE="cannot write \$HOME/$CODEMUX_PI_WORK_DST"
      return 1
    fi
  fi

  if [ -z "$(codemux_pi_bin)" ] && [ ! -f "$HOME/.bashrc.pi.bak" ]; then
    # Installing free-pi non-interactively would download ~40 MB and then sit
    # waiting for a login, which an installer must not do. Print the exact
    # command instead; the menu asks for confirmation before running it.
    APPLY_NOTE="free-pi not fetched yet${made[*]:+ (config written: ${made[*]})} — run it once: npx -y free-pi-cli@latest"
    return 0
  fi

  # The command has to be free-pi-cli, not the npx cache's own `pi` bin (that is
  # the plain upstream agent: no free models, it asks for an API key). An older
  # codemux also wrote a bare `alias pi=`, which leaves the terminal broken after
  # exit because nothing runs afterwards — the block is rewritten as a function.
  bin="$(codemux_pi_bin)"
  if ! codemux_pi_write_block "$rc" "${bin:-npx -y free-pi-cli@latest}"; then
    APPLY_NOTE="failed to write the pi wrapper to \$HOME/.bashrc"; return 1
  fi
  made+=("pi wrapper")

  if ! bash -n "$rc" 2>/dev/null; then
    APPLY_NOTE="\$HOME/.bashrc fails bash -n after adding the pi wrapper"
    return 1
  fi

  if [ "${#made[@]}" -eq 0 ]; then
    APPLY_NOTE="already complete"
  else
    APPLY_NOTE="added: ${made[*]}"
  fi
  return 0
}
