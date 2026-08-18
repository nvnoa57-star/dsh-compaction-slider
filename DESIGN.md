# DSH 上下文压缩阈值滑块插件 — 设计文档

## 1. 目标

在 DSH web 客户端的「上下文使用额」显示区(ContextMeter 圆环,位于消息输入栏、发送键之前)旁边提供一个滑动条控件。拖动滑块实时调整 `dsh-compaction-basic` 的 `thresholdRatio`(自动压缩触发比例),范围 **0.4 ~ 1.0**。

滑块是全局设置(所有会话共用),调整后对正在运行的会话在下一个 step 边界即时生效,无需重启。

## 2. 背景事实(调研验证)

| 事实 | 依据 |
|---|---|
| 上下文使用额显示 = `ContextMeter`,点击弹出「上下文已用 X% / ~used / capacity」面板 | `@deepseek-ai/dsh-client-ui-conversation` 的 InputBar 尾部,数据来自 `contextPressure` / `contextBreakdown` 会话投影 |
| ContextMeter 所在「主按钮前工具行」正是 `conversation.input.right` slot | `dsh-client-ui-conversation/lib/types/client/contract/slots.d.ts` |
| `thresholdRatio` 当前**无法运行时修改**:构造时 `deepFreeze` 冻结,每次压力检查只读 `this.config` | `dsh-compaction-basic/lib/index.js:resolveConfig()` |
| web 版 compaction 后端在 agent preset 内,预设装了就冻结、会话加入后不重读 | `dsh-agent-presets` README「stamp 机制」 |
| 官方动态配置通道 = settings 命名空间(`dsh-llm-deepseek` 模式):host 注册 → 浏览器 `settings.mutate` 写入 → 消费方每次操作重读 | `dsh-settings` README + `dsh-llm-deepseek` lib |
| 浏览器访问 settings 受 apiproxy 放行名单限制,未放行返回 `settings-not-exposed` | `dsh-host-apiproxy/lib/index.js:888` `WEB_SETTINGS_NAMESPACES` |

## 3. 架构

```
浏览器                                      host 平面                              agent preset 平面
┌───────────────────────────┐      ┌──────────────────────────────┐      ┌─────────────────────────────┐
│ @my-scope/dsh-compaction-ui │      │ @my-scope/dsh-compaction-ui │      │ @my-scope/dsh-compaction-live│
│  客户端半体                  │      │  host 半体                   │      │  preset 后端                 │
│  conversation.input.right  │      │  ctx.settings.register(      │      │  LiveCompactionEngine        │
│  slot 里的阈值滑块 0.4~1.0  │──┐   │   "compaction",             │      │  每次 compactIfNeeded 重读   │
│  scope.set("thresholdRatio"│  │   │   {thresholdRatio:0.4~1})    │      │   settings.get("compaction") │
│  ,v)                       │  │   └────────────┬─────────────────┘      │   → this.config 重建后        │
└───────────────────────────┘  │                │                          │     调用 super 逻辑           │
                                │                │                          └─────────────────────────────┘
                                ▼                ▼
                     settings.mutate 经 apiproxy    消费方每次操作重读(参照 tokenMeter 跨 realm 读 host 服务)
                     放行名单(WEB_SETTINGS_NAMESPACES 含 "compaction")
```

三个组件,两个包:

### 包 1:`@my-scope/dsh-compaction-ui`(host 半体 + 客户端半体,单一行)

- **host 半体**(`lib/index.js`):注册 settings 命名空间 `compaction`,schema = `z.object({ thresholdRatio: z.number().min(0.4).max(1).default(0.8) })`,`base` = 入口配置。命名空间拥有者必须是 host 平面(preset 插件不能注册,会重复)。
- **客户端半体**(`lib/client.js`):`dsh.client.platform: "web"`,向 `conversation.input.right` slot 注入 `ThresholdControl`。读取 `contextPressure` 投影展示当前占用,读取/写入 `compaction` 命名空间。

### 包 2:`@my-scope/dsh-compaction-live`(preset 平面后端,替换 `compaction-basic`)

