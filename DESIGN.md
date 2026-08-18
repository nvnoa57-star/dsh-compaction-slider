# DSH 上下文压缩阈值滑块插件 — 设计文档

## 1. 目标

在 DSH web 客户端的「上下文使用额」显示区(ContextMeter 圆环,位于消息输入栏、发送键之前)旁边提供一个滑动条控件。拖动滑块实时调整**当前会话**的 `thresholdRatio`(自动压缩触发比例),范围 **0.4 ~ 1.0**,**默认 80%**。

- **按会话独立**:每个会话有自己独立的阈值,互不影响
- **持久化**:阈值随会话日志保存,切换会话、重启 dsh 均保留
- **全局无状态**:不修改任何 node_modules 内部文件,升级 dsh 后无需重装

## 2. 背景事实(调研验证)

| 事实 | 依据 |
|---|---|
| 上下文使用额显示 = `ContextMeter`,点击弹出「上下文已用 X% / ~used / capacity」面板 | `@deepseek-ai/dsh-client-ui-conversation` 的 InputBar 尾部,数据来自 `contextPressure` / `contextBreakdown` 会话投影 |
| ContextMeter 所在「主按钮前工具行」正是 `conversation.input.right` slot | `dsh-client-ui-conversation/lib/types/client/contract/slots.d.ts` |
| **自定义 session 事件无法跨重启**:`KNOWN_SESSION_EVENT_TYPES` 是构建期生成目录,运行时无注册 API;`Session.append` 无法打 `ignorable: true` 标记 → 不能自造事件类型 | `dsh-session` lib + `dsh-session-persistence` `assertEventsSupported` |
| **`command/run` 是官方已知事件**,携带 `{name, args(原始输入)}`,且投影注册表(`ctx.sessionProjections`)可折叠任意已知事件 | `dsh-commands/lib/index.js:289-294`、`dsh-session` 目录 |
| **插件可注册命令** `/threshold`:`ctx.commands.register(...)`,浏览器经 `ctx.remote.commands.execute(sessionId, "/threshold 0.65")` 调用(typert 网关,无需改 apiproxy) | `dsh-commands/lib/index.js:242`、`dsh-api-gateway` |
| 浏览器访问点分服务必须显式注入完整键:`inject: ["remote", "remote.commands"]`,否则 cordis 抛 `cannot get property ... without inject` | 实测(曾踩坑) |
| 投影 schema 必须用 **zod**(`z.object`),投影注册表调用 `schema.parse()`;schemastery schema 无 `.parse` | `dsh-session-projection/lib/index.js:109`、实测 |

## 3. 架构

```
浏览器滑块 ──ctx.remote.commands.execute(sessionId, "/threshold 0.65")──▶ host
                │                                                     │
                │  (typert 网关,命令由 host 插件注册)                    │
                ▼                                                     ▼
        会话日志追加 command/run 事件 {name:"threshold", args:"0.65"}
                │                                                     │
                ▼                                                     ▼
   compactionThreshold 会话投影折叠(纯函数)               live 后端每次压力检查
   (key: command/run 最新值,默认 0.8)                     逆向扫描会话日志取最新值
                │                                                     │
                ▼                                                     ▼
   session/projection 帧推回浏览器(滑块回显)               重建 thresholdRatio 后调用官方压缩逻辑
```

### 三个组件

**包 1:`@my-scope/dsh-compaction-ui`(host 半体 + 客户端半体,单一行)**

- host 半体(`lib/index.js`):
  - 注册 `/threshold` 命令(`ctx.commands.register`):解析并 clamp 0.4~1.0,写入会话日志的是 `command/run` 事件本身
  - 注册 `compactionThreshold` 会话投影(`ctx.sessionProjections.register`):`apply` 折叠 `command/run`(name=threshold),`view` 输出 `{thresholdRatio: number}`(无记录时 0.8),schema 用 zod
- 客户端半体(`lib/client.js`):
  - `inject: ["slots", "locale", "remote", "remote.commands"]`
  - 向 `conversation.input.right` slot 注入 `ThresholdControl`:`useProjection("compactionThreshold")` 读当前会话值,拖动经 `commands.execute` 写入,`useProjection("contextPressure")` 显示占用

