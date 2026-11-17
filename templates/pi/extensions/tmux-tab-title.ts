// managed-by: codemux pi module (rewritten on `codemux install` when it differs)
/**
 * Tab titles for the codemux tmux tab strip.
 *
 * Every tab in the `pi` tmux session runs its own pi, so without this they all
 * read "pi". This renames the tmux window that holds this pi to the user's
 * latest prompt (whitespace flattened, cut at a word boundary, at most
 * TAB_TITLE_MAX characters), which is the title the status bar shows.
 *
 * The tab strip pads every tab to a fixed width, so keeping the title short
 * keeps the tap targets even. A tab renamed by hand (prefix + comma) keeps its
 * name: once the window name is no longer the one this extension set, it stops
 * touching it. No model call and nothing to do outside tmux (no TMUX_PANE).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const MAX = Number(process.env.TAB_TITLE_MAX ?? 12); // fits the 15-column tab slot with the index
// What the tab is called before any prompt: the launcher names it "pi".
const PLACEHOLDER = "pi";

function tidy(text: string): string {
	const flat = text.replace(/\s+/g, " ").trim();
	if (flat.length <= MAX) {
		return flat;
	}
	const cut = flat.slice(0, MAX - 1);
	const space = cut.lastIndexOf(" ");
	// Only honour a word boundary near the end: cutting at the first word of a
	// long sentence would throw most of the budget away.
	const body = space >= MAX - 5 ? cut.slice(0, space) : cut;
	return `${body.trimEnd()}…`;
}

export default function (pi: ExtensionAPI) {
	const pane = process.env.TMUX_PANE;
	if (!pane) {
		return;
	}

	let current = "";

	pi.on("before_agent_start", async (event) => {
		// Only real user prompts: custom triggers have no prompt text.
		if (event.messageType !== "user" || !event.prompt) {
			return;
		}
		const title = tidy(event.prompt);
		if (!title || title === current) {
			return;
		}

		// Rename the window that owns this pane, never another tab.
		const found = await pi.exec("tmux", [
			"display-message",
			"-p",
			"-t",
			pane,
			"#{window_id}\t#{window_name}",
		]);
		if (found.code !== 0) {
			return;
		}
		const [id, name] = (found.stdout ?? "").trim().split("\t");
		if (!id) {
			return;
		}
		// A name we did not set means the tab was renamed by hand: leave it be.
		if (name !== (current || PLACEHOLDER)) {
			return;
		}

		await pi.exec("tmux", ["rename-window", "-t", id, "--", title]);
		current = title;
	});
}
