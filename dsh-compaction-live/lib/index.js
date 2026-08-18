import { BasicCompactionEngine } from "@deepseek-ai/dsh-compaction-basic";

/** Plugin identity for the agent-preset composition row. */
const name = "compaction-live";

/** Settings namespace whose `thresholdRatio` this backend reads per check. */
const NS = "compaction";

/**
 * A `BasicCompactionEngine` subclass whose `thresholdRatio` is re-read from the
 * host `compaction` settings namespace on every pressure check. `this.config`
 * is a public field whose referenced object is frozen but whose field may be
 * reassigned, so each check rebuilds a fresh config from the resolved base
 * (preserving `retainRatio` and every other resolved default) and lets the
 * superclass run its full pressure / pruning / summarization / overflow logic
 * unchanged. Settings resolve from the host plane up the scope chain, exactly
 * like `tokenMeter`.
 */
class LiveCompactionEngine extends BasicCompactionEngine {
	constructor(ctx, config = {}) {
		super(ctx, config);
		/** Resolved frozen base config (all defaults, entry overrides applied). */
		this.baseConfig = this.config;
	}

	async compactIfNeeded(agent, trigger, signal) {
		const live = this.readLiveThreshold();
		if (live !== void 0) {
			this.config = { ...this.baseConfig, thresholdRatio: live };
		}
		return super.compactIfNeeded(agent, trigger, signal);
	}

	/**
	 * @returns the current `thresholdRatio` from the live settings section, or
	 * `undefined` when the namespace is unregistered or holds no number.
	 */
	readLiveThreshold() {
		const settings = this.ctx.get("settings");
		if (settings === void 0) return void 0;
		const section = settings.get(NS);
		const value = section === void 0 ? void 0 : section.thresholdRatio;
		return typeof value === "number" ? value : void 0;
	}
}

export { LiveCompactionEngine, name };
export default LiveCompactionEngine;