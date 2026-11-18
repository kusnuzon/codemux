# shellcheck shell=bash
# lib/native.sh — native upstream install for the linux platform profile (PRD §21.2).
# On plain Linux there is no TermuxVoid repo, no glibc shim and no LD_PRELOAD
# dance: OpenCode publishes flat tarballs per arch —
#   opencode-linux-<arch>[-baseline][-musl].tar.gz  (single `opencode` binary)
# tagged v<major>.x.y in sst/opencode releases. V1 = major 1, V2 = major 2.
# Performs no action when sourced.

CODEMUX_UPSTREAM_RELEASES="${CODEMUX_UPSTREAM_RELEASES:-https://api.github.com/repos/sst/opencode/releases}"
CODEMUX_UPSTREAM_DOWNLOAD="${CODEMUX_UPSTREAM_DOWNLOAD:-https://github.com/sst/opencode/releases/download}"

codemux_native_arch() {
  case "$(uname -m 2>/dev/null)" in
    aarch64 | arm64) printf 'arm64' ;;
    x86_64) printf 'x64' ;;
    *) return 1 ;;
  esac
}

# musl hosts need the musl builds; glibc hosts the default ones.
codemux_native_variant() {
  if [ -e "/lib/ld-musl-$(uname -m 2>/dev/null).so.1" ]; then printf -- '-musl'; fi
}

# codemux_native_tag <major> -> latest v<major>.x.y tag (releases list is newest-first)
codemux_native_tag() {
  local major="$1" json tok
  tok="$(codemux_gh_token)"
  if [ -n "$tok" ]; then
    json="$(curl -sS --max-time 30 -H "Authorization: Bearer $tok" \
      "$CODEMUX_UPSTREAM_RELEASES?per_page=100")" || return 1
  else
    json="$(curl -sS --max-time 30 "$CODEMUX_UPSTREAM_RELEASES?per_page=100")" || return 1
  fi
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r --arg p "v$major." \
    '[.[].tag_name] | map(select(startswith($p))) | first // empty' || return 1
}

# codemux_native_asset <arch> <variant> <tag> -> candidate asset names, best first.
# x64 has a -baseline build for CPUs without the newer instructions; it is the
# fallback, tried only if the default binary fails its smoke test.
codemux_native_asset() {
  local arch="$1" variant="$2"
  if [ "$arch" = arm64 ]; then
    printf 'opencode-linux-arm64%s.tar.gz\n' "$variant"
  else
    printf 'opencode-linux-x64%s.tar.gz\n' "$variant"
    printf 'opencode-linux-x64%s-baseline.tar.gz\n' "$variant"
  fi
}

# codemux_native_install <major> <dest> <launcher> — install the latest native
# payload of that major into <dest>, write <dest>/VERSION, and point <launcher>
# at it. Idempotent: an already-current install is left untouched.
codemux_native_install() {
  local major="$1" dest="$2" launcher="$3"
  local arch variant tag v asset url stage ver

  arch="$(codemux_native_arch)" || { log_fail "native install: unsupported arch $(uname -m)"; return 1; }
  variant="$(codemux_native_variant)"
  tag="$(codemux_native_tag "$major")" || { log_fail "native install: cannot resolve latest v$major tag"; return 1; }
  [ -n "$tag" ] || { log_fail "native install: no v$major release found"; return 1; }
  v="${tag#v}"

  if [ "$(cat "$dest/VERSION" 2>/dev/null)" = "$v" ] && [ -x "$dest/opencode" ]; then
    return 0 # already current
  fi

  stage="$CODEMUX_HOME/cache/native-$major.$$"
  rm -rf "$stage"
  mkdir -p "$stage" || return 1

  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    url="$CODEMUX_UPSTREAM_DOWNLOAD/$tag/$asset"
    codemux_spin_msg "downloading $asset ($tag)"
    codemux_download "$url" "$stage/asset.tar.gz" || continue
    if ! tar xzf "$stage/asset.tar.gz" -C "$stage" 2>/dev/null; then
      rm -f "$stage/asset.tar.gz" "$stage/opencode"
      continue
    fi
    rm -f "$stage/asset.tar.gz"
    [ -x "$stage/opencode" ] || { rm -f "$stage/opencode"; continue; }
    # smoke the binary before it is installed: wrong-ISA builds die here and
    # the loop falls back to the next candidate (baseline on x64).
    ver="$("$stage/opencode" --version 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    case "$ver" in
      *"$v"*) : ;;
      *) rm -f "$stage/opencode"; continue ;;
    esac
    mkdir -p "$dest" "$(dirname "$launcher")" || { rm -rf "$stage"; return 1; }
    mv -f "$stage/opencode" "$dest/opencode" || { rm -rf "$stage"; return 1; }
    printf '%s\n' "$v" >"$dest/VERSION"
    {
      printf '#!/usr/bin/env bash\n'
      printf '# codemux native-linux launcher: plain exec, no glibc shim needed.\n'
      printf 'exec "%s/opencode" "$@"\n' "$dest"
    } >"$launcher.part"
    chmod +x "$launcher.part"
    mv -f "$launcher.part" "$launcher" || { rm -rf "$stage"; return 1; }
    rm -rf "$stage"
    return 0
  done <<EOF
$(codemux_native_asset "$arch" "$variant")
EOF

  rm -rf "$stage"
  log_fail "native install: no working $tag asset for $arch$variant"
  return 1
}
