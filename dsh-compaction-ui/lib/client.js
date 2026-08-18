window.__ModuleLoader__.load({
	id: "@my-scope/dsh-compaction-ui",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");

		//#region \0dsh-css:@my-scope/dsh-compaction-ui/ThresholdControl.module.css
		const css = ".cc-wrap{position:relative;flex:none}.cc-chip{height:28px;align-items:center;gap:4px;padding:0 8px;display:inline-flex;border:1px solid var(--dsw-alias-border-l2);border-radius:999px;background:var(--dsw-alias-bg-base);color:var(--dsw-alias-label-secondary);cursor:pointer;font-size:12px;line-height:20px}.cc-chip:hover{background:var(--dsw-alias-interactive-bg-hover);color:var(--dsw-alias-label-primary)}.cc-chip-open{border-color:var(--dsw-alias-state-business-primary)}.cc-chip-label{color:var(--dsw-alias-label-tertiary)}.cc-chip-value{font-weight:600;font-variant-numeric:tabular-nums}.cc-panel{position:absolute;right:0;bottom:calc(100% + 8px);width:280px;z-index:40;padding:12px;border:1px solid var(--dsw-alias-border-l1);border-radius:12px;background:var(--dsw-alias-bg-layer-2);box-shadow:var(--dsw-shadow-lv2);box-sizing:border-box}.cc-panel-title{color:var(--dsw-alias-label-primary);font-size:13px;font-weight:600;line-height:20px}.cc-panel-desc{margin-top:4px;color:var(--dsw-alias-label-secondary);font-size:12px;line-height:18px}.cc-row{margin-top:10px;align-items:center;justify-content:space-between;display:flex;color:var(--dsw-alias-label-secondary);font-size:12px;line-height:20px}.cc-row-value{color:var(--dsw-alias-label-primary);font-weight:600;font-variant-numeric:tabular-nums}.cc-range{width:100%;margin:6px 0 0;accent-color:var(--dsw-alias-state-business-primary)}.cc-saving{height:16px;line-height:16px;overflow:hidden;color:var(--dsw-alias-label-tertiary);font-size:11px}.cc-used{margin-top:8px;color:var(--dsw-alias-label-tertiary);font-size:11px;line-height:16px;font-variant-numeric:tabular-nums}.cc-used em{font-style:normal}";
		const tagId = "@my-scope/dsh-compaction-ui/ThresholdControl.module.css";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(tagId) + "]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "@my-scope/dsh-compaction-ui";
			tag.dataset.pluginCss = tagId;
			tag.textContent = css;
			document.head.appendChild(tag);
		}
		//#endregion

		//#region lib/types/client/index.js
		/** Dictionary namespace owned by this plugin. */
		const NS = "compactThreshold";
		/** Required services for the input-right slider and the settings scope. */
		const inject = ["slots", "locale", "settingsScope"];

		const zh = {
			"label": "压缩",
			"used": "已用",
			"threshold": "触发比例",
			"panel.title": "上下文压缩阈值",
			"panel.desc": "会话占用达到上下文窗口该比例时,自动压缩旧历史。",
			"unavailable": "设置未开放",
			"saving": "保存中…"
		};
		const en = {
			"label": "Compact",
			"used": "used",
			"threshold": "Trigger ratio",
			"panel.title": "Context compaction threshold",
			"panel.desc": "Auto-compact old history when the session reaches this ratio of the context window.",
			"unavailable": "Settings not exposed",
			"saving": "Saving…"
		};

		/** 1.2e5 -> "120K"; 1.2e6 -> "1.2M". */
		function formatTokens(value) {
			if (typeof value !== "number" || !Number.isFinite(value)) return "–";
			if (value >= 1000000) return (value / 1000000).toFixed(1).replace(/\.0$/, "") + "M";
			if (value >= 1000) return (value / 1000).toFixed(0) + "K";
			return String(value);
		}

		/**
		* ThresholdControl: a compact chip beside the ContextMeter ring. Click
		* opens a popover with a 0.4-1.0 range slider that writes the `compaction`
		* settings namespace live (debounced); the current context occupancy rides
		* the `contextPressure` projection alongside it.
		*/
		function ThresholdControl({ scope, t, useProjection }) {
			const [open, setOpen] = react.useState(false);
			const [draft, setDraft] = react.useState(null);
			const [saving, setSaving] = react.useState(false);
			const timer = react.useRef(null);
			const wrapRef = react.useRef(null);

			const snapshot = react.useSyncExternalStore(
				(listener) => scope.subscribe(listener),
				() => scope.getSnapshot()
			);
			const stored = snapshot && snapshot.value && typeof snapshot.value.thresholdRatio === "number"
				? snapshot.value.thresholdRatio
				: 0.8;
			const unavailable = snapshot ? snapshot.status === "unavailable" : false;

			const pressure = useProjection("contextPressure");
			const ratio = draft ?? stored;
			const percent = Math.max(0, Math.min(100, Math.round(ratio * 100)));

			const commit = (value) => {
				if (timer.current) {
					clearTimeout(timer.current);
					timer.current = null;
				}
				setSaving(true);
				scope.set("thresholdRatio", value).finally(() => setSaving(false));
			};
			const onChange = (event) => {
				const value = Number(event.target.value);
				setDraft(value);
				if (timer.current) clearTimeout(timer.current);
				timer.current = setTimeout(() => commit(value), 250);
			};
			const onRelease = () => {
				if (draft !== null) commit(draft);
			};

			react.useEffect(() => {
				if (!open) return;
				const onDown = (event) => {
					if (wrapRef.current && !wrapRef.current.contains(event.target)) setOpen(false);
				};
				document.addEventListener("pointerdown", onDown);
				return () => document.removeEventListener("pointerdown", onDown);
			}, [open]);

			react.useEffect(() => () => {
				if (timer.current) clearTimeout(timer.current);
			}, []);

			const onKeyDown = (event) => {
				if (event.key === "Escape") setOpen(false);
			};

			return react.createElement(
				"div",
				{ className: "cc-wrap", ref: wrapRef },
				react.createElement(
					"button",
					{
						type: "button",
						className: "cc-chip" + (open ? " cc-chip-open" : ""),
						onClick: () => {
							const next = !open;
							setOpen(next);
							if (!next) setDraft(null);
						},
						"aria-haspopup": "dialog",
						"aria-expanded": open,
						title: t("panel.title")
					},
					react.createElement("span", { className: "cc-chip-label" }, t("label")),
					react.createElement("span", { className: "cc-chip-value" }, percent + "%")
				),
				open && react.createElement(
					"div",
					{ className: "cc-panel", role: "dialog", onKeyDown },
					react.createElement("div", { className: "cc-panel-title" }, t("panel.title")),
					react.createElement("div", { className: "cc-panel-desc" }, t("panel.desc")),
					react.createElement(
						"label",
						{ className: "cc-row" },
						react.createElement("span", null, t("threshold")),
						react.createElement("span", { className: "cc-row-value" }, percent + "%")
					),
					react.createElement("input", {
						type: "range",
						className: "cc-range",
						min: 0.4,
						max: 1,
						step: 0.05,
						value: ratio,
						disabled: unavailable,
						onChange,
						onPointerUp: onRelease,
						onKeyUp: onRelease
					}),
					react.createElement("div", { className: "cc-saving" }, saving ? t("saving") : ""),
					react.createElement(
						"div",
						{ className: "cc-used" },
						t("used") + ": ~" + formatTokens(pressure ? pressure.projectedTokens ?? pressure.pressureTokens : undefined) + " / " + formatTokens(pressure ? pressure.contextWindow : undefined)
					)
				)
			);
		}

		/**
		* Client plugin body: the threshold chip in the composer tool row, right
		* before the send button (beside the ContextMeter ring).
		*/
		function apply(ctx) {
			ctx.effect(() => ctx.locale.register(NS, { zh, en }), "compaction-ui: dictionaries");
			const scope = ctx.settingsScope.bind({ namespace: "compaction" });
			ctx.slots.inject("conversation.input.right", () => ctx.slots.register({
				name: "conversation.input.right",
				id: "compact-threshold",
				order: 10,
				locale: NS,
				inject: () => ({ scope })
			}, ThresholdControl));
		}
		//#endregion

		exports.ThresholdControl = ThresholdControl;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

//# sourceMappingURL=client.js.map