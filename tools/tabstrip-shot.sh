#!/usr/bin/env bash
# tools/tabstrip-shot.sh — render the tab strip exactly as tmux draws it and
# save a PNG, so a change to the strip can be looked at instead of assumed.
#
# It boots a throwaway tmux server with the managed block from ~/.tmux.conf,
# evaluates the real window-status formats for each window, converts the
# #[fg=...#,bg=...#,bold] codes into styled HTML and screenshots that page with
# headless Chromium. Nothing on the real server is touched. The #[range=user|…]
# markers the click handler uses are stripped: they are invisible in a terminal.
#
# usage: bash tools/tabstrip-shot.sh [-n windows] [-p pending] [-a active]
#                                    [-t title,title,...] [out.png]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
BASE="${TMPDIR:-/tmp}"
[ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ] && BASE="$PREFIX/tmp"
WORK="$BASE/codemux-shot-$$"

n=5 pending="" active=0 titles="" out="tabstrip.png"
while [ $# -gt 0 ]; do
  case "$1" in
    -n) n="$2"; shift 2 ;;
    -p) pending="$2"; shift 2 ;;
    -a) active="$2"; shift 2 ;;
    -t) titles="$2"; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) out="$1"; shift ;;
  esac
done

command -v tmux >/dev/null 2>&1 || { echo "tabstrip-shot: tmux is missing" >&2; exit 1; }

cleanup() { tmux -L codemuxshot kill-server >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"; mkdir -p "$WORK"

S="main"
tmux -L codemuxshot new-session -d -s "$S" -x 90 -y 20 "sleep 120" || exit 1
[ -f "$HOME/.tmux.conf" ] && tmux -L codemuxshot source-file "$HOME/.tmux.conf" >/dev/null 2>&1

# Fill the session with n windows; names come from -t (comma separated) or a
# small default set that looks like real prompts.
[ -n "$titles" ] || titles="menu,tidy-docs,test-new-tab,read-logs,fix-bug-queue,deploy"
i=1
while [ "$i" -lt "$n" ]; do
  name="$(printf '%s' "$titles" | cut -d, -f$((i + 1)))"
  [ -n "$name" ] && tmux -L codemuxshot new-window -t "$S:" -n "$name" "sleep 120" >/dev/null 2>&1
  i=$((i + 1))
done
# -p <tab> marks that tab as waiting for its close confirmation: the tab itself
# turns into the keep/close buttons (the format from the managed block does it).
# The right end of the bar is empty: the " + " button rides on the last tab, so
# the format above already draws it and nothing is appended here.
right="$(tmux -L codemuxshot show -gv status-right)"
if [ -n "$pending" ]; then
  tmux -L codemuxshot set-option -t "$S" @closepending "$pending"
else
  tmux -L codemuxshot set-option -t "$S" -u @closepending 2>/dev/null
fi
tmux -L codemuxshot select-window -t "$S:$active" >/dev/null 2>&1

fmt="$(tmux -L codemuxshot show -gv window-status-format)"
cur="$(tmux -L codemuxshot show -gv window-status-current-format)"

# One line of real format output per window, in index order.
: >"$WORK/tabs.txt"
idx=0
while [ "$idx" -lt "$n" ]; do
  if [ "$idx" = "$active" ]; then
    tmux -L codemuxshot display -p -t "$S:$idx" "$cur" >>"$WORK/tabs.txt"
  else
    tmux -L codemuxshot display -p -t "$S:$idx" "$fmt" >>"$WORK/tabs.txt"
  fi
  idx=$((idx + 1))
done

python3 - "$WORK" "$right" "$n" "$out" <<'PY' || exit 1
import html, re, sys, pathlib
work, right, n, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
tabs = pathlib.Path(work, "tabs.txt").read_text(encoding="utf-8").split("\n")
tabs = [t for t in tabs if t != ""]
style_re = re.compile(r"#\[([^]]*)\]")

def spans(text, base_fg="#8a8f98", base_bg="#000000"):
    """Turn tmux style codes into HTML spans; user ranges are invisible."""
    out, i, cur = [], 0, (base_fg, base_bg, "normal")
    for m in style_re.finditer(text):
        chunk = text[i:m.start()]
        if chunk:
            fg, bg, weight = cur
            out.append(
                f'<span style="color:{fg};background:{bg};font-weight:{weight}">'
                f'{html.escape(chunk)}</span>'
            )
        fg, bg, weight = cur
        for part in m.group(1).split(","):
            if part.startswith("fg="):
                fg = part[3:]
            elif part.startswith("bg="):
                bg = part[3:]
            elif part == "bold":
                weight = "bold"
            elif part.startswith("range=") or part in ("default", "none"):
                pass
        cur = (fg, bg, weight)
        i = m.end()
    tail = text[i:]
    if tail:
        fg, bg, weight = cur
        out.append(
            f'<span style="color:{fg};background:{bg};font-weight:{weight}">'
            f'{html.escape(tail)}</span>'
        )
    return "".join(out)

bar = "".join(spans(t, base_fg="#8a8f98") for t in tabs) + spans(right, base_fg="#c0c0c0")
doc = f"""<!doctype html><meta charset=utf-8>
<style>
  body {{ margin:0; background:#000; }}
  .term {{ font: 700 15px/1.45 'DejaVu Sans Mono',monospace; background:#000000; color:#c0c0c0;
           width: 900px; padding: 0; }}
  .bar {{ white-space: pre; height: 22px; }}
  .pane {{ white-space: pre; padding: 6px 0 0 0; color:#c0c0c0; }}
  .hint {{ color:#5f6368; font-size:12px; padding:4px 6px; }}
</style>
<div class=term>
  <div class=bar>{bar}</div>
  <div class=pane>{html.escape(chr(10).join(['  π free-pi v0.6.22 · DeepSeek V4.1 Flash', '', '  > ']))}</div>
  <div class=hint>tabstrip-shot · tmux {html.escape(n)} tab</div>
</div>
"""
pathlib.Path(work, "strip.html").write_text(doc, encoding="utf-8")
print(pathlib.Path(work, "strip.html"))
PY

HTML="$WORK/strip.html"
SHOT="$out"
case "$SHOT" in /*) ;; *) SHOT="$ROOT/$out" ;; esac
for bin in chromium-browser chromium; do
  command -v "$bin" >/dev/null 2>&1 || continue
  "$bin" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=900,240 --screenshot="$SHOT" "file://$HTML" >/dev/null 2>&1 && break
done
if [ -s "$SHOT" ]; then
  echo "screenshot: $SHOT"
else
  echo "tabstrip-shot: screenshot failed (chromium missing?)" >&2
  exit 1
fi
