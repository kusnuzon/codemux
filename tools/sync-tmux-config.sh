#!/data/data/com.termux/files/usr/bin/bash
# tools/sync-tmux-config.sh — copy the tmux config block from
# lib/tmux-config.sh into the sibling repos, or check that they match.
#
#   bash tools/sync-tmux-config.sh          # write the copies
#   bash tools/sync-tmux-config.sh --check  # exit 1 when a copy has drifted
#
# Targets are found next to this repo (../../<name>), so the script works from
# any checkout. The copied text is the block between the two markers in
# lib/tmux-config.sh, minus the markers themselves.
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
SRC="$ROOT/lib/tmux-config.sh"
PARENT="$(cd "$ROOT/.." && pwd)"

# <target repo>:<path inside it>:<what to print>
TARGETS=(
  "opencode-termux:install.sh:opencode-termux/install.sh"
  "opencode-termux-v2:lib/common.sh:opencode-termux-v2/lib/common.sh"
)

BEGIN='# ---8<--- tmux-config begin ---8<---'
END='# ---8<--- tmux-config end ---8<---'
HDR_BEGIN='# --- tmux-config begin (synced from codemux/lib/tmux-config.sh) ---'
HDR_END='# --- tmux-config end ---'

check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) printf 'usage: %s [--check]\n' "${0##*/}" >&2; exit 2 ;;
esac

[ -f "$SRC" ] || { printf 'missing %s\n' "$SRC" >&2; exit 1; }

block="$(awk -v b="$BEGIN" -v e="$END" '
  $0 == b { on = 1; next }
  $0 == e { on = 0 }
  on { print }
' "$SRC")"
[ -n "$block" ] || { printf 'cannot read the block from %s\n' "$SRC" >&2; exit 1; }

rendered="$(printf '%s\n%s\n%s\n' "$HDR_BEGIN" "$block" "$HDR_END")"
# awk -v would eat the backslashes in the block (it processes escapes in an
# assignment), which silently broke the tmux bindings once. The text is handed
# over as a file instead, so every byte survives.
blockfile="${TMPDIR:-/tmp}/codemux-tmuxconf.$$"
printf '%s\n' "$rendered" >"$blockfile" || exit 1
trap 'rm -f "$blockfile"' EXIT
drift=0

for t in "${TARGETS[@]}"; do
  repo="${t%%:*}"; rest="${t#*:}"; rel="${rest%%:*}"; label="${rest#*:}"
  file="$PARENT/$repo/$rel"
  if [ ! -f "$file" ]; then
    printf 'skip %s (not found)\n' "$label"
    continue
  fi
  if grep -qF "$HDR_BEGIN" "$file"; then
    # replace an existing synced block
    tmp="$file.sync.$$"
    awk -v b="$HDR_BEGIN" -v e="$HDR_END" -v new="$blockfile" '
      $0 == b {
        while ((getline line < new) > 0) print line
        close(new)
        skip = 1
        next
      }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$file" >"$tmp"
  else
    printf 'no sync markers in %s\n' "$label" >&2
    printf 'add them first:\n  %s\n  %s\n' "$HDR_BEGIN" "$HDR_END" >&2
    drift=1
    continue
  fi

  if cmp -s "$tmp" "$file"; then
    printf 'ok   %s\n' "$label"
    rm -f "$tmp"
  elif [ "$check" -eq 1 ]; then
    printf 'DRIFT %s\n' "$label"
    # sed stops early, so the pipeline exits on SIGPIPE under pipefail; the
    # drift report is best-effort and must not abort before the temp file goes.
    diff -u "$file" "$tmp" | sed -n '1,40p' || true
    rm -f "$tmp"
    drift=1
  else
    mv "$tmp" "$file"
    printf 'wrote %s\n' "$label"
  fi
done

[ "$drift" -eq 0 ]
