// managed-by: codemux pi module (rewritten on `codemux install` when it differs)
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// free-pi forces theme:"light/dark" in buildSettingsManager() and rewrites
// global settings on every start, so the "theme" key in settings.json never
// sticks. The custom theme file lives in <agent-dir>/themes/ (auto-loaded);
// this extension re-selects it via ctx.ui.setTheme on each session start.
const THEME = "amoled-calm";

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (ctx?.mode !== "tui" || !ctx.ui) return;
    try {
      ctx.ui.setTheme(THEME);
    } catch {
      // Theme missing or UI not ready: nothing to do.
    }
  });
}
