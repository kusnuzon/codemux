# shellcheck shell=bash
# lib/maintenance.sh — `codemux doctor`, `upgrade`, `uninstall` (M5).

# --- utils -------------------------------------------------------------------
# --yes / non-tty counts as consent; otherwise ask.
codemux_confirm() {
  local prompt="$1" ans
  [ "${CODEMUX_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || return 0
  printf '%s [y/N] ' "$prompt"
  read -r ans || true
  case "$ans" in y | Y | ya | YA) return 0 ;; *) return 1 ;; esac
}

codemux_strip_managed_blocks() { # <file> <tag...> → stdout without marked blocks
  local file="$1"
  shift
  local -a tags=("$@")
  awk -v tags="${tags[*]}" '
    BEGIN { n = split(tags, t, " "); for (i = 1; i <= n; i++) on[i] = 0 }
    {
      hit = 0
      for (i = 1; i <= n; i++) {
        if ($0 ~ ("# codemux:" t[i] " begin")) { on[i] = 1; hit = 1 }
        if ($0 ~ ("# codemux:" t[i] " end")) { on[i] = 0; hit = 1 }
        if (on[i]) hit = 1
      }
      if (!hit) print
    }
    END {
      for (i = 1; i <= n; i++) if (on[i]) exit 3
    }
  ' "$file"
}

# --- doctor ------------------------------------------------------------------
codemux_cmd_doctor() {
  local a extra_fail=0 rc=0 base size pct free_kb age
  for a in "$@"; do
    case "$a" in
      -h | --help) codemux_usage; return 0 ;;
      --json) log_warn "doctor --json is not available yet; use: codemux check --json" ;;
      *) : ;;
    esac
  done

  codemux_load_modules
  codemux_cmd_check || rc=$?

  base="$HOME/.config/opencode"
  printf '\n%sAdditional checks%s\n' "$C_B" "$C_R"

  # 1. ~/.bashrc
  if [ -f "$HOME/.bashrc" ] && bash -n "$HOME/.bashrc" 2>/dev/null; then
    log_ok "$HOME/.bashrc passes bash -n"
  else
    log_fail "$HOME/.bashrc is broken (bash -n failed) — codemux install will restore it from backup"
    extra_fail=$((extra_fail + 1))
  fi
  if grep -q '_oc_refresh_digest()' "$HOME/.bashrc" 2>/dev/null; then
    log_ok "digest wrapper active (RECENT.md refreshed every time opencode opens)"
  else
    log_warn "digest wrapper missing — run: codemux install"
  fi

  # 2. memory
  if [ -f "$base/MEMORY.md" ]; then
    size="$(wc -c <"$base/MEMORY.md")"; size="${size// /}"
    pct=$((size * 100 / CODEMUX_MEMORY_LIMIT))
    if [ "$pct" -ge 100 ]; then
      log_fail "MEMORY.md ${size}B ≥ ${CODEMUX_MEMORY_LIMIT}B — memory_save will fail, trim it now"
      extra_fail=$((extra_fail + 1))
    elif [ "$pct" -ge 90 ]; then
      log_warn "MEMORY.md ${size}B (${pct}%) — almost full, consider trimming"
    else
      log_ok "MEMORY.md ${size}B (${pct}% of the limit)"
    fi
  else
    log_warn "MEMORY.md is missing — run: codemux install"
  fi
  if [ -f "$base/opencode.jsonc" ] &&
    grep -q 'MEMORY.md' "$base/opencode.jsonc" &&
    grep -q 'RECENT.md' "$base/opencode.jsonc"; then
    log_ok "instructions load MEMORY.md + RECENT.md"
  else
    log_warn "instructions in opencode.jsonc are incomplete — run: codemux install"
  fi

  # 3. environment that breaks the glibc payload
  if printf '%s' "${LD_PRELOAD:-}" | grep -q 'libtermux-exec'; then
    log_fail "bionic LD_PRELOAD is active (${LD_PRELOAD}) — it can break OpenCode V2; the launcher sanitizes it, this shell does not"
    extra_fail=$((extra_fail + 1))
  else
    log_ok "LD_PRELOAD is clean"
  fi

  # 4. disk
  free_kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  free_kb="${free_kb:-0}"
  if [ "$free_kb" -lt 1048576 ]; then
    log_warn "disk free $(human_bytes $((free_kb * 1024))) — less than 1 GB"
  else
    log_ok "disk free $(human_bytes $((free_kb * 1024)))"
  fi

  # 5. lock & update cache
  if [ -d "$CODEMUX_HOME/lock" ]; then
    if codemux_lock_info | grep -q '^active'; then
      log_warn "another install/upgrade is running ($(codemux_lock_info))"
    else
      log_warn "stale lock — run: codemux repair"
    fi
  else
    log_ok "no leftover lock"
  fi
  if [ -f "$(codemux_update_cache)" ]; then
    age=$(( ($(date +%s) - $(stat -c %Y "$(codemux_update_cache)" 2>/dev/null || echo 0)) / 3600 ))
    if [ "$age" -ge 24 ]; then
      log_warn "update cache ${age}h old — run: codemux update-check"
    else
      log_ok "update cache ${age}h old"
    fi
  else
    log_warn "never checked for updates — run: codemux update-check"
  fi

  printf '\n'
  if [ "$rc" -eq 0 ] && [ "$extra_fail" -eq 0 ]; then
    log_ok "no problems need action."
    return 0
  fi
  if [ "$extra_fail" -gt 0 ]; then
    log_fail "$extra_fail extra findings need fixing."
  else
    log_warn "some modules are not ready yet."
  fi
  log_dim "fix automatically: codemux install · clean up leftovers: codemux repair"
  [ "$extra_fail" -gt 0 ] && return 1
  return "$rc"
}

