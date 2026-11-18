#!/usr/bin/env bash
# work-diff.sh — show what an edit just changed, live in a work pane.
# usage: work-diff.sh <file> [more files...]
# Computes the current change for each file (git diff for tracked files in a
# repo, a head preview for new/untracked files, numbered content for files
# outside any repo) and displays it through work.sh, so the edit is visible
# in tmux the same way executed commands are. A full copy lands in ~/work.log.
set -u

[ $# -ge 1 ] || { echo "usage: work-diff.sh <file> [more files...]" >&2; exit 2; }

tmp="$(mktemp "${TMPDIR:-${PREFIX:-/tmp}}/work-diff.XXXXXX")" || exit 3

for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "work-diff: not a file: $f" >>"$tmp"
    continue
  fi
  d="${f%/*}"; [ "$d" = "$f" ] && d=.
  b="${f##*/}"
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$d" ls-files --error-unmatch -- "$b" >/dev/null 2>&1; then
      git -C "$d" diff -- "$b" >>"$tmp" 2>/dev/null || true
    else
      echo "--- new file: $f (first 40 lines) ---" >>"$tmp"
      head -n 40 "$f" >>"$tmp"
    fi
  else
    echo "--- outside a repo: $f (first 40 lines) ---" >>"$tmp"
    head -n 40 "$f" >>"$tmp"
  fi
done

if [ ! -s "$tmp" ]; then
  echo "work-diff: no changes to show" >&2
  rm -f "$tmp"
  exit 0
fi

name="$(basename "$1")"
[ $# -gt 1 ] && name="$#-files"
bash "$HOME/bin/work.sh" "edit $name" -- "cat \"$tmp\"; rm -f \"$tmp\""
