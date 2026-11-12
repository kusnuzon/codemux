# shellcheck shell=bash
# lib/update.sh — `codemux update-check`: compare local versions with upstream releases.
# Cheap: uses the /releases/latest redirect (no API quota), 24h cache.
# Offline/failure → silent: the old cache is kept.

codemux_update_cache() { printf '%s/update-cache.tsv' "$CODEMUX_HOME"; }

# Read the latest release tag from the GitHub redirect (no API, no quota).
# Tests can force the result via CODEMUX_FAKE_TAG_*.
codemux_latest_tag() {
  local repo="$1" envname eff base
  envname="CODEMUX_FAKE_TAG_$(printf '%s' "${repo##*/}" | tr '[:lower:]-' '[:upper:]_')"
  eval "eff=\"\${$envname:-}\""
  if [ -n "$eff" ]; then printf '%s' "$eff"; return 0; fi

  base="${CODEMUX_GITHUB_BASE:-https://github.com}"
  eff="$(curl -fsSIL -o /dev/null -w '%{url_effective}' --max-time 8 \
    "$base/$repo/releases/latest" 2>/dev/null)" || return 1
  case "$eff" in
    */tag/*) printf '%s' "${eff##*/tag/}" ;;
    *) return 1 ;;
  esac
}

# "opencode-termux-v2-2.1.3" → "2.1.3"; "v0.5.0" → "0.5.0"
codemux_norm_ver() {
  printf '%s' "$1" | sed -n 's/.*[^0-9.]\([0-9][0-9.]*\)$/\1/p'
}

codemux_ver_newer() { # <candidate> <current> → 0 when the candidate is newer
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] &&
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | tail -n 1)" = "$1" ]
}

codemux_apt_upgradable() {
  [ "${CODEMUX_NO_APT_CHECK:-0}" = 1 ] && { printf 0; return 0; }
  command -v apt-get >/dev/null 2>&1 || { printf 0; return 0; }
  timeout 20 apt-get -s -q upgrade 2>/dev/null | grep -c '^Inst ' || true
}

# Write the cache: component<TAB>local<TAB>latest<TAB>status
codemux_update_write_cache() {
  local file tmp_lines="$1"
  file="$(codemux_update_cache)"
  mkdir -p "$CODEMUX_HOME" || return 1
  printf '%s\n' "$tmp_lines" | codemux_atomic_write "$file"
}

# Local version; the CODEMUX_FAKE_LOCAL_* env vars are used by tests (no real payload).
codemux_local_version() {
  case "$1" in
    codemux) printf '%s' "${CODEMUX_FAKE_LOCAL_CODEMUX:-$CODEMUX_VERSION}" ;;
    opencode-v1) printf '%s' "${CODEMUX_FAKE_LOCAL_V1:-$(opencode_v1_version)}" ;;
    opencode-v2) printf '%s' "${CODEMUX_FAKE_LOCAL_V2:-$(opencode_v2_version)}" ;;
  esac
}

# The "latest" version already known from the previous cache.
# Used when the network fails briefly: an older result must not be overwritten
# with "na", because "na" lines are not reported by the menu and the cache lasts
# 24 hours — an update that was already known would stay invisible all day.
codemux_prev_latest() { # <component>
  local f v
  f="$(codemux_update_cache)"
  [ -f "$f" ] || return 0
  v="$(awk -F'\t' -v c="$1" '$1==c && $3!="-" && $3!="" {print $3}' "$f" 2>/dev/null | tail -n 1)"
  [ -n "$v" ] || return 0
  printf '%s' "$v"
}