# --- upgrade -----------------------------------------------------------------
codemux_upgrade_step_apt() {
  local rc=0
  log_info "apt: refresh the package list"
  codemux_spawn upgrade_apt env DEBIAN_FRONTEND=noninteractive apt-get update ||
    { log_warn "failed to run apt-get update"; return 1; }
  codemux_wait upgrade_apt 1800 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "apt-get update failed (rc $rc): $(codemux_step_tail upgrade_apt)"
    return 1
  fi
  log_info "apt: upgrade packages (opencode is held)"
  codemux_spawn upgrade_apt2 env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confold upgrade ||
    { log_warn "failed to run apt-get upgrade"; return 1; }
  codemux_wait upgrade_apt2 5400 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "apt-get upgrade failed (rc $rc): $(codemux_step_tail upgrade_apt2)"
    return 1
  fi
  log_ok "apt: packages updated"
  return 0
}

codemux_upgrade_step_v1() {
  local script="$PREFIX/share/opencode/upgrade.sh" rc=0
  if [ -x "$script" ]; then
    log_info "V1: $script"
    codemux_spawn upgrade_v1 bash "$script" || return 1
    codemux_wait upgrade_v1 3600 || rc=$?
    [ "$rc" -eq 0 ] || { log_warn "V1 upgrade failed (rc $rc)"; return 1; }
  else
    log_info "V1: no local upgrade.sh — reinstalling the latest payload through the adapter"
    m_v1_apply || return 1
  fi
  log_ok "V1: $(opencode_v1_version)"
  return 0
}

codemux_upgrade_step_v2() {
  local script="$PREFIX/share/opencode-v2/upgrade.sh" rc=0
  if [ -x "$script" ]; then
    log_info "V2: $script"
    codemux_spawn upgrade_v2 bash "$script" || return 1
    codemux_wait upgrade_v2 3600 || rc=$?
    [ "$rc" -eq 0 ] || { log_warn "V2 upgrade failed (rc $rc)"; return 1; }
  else
    log_info "V2: no local upgrade.sh — reinstalling the latest payload through the adapter"
    m_v2_apply || return 1
  fi
  log_ok "V2: $(opencode_v2_version)"
  return 0
}

codemux_upgrade_step_launcher() {
  m_launcher_apply || { log_warn "failed to sync the launcher block"; return 1; }
  m_dotfiles_apply || true
  codemux_memory_ensure_wrapper || { log_warn "failed to install the digest wrapper"; return 1; }
  log_ok "launcher + digest wrapper in sync"
  return 0
}

