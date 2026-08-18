import z from "@deepseek-ai/schemastery";
import { settingsNamespace } from "@deepseek-ai/dsh-settings";

/** Settings namespace owning the live compaction policy defaults. */
const NS = settingsNamespace("compaction");

/** Plugin identity for the host composition row. */
const name = "compaction-settings";

/** Wait for the host settings service before registering the namespace. */
const inject = ["settings"];

/**
 * Live compaction policy section. `thresholdRatio` is the only field the
 * browser slider edits; other compaction policy stays in the preset row.
 */
const Config = z.object({
  thresholdRatio: z.number().step(0.05).min(0.4).max(1).default(0.8)
});

/**
 * Host half: register the `compaction` settings namespace so the browser
 * can read/write it. The namespace owner must be host-plane — a preset-mounted
 * plugin would register once per session and collide.
 */
function apply(ctx, config) {
  ctx.inject(["settings"], (sctx) => {
    sctx.settings.register(NS, Config, { base: config ?? {} });
  });
}

export { NS, Config, apply, inject, name };
export default apply;