codemux_update_rows() { # print the TSV rows of the current check
  local c_local="$CODEMUX_VERSION" c_latest="" v1 v1_latest v2 v2_latest apt_n
  local state

  c_local="$(codemux_local_version codemux)"
  c_latest="$(codemux_norm_ver "$(codemux_latest_tag "${UPSTREAM_CODEMUX:-kusnuzon/codemux}" 2>/dev/null || true)")"
  [ -n "$c_latest" ] || c_latest="$(codemux_prev_latest codemux)"
  v1="$(codemux_local_version opencode-v1)"
  v1_latest="$(codemux_norm_ver "$(codemux_latest_tag "${UPSTREAM_V1:-kusnuzon/opencode-termux}" 2>/dev/null || true)")"
  [ -n "$v1_latest" ] || v1_latest="$(codemux_prev_latest opencode-v1)"
  v2="$(codemux_local_version opencode-v2)"
  v2_latest="$(codemux_norm_ver "$(codemux_latest_tag "${UPSTREAM_V2:-kusnuzon/opencode-termux-v2}" 2>/dev/null || true)")"
  [ -n "$v2_latest" ] || v2_latest="$(codemux_prev_latest opencode-v2)"

  case "$c_local" in [!0-9]*) state="na" ;; *) state="" ;; esac
  if [ -z "$c_latest" ] || [ "$state" = na ]; then
    state="na"; c_latest="${c_latest:--}"
  else
    state="ok"
    codemux_ver_newer "$c_latest" "$c_local" && state="update"
  fi
  printf 'codemux\t%s\t%s\t%s\n' "$c_local" "$c_latest" "$state"

  # Only components that are installed are reported (a V1-only device gets no V2
  # row). Before the first install nothing is detected, so the saved choice is
  # used and the plan still shows what will be installed.
  local comps want_v1=0 want_v2=0
  comps="$(codemux_components_installed)"
  [ -n "$comps" ] || comps="$(codemux_components_get)"
  case " $comps " in *" v1 "*) want_v1=1 ;; esac
  case " $comps " in *" v2 "*) want_v2=1 ;; esac
  if [ "$want_v1" = 1 ]; then
    case "$v1" in [!0-9]*) state="na" ;; *) state="" ;; esac
    if [ -z "$v1_latest" ] || [ "$state" = na ]; then state="na"; v1_latest="${v1_latest:--}"; else
      state="ok"; codemux_ver_newer "$v1_latest" "$v1" && state="update"
    fi
    printf 'opencode-v1\t%s\t%s\t%s\n' "$v1" "$v1_latest" "$state"
  fi

  if [ "$want_v2" = 1 ]; then
    case "$v2" in [!0-9]*) state="na" ;; *) state="" ;; esac
    if [ -z "$v2_latest" ] || [ "$state" = na ]; then state="na"; v2_latest="${v2_latest:--}"; else
      state="ok"; codemux_ver_newer "$v2_latest" "$v2" && state="update"
    fi
    printf 'opencode-v2\t%s\t%s\t%s\n' "$v2" "$v2_latest" "$state"
  fi

  apt_n="$(codemux_apt_upgradable)"
  state="ok"; [ "${apt_n:-0}" -gt 0 ] && state="update"
  printf 'apt\t%s\t-\t%s\n' "$apt_n" "$state"
}

codemux_update_count() { # how many rows have status update in the cache
  local f
  f="$(codemux_update_cache)"
  [ -f "$f" ] || { printf 0; return 0; }
  awk -F'\t' '$4=="update"' "$f" 2>/dev/null | wc -l | tr -d ' '
}

codemux_update_summary_line() { # used by the launcher (menu): one short line
  local f n
  f="$(codemux_update_cache)"
  [ -f "$f" ] || return 1
  n="$(codemux_update_count)"
  [ "${n:-0}" -gt 0 ] || return 1
  awk -F'\t' '$4=="update" {printf "%s%s", sep, ($1=="apt" ? $2 " apt packages" : $1 " " $3); sep=" · "}' "$f"
}

codemux_cmd_update_check() {
  local json=0 quiet=0 a rows n
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      --quiet | -q) quiet=1 ;;
      -h | --help)
        printf '%s\n' 'usage: codemux update-check [--json] [--quiet]' \
          '' 'Compare local versions (codemux, OpenCode V1/V2, apt packages) with' \
          'upstream releases. The result is cached for 24 hours; nothing is downloaded.' \
          '--quiet only refreshes the cache (used by the menu in the background).'
        return 0
        ;;
      *) log_warn "unknown option for update-check: $a" ;;
    esac
  done

  rows="$(codemux_update_rows)"
  codemux_update_write_cache "$rows" || {
    log_fail "cannot write the cache in $CODEMUX_HOME"; return 2
  }
  [ "$quiet" -eq 1 ] && return 0
  n="$(codemux_update_count)"

  if [ "$json" -eq 1 ]; then
    printf '{"diperiksa":"%s","update":%d,"komponen":[' "$(date '+%Y-%m-%dT%H:%M:%S')" "$n"
    local first=1 comp local_v latest_v st
    while IFS=$'\t' read -r comp local_v latest_v st; do
      [ -n "$comp" ] || continue
      [ "$first" -eq 1 ] || printf ','
      printf '{"nama":"%s","lokal":"%s","terbaru":"%s","status":"%s"}' \
        "$(json_escape "$comp")" "$(json_escape "$local_v")" \
        "$(json_escape "$latest_v")" "$(json_escape "$st")"
      first=0
    done <<<"$rows"
    printf ']}\n'
    return 0
  fi

  printf '%s%s %s%s · upstream update check\n\n' "$C_B" "$CODEMUX_NAME" "$CODEMUX_VERSION" "$C_R"
  printf '  %-14s %-12s %-12s %s\n' component local latest status
  local comp local_v latest_v st
  while IFS=$'\t' read -r comp local_v latest_v st; do
    [ -n "$comp" ] || continue
    case "$st" in
      update) printf '  %-14s %-12s %-12s %supdate%s\n' "$comp" "$local_v" "$latest_v" "$C_WARN" "$C_R" ;;
      na) printf '  %-14s %-12s %-12s %s\n' "$comp" "$local_v" "$latest_v" "not detected" ;;
      *) printf '  %-14s %-12s %-12s %s\n' "$comp" "$local_v" "$latest_v" "latest" ;;
    esac
  done <<<"$rows"
  printf '\n'
  if [ "${n:-0}" -gt 0 ]; then
    log_warn "$n components can be updated — run: codemux upgrade"
  else
    log_ok "all components are up to date (as far as we can tell)."
  fi
  log_dim "cache: $(codemux_update_cache) · re-checked automatically after 24 hours"
  return 0
}
