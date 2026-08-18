import { BasicCompactionEngine } from "@deepseek-ai/dsh-compaction-basic";
import { COMMAND_NAME, parseThreshold } from "@my-scope/dsh-compaction-ui";

/** Plugin identity for the agent-preset composition row. */
const name = "compaction-live";

/**
 * A `BasicCompactionEngine` subclass whose `thresholdRatio` is re-read from the
 * owning session's newest `/threshold` command event on every pressure check.
 * `this.config` is a public field whose referenced object is frozen but whose
 * field may be reassigned, so each check rebuilds a fresh config from the
 * resolved base (preserving `retainRatio` and every other resolved default)
 * and lets the superclass run its full pressure / pruning / summarization /
 * overflow logic unchanged. A session with no `/threshold` event falls back to
 * the entry config default (0.8), giving every session a fresh 80% start.
 */
class LiveCompactionEngine extends BasicCompactionEngine {
	constructor(ctx, config = {}) {
		super(ctx, config);
		/** Resolved frozen base config (all defaults, entry overrides applied). */
		this.baseConfig = this.config;
	}

	async compactIfNeeded(agent, trigger, signal) {
		const live = this.readLiveThreshold(agent);
		if (live !== void 0) {
			this.config = { ...this.baseConfig, thresholdRatio: live };
		}
		return super.compactIfNeeded(agent, trigger, signal);
	}

	/**
	 * @param agent - the session whose `/threshold` history is scanned.
	 * @returns the newest valid threshold ratio for this session (clamped to
	 * 0.4..1.0, rounded to two decimals), or `undefined` when the session has
	 * never set one (callers keep the default 0.8).
	 */
	readLiveThreshold(agent) {
		const events = agent.session.events;
		for (let index = events.length - 1; index >= 0; index--) {
			const event = events[index];
			if (event.type !== "command/run" || event.data?.name !== COMMAND_NAME) continue;
			const ratio = parseThreshold(event.data?.args);
			if (ratio !== void 0) return ratio;
		}
		return void 0;
	}
}

export { LiveCompactionEngine, name };
export default LiveCompactionEngine;