# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/APPLY_NOTE/globals are shared across files
# module: memory — Linux profile (PRD §21.2). Loaded by bin/codemux AFTER
# lib/modules/memory.sh, whose m_memory_* it replaces on plain Linux.
#
# On Linux the opencode-specific machinery (plugins, digest wrapper, quota) is
# out of scope — that stack is tested on Termux only. What stays useful is the
# cross-session memory itself: the tiered zen-memory store (~/.zen: memory.md,
# topics/, archive/). The linux profile therefore installs the zen-memory CLI
# from the kusnuzon/zen-memory repo (the same fetch-from-upstream pattern the
# termux memory module uses) and wires a ~/.bashrc pointer block so new shells
# get the alias.

CODEMUX_ZEN_CLI_DIR="${CODEMUX_ZEN_CLI_DIR:-$HOME/.local/bin}"
CODEMUX_ZEN_VAULT="${CODEMUX_ZEN_VAULT:-$HOME/.zen}"
CODEMUX_ZEN_SCRIPTS_URL="${CODEMUX_ZEN_SCRIPTS_URL:-https://raw.githubusercontent.com/kusnuzon/zen-memory/main/scripts}"

m_memory_linux_wrapper_present() {
  grep -q 'codemux:zen-memory' "$HOME/.bashrc" 2>/dev/null
}

m_memory_linux_probe() {
  local miss=() f
  for f in zen-memory.sh store.sh zen-archiver.py; do
    [ -s "$CODEMUX_ZEN_CLI_DIR/$f" ] || miss+=("$f")
  done
  if [ ! -d "$CODEMUX_ZEN_VAULT" ]; then
    miss+=("store (~/.zen)")
  fi
  if [ "${#miss[@]}" -gt 0 ]; then
    PROBE=MISS; NOTE="missing: ${miss[*]}"
    return
  fi
  if ! m_memory_linux_wrapper_present; then
    PROBE=WARN; NOTE="bashrc pointer block missing (added during install)"
    return
  fi
  PROBE=OK
  NOTE="zen-memory CLI + store present"
}

m_memory_linux_verify() { m_memory_linux_probe; }

m_memory_linux_apply() {
  local f url dst tmp
  # 1) CLI: fetch the scripts from the zen-memory repo. store.sh is sourced by
  #    zen-memory.sh from its own directory, so all three must land together;
  #    zen-archiver.py is invoked through python3, so its shebang never matters.
  #    An existing CLI is left alone (updating it is `zen-memory`'s own job).
  mkdir -p "$CODEMUX_ZEN_CLI_DIR" "$CODEMUX_HOME/cache" || {
    APPLY_NOTE="cannot create $CODEMUX_ZEN_CLI_DIR"; return 1
  }
  for f in zen-memory.sh store.sh zen-archiver.py; do
    dst="$CODEMUX_ZEN_CLI_DIR/$f"
    [ -s "$dst" ] && continue
    url="$CODEMUX_ZEN_SCRIPTS_URL/$f"
    tmp="$CODEMUX_HOME/cache/$f"
    if ! codemux_fetch_raw "$url" "$tmp"; then
      APPLY_NOTE="failed to download $f"
      return 1
    fi
    codemux_atomic_write "$dst" <"$tmp" || {
      APPLY_NOTE="cannot write $dst"; return 1
    }
    chmod 700 "$dst" 2>/dev/null || true
    rm -f "$tmp"
  done

  # 2) Store: create it when missing (never touches an existing one).
  if [ ! -d "$CODEMUX_ZEN_VAULT" ]; then
    codemux_spin_msg "initialising the zen-memory store"
    if ! "$CODEMUX_ZEN_CLI_DIR/zen-memory.sh" init >/dev/null 2>&1; then
      APPLY_NOTE="zen-memory init failed"
      return 1
    fi
    APPLY_NOTE="zen-memory CLI installed · store initialised"
  fi

  # 3) bashrc pointer: one marked block, rewritten when the version changes.
  if ! grep -q 'codemux:zen-memory version 1' "$HOME/.bashrc" 2>/dev/null; then
    local rcfile="$HOME/.bashrc" tmpbak
    [ -f "$rcfile" ] || : >"$rcfile" || return 1
    tmpbak="$(codemux_backup memory "$rcfile")" || return 1
    sed -i '/^# codemux:zen-memory begin/,/^# codemux:zen-memory end/d' "$rcfile" 2>/dev/null || true
    {
      printf '\n%s\n' "# codemux:zen-memory begin  (managed by codemux — cross-session memory)"
      printf '# codemux:zen-memory version 1\n'
      cat <<'EOS'
zen-memory() { "$HOME/.local/bin/zen-memory.sh" "$@"; }
EOS
      printf '%s\n' "# codemux:zen-memory end"
    } >>"$rcfile" || {
      [ -n "$tmpbak" ] && cp -a "$tmpbak" "$rcfile"
      APPLY_NOTE="failed to append the zen-memory block to ~/.bashrc"
      return 1
    }
    if ! bash -n "$rcfile" 2>/dev/null; then
      [ -n "$tmpbak" ] && cp -a "$tmpbak" "$rcfile"
      APPLY_NOTE="bashrc syntax broken after the zen-memory block — restored"
      return 1
    fi
    chmod 600 "$rcfile" 2>/dev/null || true
    [ -n "$APPLY_NOTE" ] || APPLY_NOTE="bashrc pointer block added"
  fi
  [ -n "$APPLY_NOTE" ] || APPLY_NOTE="zen-memory already current"
  return 0
}