codemux_cmd_upgrade() {
  local dry=0 only="" m rc=0 ok_n=0 fail_n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -y | --yes) CODEMUX_YES=1 ;;
      --only) only="${2:-}"; shift ;;
      --only=*) only="${1#--only=}" ;;
      -h | --help)
        printf '%s\n' 'usage: codemux upgrade [--dry-run] [--yes] [--only apt,v1,v2,launcher]' \
          '' 'Update apt packages, the OpenCode V1/V2 payloads, then sync the launcher block.' \
          'The apt opencode package stays held; memory & projects are untouched.'
        return 0
        ;;
      *) log_warn "unknown option for upgrade: $1" ;;
    esac
    shift
  done
  codemux_load_modules

  local -a steps=(apt v1 v2 launcher)
  local -a run=()
  for m in "${steps[@]}"; do
    if [ -n "$only" ] && ! codemux_in_list "$m" "$only"; then continue; fi
    run+=("$m")
  done
  [ "${#run[@]}" -gt 0 ] || { log_fail "--only does not match (apt,v1,v2,launcher)"; return 2; }

  printf '%s%s %s%s · upgrade%s\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R" \
    "$([ "$dry" -eq 1 ] && printf ' (dry-run)')"
  for m in "${run[@]}"; do
    case "$m" in
      apt) printf '  %-10s %s\n' apt 'apt-get update + upgrade (opencode held)' ;;
      v1) printf '  %-10s %s\n' v1 "V1 payload now $(opencode_v1_version)" ;;
      v2) printf '  %-10s %s\n' v2 "V2 payload now $(opencode_v2_version)" ;;
      launcher) printf '  %-10s %s\n' launcher 'sync the launcher block + digest wrapper' ;;
    esac
  done
  printf '\n'
  if [ "$dry" -eq 1 ]; then log_dim "--dry-run mode: nothing was changed."; return 0; fi
  codemux_confirm "Continue with the upgrade?" || { log_dim "cancelled."; return 0; }

  local lock_rc=0
  codemux_lock_acquire || lock_rc=$?
  case "$lock_rc" in
    0) : ;;
    1) log_fail "another process is running: $(codemux_lock_info)"; return 3 ;;
    *) log_fail "cannot write $CODEMUX_HOME"; return 2 ;;
  esac
  # shellcheck disable=SC2064
  trap 'codemux_lock_release' EXIT INT TERM
  codemux_log_start
  printf 'upgrade start · only=%s\n' "${only:-all}" >>"$CODEMUX_LOG"

  for m in "${run[@]}"; do
    printf '[%s] ' "$m"
    if "codemux_upgrade_step_$m" 2>>"$CODEMUX_LOG"; then
      ok_n=$((ok_n + 1)); printf '%sOK%s\n' "$C_OK" "$C_R"
    else
      fail_n=$((fail_n + 1)); printf '%sFAIL%s\n' "$C_MISS" "$C_R"
    fi
  done

  codemux_lock_release
  trap - EXIT INT TERM

  # The upstream update cache is written BEFORE the payload is swapped, so it
  # still holds the old versions. Without this, the menu keeps suggesting an
  # upgrade that just finished.
  if [ "$ok_n" -gt 0 ] && [ "$dry" -eq 0 ]; then
    if codemux_cmd_update_check --quiet >/dev/null 2>&1; then
      log_dim "update cache refreshed · remaining updates: $(codemux_update_count)"
    else
      log_dim "could not refresh the update cache — run: codemux update-check"
    fi
  fi

  printf '\n'
  if [ "$fail_n" -eq 0 ]; then
    log_ok "upgrade finished: $ok_n steps."
    log_dim "health check: codemux doctor · log: $CODEMUX_LOG"
    return 0
  fi
  log_fail "$fail_n steps failed."
  log_dim "see: codemux status · log: $CODEMUX_LOG"
  return 1
}