子类化 `BasicCompactionEngine`,重写 `compactIfNeeded`:

```js
class LiveCompactionEngine extends BasicCompactionEngine {
  constructor(ctx, config) { super(ctx, config); this.baseConfig = this.config; }
  async compactIfNeeded(agent, trigger, signal) {
    const live = this.ctx.get("settings")?.get("compaction")?.thresholdRatio;
    if (typeof live === "number") this.config = { ...this.baseConfig, thresholdRatio: live };
    return super.compactIfNeeded(agent, trigger, signal);
  }
}
```

要点:
- `this.config` 是公开字段、对象被冻结但字段可重新赋值;每次从 `baseConfig`(已解析冻结的默认配置)展开并覆盖 `thresholdRatio`,保留 `retainRatio` 等其余已解析值。
- 总结、保留尾部、工具结果裁剪、溢出恢复全部复用官方实现(`super.compactIfNeeded`)。
- 预设组 `compaction` 的 `isolate` realm 内读取 host 平面 `settings` 服务,与服务解析向上穿透的机制一致(同 `tokenMeter`)。

## 4. 数据流

1. 用户拖动滑块 → 客户端 `scope.set("thresholdRatio", v)`(防抖 300ms + 拖动中节流)。
2. `settings.mutate` 经 apiproxy(需放行名单含 `compaction`)写入 `$DSH_HOME/settings.yaml` 的 `compaction:` 段,带 revision 防并发冲突。
3. host 的 `settings` 命名空间解析更新(校验失败保留上一个好值并记日志)。
4. 下一个 `agent/pre-step` 压力检查:`LiveCompactionEngine.compactIfNeeded` 重读 `settings.get("compaction").thresholdRatio` → 重建 `this.config` → `super.compactIfNeeded` 使用新阈值决定是否压缩。
5. 压缩结果写回会话(surface replace),`contextPressure` 投影更新,UI 圆环同步。

## 5. 边界与约束

- **范围 0.4 ~ 1.0**:与默认 `retainRatio: 0.16` 恒满足 `retainRatio < thresholdRatio` 校验;滑块步长 0.05。
- `1.0` ≈ 接近不主动压缩(仅靠溢出恢复兜底);`0.4` 极激进(更早、更频繁压缩)。
- 命名空间放行需在 `dsh-host-apiproxy/lib/index.js` 的 `WEB_SETTINGS_NAMESPACES` 加入 `"compaction"`(全局 node_modules,升级会覆盖,需记录在部署脚本)。
- 换压缩后端需新会话或重启 `dsh web`;阈值本身对运行中会话即时生效。
- 滑块为全局设置,非按会话。

## 6. 文件清单

```
plugins/
  DESIGN.md                                   ← 本文档
  dsh-compaction-ui/
    package.json                              ← dsh.client 声明 + exports["./client"]
    lib/index.js                              ← host 半体:注册 settings 命名空间
    lib/client.js                             ← 浏览器半体:ThresholdControl + locale
  dsh-compaction-live/
    package.json
    lib/index.js                              ← LiveCompactionEngine
```

## 7. 接入步骤(部署)

1. 把两个包加入 web profile 依赖并安装(或建立 junction 到 profile/node_modules)。
2. `$DSH_HOME/profiles/web/cordis.patch.yml`:
   ```yaml
   - insert:
       - id: compaction-ui
         name: '@my-scope/dsh-compaction-ui'
       - id: compaction-live-host
         name: '@my-scope/dsh-compaction-live'   # 仅保证 host 解析可达;实际由 preset 引用
   ```
3. `dsh-host-apiproxy/lib/index.js` `WEB_SETTINGS_NAMESPACES` 加 `"compaction"`。
4. 复制 `standard` preset 为 `$DSH_HOME/.agent-presets/auto-compact/`,`compaction` 组内 `compaction-basic` → `@my-scope/dsh-compaction-live`;`settings.yaml` 设 `agent-presets.default: auto-compact`。
5. 重启 `dsh web`。