**包 2:`@my-scope/dsh-compaction-live`(preset 平面后端,替换 `compaction-basic`)**

子类化 `BasicCompactionEngine`,重写 `compactIfNeeded`:

```js
async compactIfNeeded(agent, trigger, signal) {
    const live = this.readLiveThreshold(agent);   // 逆向扫描 session.events 中
    if (live !== void 0) {                          // 最新的 /threshold command/run
        this.config = { ...this.baseConfig, thresholdRatio: live };
    }
    return super.compactIfNeeded(agent, trigger, signal);
}
```

要点:
- `this.config` 是公开字段、对象被冻结但字段可重新赋值;每次从 `baseConfig`(已解析冻结的默认配置)展开并覆盖 `thresholdRatio`
- 总结、保留尾部、工具结果裁剪、溢出恢复全部复用官方实现
- 纯解析函数 `parseThreshold` 由 ui 包导出、live 包复用,单点维护

## 4. 数据流

1. 用户拖动滑块 → 客户端防抖 250ms/松手时提交 → `ctx.remote.commands.execute(sessionId, "/threshold 0.65")`
2. typert 网关 → host `/threshold` 命令 handler 校验 clamp → `command/run` 会话事件入日志
3. 投影注册表驱动 `compactionThreshold` 折叠 → 变更推送 `session/projection` 帧 → 客户端 store 更新(更高 seq 胜出)→ 滑块回显
4. 下一个 `agent/pre-step` 压力检查:`LiveCompactionEngine.readLiveThreshold` 逆向扫描本会话日志取最新值 → 重建 `this.config` → `super.compactIfNeeded` 使用新阈值
5. 压缩结果写回会话(surface replace),`contextPressure` 投影更新,UI 圆环同步

## 5. 持久化与重建

- 阈值存储在**会话日志的 `command/run` 事件**里(官方已知事件类型,可重放)
- 会话重开/重启:`compactionThreshold` 投影从日志折叠重建;live 后端同样逆向扫描
- 未设置过阈值的会话:投影与后端均回落默认 **0.8**

## 6. 边界与约束

- 范围 **0.4 ~ 1.0**:与默认 `retainRatio: 0.16` 恒满足 `retainRatio < thresholdRatio` 校验;滑块步长 0.05
- `1.0` ≈ 接近不主动压缩(仅靠溢出恢复兜底);`0.4` 极激进
- 滑块为**按会话**设置;聊天输入 `/threshold 0.65` 等效
- 换压缩后端需新会话或重启 `dsh web`;阈值本身对运行中会话即时生效

## 7. 踩坑记录(实现教训)

1. **投影 schema 必须 zod**:schemastery schema 无 `.parse`,会导致所有会话历史加载失败(`schema.parse is not a function`)
2. **点分服务必须注入完整键**:`ctx.remote.commands` 需要 `inject` 里声明 `"remote.commands"`(仅 `"remote"` 不够),否则恒定抛错
3. **不能自定义 session 事件类型**:会破坏日志重载,必须复用官方已知事件(`command/run`)

## 8. 文件清单

```
plugins/
  DESIGN.md                                   ← 本文档
  dsh-compaction-ui/
    package.json                              ← dsh.client 声明 + exports["./client"]
    lib/index.js                              ← host 半体:/threshold 命令 + compactionThreshold 投影
    lib/client.js                             ← 浏览器半体:ThresholdControl 滑块组件
  dsh-compaction-live/
    package.json
    lib/index.js                              ← LiveCompactionEngine(按会话读日志)
```

## 9. 接入步骤(部署)

1. 复制两个包到 `$DSH_HOME/profiles/node_modules/@my-scope/`(或运行 `install.ps1`)
2. `$DSH_HOME/profiles/web/cordis.patch.yml`:
   ```yaml
   - insert:
       - id: compaction-settings
         name: '@my-scope/dsh-compaction-ui'
   ```
3. 复制 `presets/auto-compact` 到 `$DSH_HOME/.agent-presets/`,并设 `agent-presets.default: auto-compact`(settings.yaml)
4. 重启 `dsh web`。无需修改任何 node_modules 内部文件。
