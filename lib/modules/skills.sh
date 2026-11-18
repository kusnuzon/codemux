# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/APPLY_NOTE/globals are shared across files
# module: skills — agent skills in ~/.agents/skills and their tool dependencies.
#
# Two jobs:
# 1. Keep the managed skills (canonical copies in $CODEMUX_ROOT/skills) in sync
#    with the installed copies. The two bundled rewrites replace skill docs that
#    assumed a Node Playwright CLI which cannot run on Android; the canonical
#    text targets Python Playwright from kusnuzon/zplaywright instead.
# 2. Make sure the Python side of that stack is importable: pyee (patcher
#    dependency) and the zplaywright-patched playwright package. Chromium itself
#    is an optional apt package handled by the toolset module (CODEMUX_APT_EXTRA).

CODEMUX_SKILLS_DIR="${CODEMUX_SKILLS_DIR:-$HOME/.agents/skills}"
CODEMUX_SKILLS_MANAGED=(agent-browser webapp-testing)

# Marker written into every managed skill file; the probe uses it to tell a
# codemux-managed copy from a foreign one.
CODEMUX_SKILLS_MARKER="managed-by: codemux skills module"

# On plain Linux the Python side is the official Playwright package (`pip
# install playwright` + `playwright install chromium`); the zplaywright patcher
# and its installer URL are Termux-only workarounds for the android-arm64
# wheel that upstream does not ship.
skills_python_module() {
  case "$(codemux_detect_platform)" in
    linux) printf 'playwright' ;;
    *) printf 'pyee' ;;
  esac
}

skills_python_ok() { python3 -c "import $1" >/dev/null 2>&1; }

# Prints "missing" entries: "skill:<name>" for a bad/absent managed skill copy,
# "pip:<module>" for a missing Python module.
skills_missing_items() {
  local s src dst
  for s in "${CODEMUX_SKILLS_MANAGED[@]}"; do
    src="$CODEMUX_ROOT/skills/$s/SKILL.md"
    dst="$CODEMUX_SKILLS_DIR/$s/SKILL.md"
    if [ ! -f "$src" ]; then
      printf 'skill:%s (canonical file missing)\n' "$s"
    elif [ ! -f "$dst" ] || ! grep -qF "$CODEMUX_SKILLS_MARKER" "$dst" || ! cmp -s "$src" "$dst"; then
      printf 'skill:%s\n' "$s"
    fi
  done
  skills_python_ok "$(skills_python_module)" || printf 'pip:%s\n' "$(skills_python_module)"
}

m_skills_probe() {
  local miss n
  miss="$(skills_missing_items)"
  if [ -z "$miss" ]; then
    PROBE=OK
    case "$(codemux_detect_platform)" in
      linux) NOTE="${#CODEMUX_SKILLS_MANAGED[@]} skills synced · playwright importable" ;;
      *) NOTE="${#CODEMUX_SKILLS_MANAGED[@]} skills synced · pyee + playwright importable" ;;
    esac
  else
    n="$(printf '%s\n' "$miss" | wc -l | tr -d ' ')"
    PROBE=MISS
    NOTE="$n item(s) missing/stale: $(printf '%s' "$miss" | tr '\n' ' ' | sed 's/ *$//')"
  fi
  if ! command -v chromium-browser >/dev/null 2>&1; then
    NOTE="$NOTE · chromium-browser absent (optional, toolset extra)"
    [ "$PROBE" = OK ] && PROBE=WARN
  fi
}

m_skills_verify() { m_skills_probe; }

m_skills_apply() {
  local miss s src dst dir bak
  miss="$(skills_missing_items)"

  # Python dependencies first: the skills are useless without them.
  case "$(codemux_detect_platform)" in
    linux)
      if ! skills_python_ok playwright; then
        codemux_spin_msg "pip install playwright"
        if ! pip install playwright >/dev/null 2>&1; then
          APPLY_NOTE="pip install playwright failed"
          return 1
        fi
      fi
      ;;
    *)
      if ! skills_python_ok pyee; then
        codemux_spin_msg "pip install pyee"
        if ! pip install pyee >/dev/null 2>&1; then
          APPLY_NOTE="pip install pyee failed"
          return 1
        fi
      fi
      if ! skills_python_ok playwright; then
        if [ -z "${CODEMUX_ZPLAYWRIGHT_INSTALL:-}" ]; then
          APPLY_NOTE="CODEMUX_ZPLAYWRIGHT_INSTALL is not set (versions.env missing?)"
          return 1
        fi
        codemux_spin_msg "installing zplaywright (Playwright patcher for Termux)"
        if ! curl -fsSL "$CODEMUX_ZPLAYWRIGHT_INSTALL" | bash >/dev/null 2>&1; then
          APPLY_NOTE="zplaywright installer failed"
          return 1
        fi
        skills_python_ok playwright || {
          APPLY_NOTE="playwright still not importable after zplaywright install"
          return 1
        }
      fi
      ;;
  esac

  # Sync the managed skill docs (backup a differing foreign copy once).
  for s in "${CODEMUX_SKILLS_MANAGED[@]}"; do
    src="$CODEMUX_ROOT/skills/$s/SKILL.md"
    dst="$CODEMUX_SKILLS_DIR/$s/SKILL.md"
    [ -f "$src" ] || continue
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then continue; fi
    dir="$(dirname "$dst")"
    mkdir -p "$dir" || {
      APPLY_NOTE="cannot create $dir"
      return 1
    }
    if [ -f "$dst" ]; then
      bak="$dst.bak-$(date +%Y%m%d%H%M%S)"
      cp "$dst" "$bak" 2>/dev/null || true
    fi
    cp "$src" "$dst" || {
      APPLY_NOTE="cannot write $dst"
      return 1
    }
  done

  if [ -z "$miss" ]; then
    APPLY_NOTE="nothing to install"
  else
    APPLY_NOTE="installed/synced: $(printf '%s' "$miss" | tr '\n' ' ' | sed 's/ *$//')"
  fi
}