# --- uninstall ---------------------------------------------------------------
codemux_cmd_uninstall() {
  local dry=0 purge=0 a dest moved=() rc=0
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -y | --yes) CODEMUX_YES=1 ;;
      --purge) purge=1 ;;
      -h | --help)
        printf '%s\n' 'usage: codemux uninstall [--dry-run] [--yes] [--purge]' \
          '' 'Remove the OpenCode V1/V2 payloads + the launcher block in ~/.bashrc.' \
          'Does NOT delete MEMORY.md, AGENTS.md, projects, or backups.' \
          '--purge also deletes the codemux cache/state (~/.config/codemux).'
        return 0
        ;;
      *) log_warn "unknown option for uninstall: $a" ;;
    esac
  done

  printf '%s%s %s%s · uninstall%s\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R" \
    "$([ "$dry" -eq 1 ] && printf ' (dry-run)')"
  printf '  removed   : OpenCode V1 + V2 payloads + launcher/wrapper block in ~/.bashrc\n'
  printf '  kept      : MEMORY.md, AGENTS.md, opencode config, projects, backups\n'
  [ "$purge" -eq 1 ] && printf '  --purge   : also delete %s (codemux state, cache, backups)\n' "$CODEMUX_HOME"
  printf '\n'

  if [ "$dry" -eq 1 ]; then
    log_dim "--dry-run mode: nothing was changed."
    return 0
  fi
  codemux_confirm "Remove OpenCode V1/V2 from Termux?" || { log_dim "cancelled."; return 0; }

  dest="$CODEMUX_HOME/backup/$(date '+%Y%m%d-%H%M%S')-uninstall"
  mkdir -p "$dest" || { log_fail "cannot create $dest"; return 2; }

  local p name
  for p in "$PREFIX/share/opencode" "$PREFIX/share/opencode-v2" \
    "$PREFIX/bin/opencode" "$PREFIX/bin/opencode-v2"; do
    [ -e "$p" ] || continue
    case "$p" in
      "$PREFIX/share/"*) name="share-$(basename "$p")" ;;
      "$PREFIX/bin/"*) name="bin-$(basename "$p")" ;;
      *) name="$(basename "$p")" ;;
    esac
    if mv "$p" "$dest/$name" 2>/dev/null; then
      moved+=("$(basename "$p")")
    else
      log_warn "failed to move $p"
      rc=1
    fi
  done

  # launcher + digest wrapper block in ~/.bashrc
  if [ -f "$HOME/.bashrc" ] &&
    grep -q 'codemux:launcher begin\|codemux:memory begin' "$HOME/.bashrc" 2>/dev/null; then
    local bak tmp
    bak="$(codemux_backup uninstall "$HOME/.bashrc")" || true
    tmp="$(mktemp "$HOME/.bashrc.codemux.XXXXXX" 2>/dev/null)" || tmp=""
    if [ -n "$tmp" ] &&
      codemux_strip_managed_blocks "$HOME/.bashrc" launcher memory >"$tmp" 2>/dev/null; then
      if bash -n "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$HOME/.bashrc" && chmod 600 "$HOME/.bashrc"
        moved+=("launcher/wrapper block")
      else
        rm -f "$tmp"
        log_warn "result without the blocks failed bash -n — ~/.bashrc left untouched"
        rc=1
      fi
    else
      [ -n "$tmp" ] && rm -f "$tmp"
      log_warn "marked blocks are incomplete — ~/.bashrc left untouched"
      rc=1
    fi
    [ -n "${bak:-}" ] && log_dim "bashrc backup: $bak"
  fi

  if [ "$purge" -eq 1 ]; then
    case "$CODEMUX_HOME" in
      "$HOME"/*) rm -rf "$CODEMUX_HOME"; moved+=("$CODEMUX_HOME") ;;
      *) log_warn "not deleting $CODEMUX_HOME (outside \$HOME)"; rc=1 ;;
    esac
  fi

  printf '\n'
  if [ "${#moved[@]}" -gt 0 ]; then
    log_ok "removed: ${moved[*]}"
  else
    log_info "nothing to remove."
  fi
  if [ "$rc" -eq 0 ]; then
    log_dim "old payload stored at: $dest"
    log_dim "install again: codemux install · memory & projects untouched"
    return 0
  fi
  log_warn "some steps failed — see the messages above."
  return 1
}
