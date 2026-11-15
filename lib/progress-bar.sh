# progress-bar.sh — the one ASCII progress bar used by codemux,
# opencode-termux and opencode-termux-v2.
#
# This file is the single source of truth. Do not edit the copies in the
# other repos: change this file, then run tools/sync-progress-bar.sh in
# codemux, which copies the block between the markers below into each repo
# and fails when a copy drifts.
#
# The block is copied verbatim, so it must not depend on anything outside
# itself: no colour variables, no helper functions, plain bash builtins only.

# ---8<--- progress-bar begin ---8<---
# progress_bar <percent> [width] [label] — plain ASCII bar + percentage.
# Out-of-range and non-numeric input is clamped, never an error: the callers
# use it inside command substitution, where an error would print garbage.
progress_bar() {
  local pct="${1:-0}" width="${2:-24}" label="${3:-}"
  local filled blank bar dash
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  [ "$width" -gt 0 ] 2>/dev/null || width=24
  filled=$((pct * width / 100))
  blank=$((width - filled))
  printf -v bar '%*s' "$filled" ''
  printf -v dash '%*s' "$blank" ''
  bar="${bar// /#}"
  dash="${dash// /-}"
  printf '[%s%s] %3d%%' "$bar" "$dash" "$pct"
  [ -n "$label" ] && printf '  %s' "$label"
  return 0
}

# progress_step <current> <total> <label> — a numbered bar line.
progress_step() {
  progress_bar "$((10#${1:-0} * 100 / 10#${2:-1}))" 24 "${1:-0}/${2:-0} ${3:-}"
}
# ---8<--- progress-bar end ---8<---
