// managed-by: codemux pi module (rewritten on `codemux install` when it differs)
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// free-pi hardcodes defaultThinkingLevel: "off" in its bundled settings and
// rewrites settings.json on every start, so /thinking + Ctrl+S never sticks.
// This extension re-applies the wanted level for each new session.
const LEVEL = "medium" as const;

export default function (pi: ExtensionAPI) {
  pi.on("session_start", () => {
    try {
      pi.setThinkingLevel(LEVEL);
    } catch {
      // Model without thinking support: pi clamps or rejects, nothing to do.
    }
  });
}
