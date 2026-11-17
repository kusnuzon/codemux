#!/usr/bin/env bash
# sync-opencode-files.sh — single source for the files that must stay identical
# in opencode-termux (V1) and opencode-termux-v2 (V2).
#
# The canonical copies live in this repo (opencode-shared/). The two installers
# differ on purpose — upstream opencode 1.x and 2.x have different architecture
# (daemon, library shim, updater) — but the plugins, the memory templates and
# the LICENSE are the same files in both repos. Editing one copy and forgetting
# the other is exactly how the kuota->quota rename drifted between the repos.
#
#   sync-opencode-files.sh                      copy canonical -> both repos
#   sync-opencode-files.sh --check              verify only, exit 1 on drift
#   sync-opencode-files.sh --check <dir> ...    explicit repo roots (used by CI)
#
# With no repo arguments the two repos are expected next to this repository,
# like on the maintainer machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SYNC_FILES_SRC:-$ROOT/opencode-shared}"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

# The file list is whatever lives in the canonical tree: adding a shared file
# means adding it to opencode-shared/, nothing else to maintain.
if [ ! -d "$SRC" ]; then
  echo "FAIL canonical directory missing: $SRC" >&2
  exit 1
fi
FILES="$(cd "$SRC" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
if [ -z "$FILES" ]; then
  echo "FAIL canonical directory is empty: $SRC" >&2
  exit 1
fi

repos=()
check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) repos+=("$1"); shift ;;
  esac
done
if [ "${#repos[@]}" -eq 0 ]; then
  # shellcheck disable=SC2034  # filled via nameref-free append below
  repos+=("$ROOT/../opencode-termux" "$ROOT/../opencode-termux-v2")
fi

if [ ! -d "$SRC" ]; then
  echo "FAIL canonical directory missing: $SRC" >&2
  exit 1
fi

status=0
for repo in "${repos[@]}"; do
  if [ ! -d "$repo" ]; then
    echo "FAIL repo not found: $repo" >&2
    status=1
    continue
  fi
  name="$(basename "$repo")"
  # word splitting on $FILES is intentional: one path per line, no spaces
  # shellcheck disable=SC2086
  for f in $FILES; do
    if [ ! -f "$repo/$f" ]; then
      if [ "$check" = 1 ]; then
        echo "FAIL $name: file missing: $f" >&2
        status=1
        continue
      fi
      # sync mode: a file the repo does not have yet is the normal case
      mkdir -p "$(dirname "$repo/$f")"
      cp "$SRC/$f" "$repo/$f"
      echo "sync $name $f"
      continue
    fi
    if cmp -s "$SRC/$f" "$repo/$f"; then
      [ "$check" = 1 ] && echo "ok   $name $f"
      continue
    fi
    if [ "$check" = 1 ]; then
      echo "DRIFT $name $f" >&2
      status=1
    else
      cp "$SRC/$f" "$repo/$f"
      echo "sync $name $f"
    fi
  done
done

if [ "$status" = 0 ]; then
  echo "shared opencode files: in sync"
fi
exit "$status"
