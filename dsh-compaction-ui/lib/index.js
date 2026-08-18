import { z } from "zod";

/** Plugin identity for the host composition row. */
const name = "compaction-settings";

/** Host services this plugin needs: the command registry and the projection registry. */
const inject = ["commands", "sessionProjections"];

/**
 * Slash command name carrying each session's compaction trigger ratio. The
 * `command/run` session event this command produces (with the raw input in
 * `args`) is the session-scoped, replayable store the live compaction backend
 * reads; no custom session event type or settings document is involved.
 */
const COMMAND_NAME = "threshold";

/** Client-facing projection view schema: the whole-value threshold view. */
const ThresholdViewSchema = z.object({
	thresholdRatio: z.number()
});

/**
 * Parse a `/threshold` raw input into a clamped two-decimal ratio.
 * @param raw - the command's raw input string (or anything else).
 * @returns ratio clamped to 0.4..1.0, or `undefined` when unparseable.
 */
function parseThreshold(raw) {
	if (typeof raw !== "string") return void 0;
	const ratio = Number(raw.trim());
	if (!Number.isFinite(ratio)) return void 0;
	return Math.min(1, Math.max(0.4, Math.round(ratio * 100) / 100));
}

/** Fold one session event into the per-session threshold state (whole-value). */
function foldThresholdEvent(state, event) {
	if (event.type !== "command/run" || event.data?.name !== COMMAND_NAME) return state;
	const ratio = parseThreshold(event.data?.args);
	if (ratio === void 0) return state;
	return { thresholdRatio: ratio };
}

/** The client-facing view: the session's threshold, defaulting to 0.8 (80%). */
function viewThreshold(state) {
	return { thresholdRatio: state.thresholdRatio ?? 0.8 };
}

/**
 * Host half: expose the `/threshold <0.40-1.00>` command (per-session write)
 * and the `compactionThreshold` session projection (per-session read, pushed
 * to the browser). Both are session-scoped: each session's command history is
 * its own, the projection folds that session's log, and a session that never
 * set a value views the default 0.8.
 */
function apply(ctx) {
	ctx.inject(["commands"], (commandsCtx) => {
		commandsCtx.commands.register({
			name: COMMAND_NAME,
			description: "Set this session's context compaction trigger ratio (0.40-1.00)",
			input: { hint: "<0.40-1.00>" },
			handler: async ({ rawInput }) => {
				const ratio = parseThreshold(rawInput);
				if (ratio === void 0) {
					return { kind: "error", text: `usage: /${COMMAND_NAME} <0.40-1.00>` };
				}
				return {
					kind: "success",
					text: `compaction threshold for this session set to ${ratio.toFixed(2)}`
				};
			}
		});
	});

	ctx.inject(["sessionProjections"], (projectionCtx) => {
		projectionCtx.sessionProjections.register({
			key: "compactionThreshold",
			schema: ThresholdViewSchema,
			init: () => ({}),
			apply: foldThresholdEvent,
			view: viewThreshold,
			stateVersion: 1
		});
	});
}

export { COMMAND_NAME, ThresholdViewSchema, apply, foldThresholdEvent, inject, name, parseThreshold, viewThreshold };
export default apply;