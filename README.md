# dsh-compaction-slider

DSH(DeepSeek Harness)上下文压缩阈值滑块插件 —— 在 web 输入栏的上下文使用量圆环旁提供实时滑块,拖动即可调整**当前会话**的自动压缩触发比例(`thresholdRatio`,范围 **0.4 ~ 1.0**,默认 **80%**)。

- **按会话独立**:每个会话有自己独立的阈值,切换会话、重启 dsh 均保留
- **即时生效**:调整后下一个 step 边界生效,无需改配置、无需重启
- **零侵入**:不修改任何 node_modules 内部文件,升级 dsh 无需重装

---

## 功能特性

- **实时滑块**:消息输入栏 ContextMeter 圆环(发送键左侧)旁新增「压缩 XX%」chip,点击弹出 0.4~1.0 滑动条
- **按会话持久化**:阈值随会话日志保存,切换会话/重启都不丢;每个会话默认 80%,互不影响
- **也支持命令行**:聊天里直接输入 `/threshold 0.65` 等效设置
- **完整压缩链路**:复用官方 `compaction-basic` 的总结/保留尾部/工具结果裁剪/溢出恢复逻辑,只替换触发比例来源
- **上下文占用同步显示**:弹窗内同时展示当前 `~已用 / 容量`
- **一键安装/卸载**:`install.ps1` 自动完成全部接线,带备份与幂等保护

## 前置要求

| 项目 | 要求 |
|---|---|
| Node.js | ≥ 22.19(LTS) |
| dsh | `@deepseek-ai/dsh` 0.1.0-rc.6(同版本安装:`npm install -g @deepseek-ai/dsh`) |
| 系统 | Windows PowerShell 5.1+(其他平台可手动安装,见下文) |
| 已运行过 | 至少启动过一次 `dsh web`(自动初始化 profile) |

## 快速开始(推荐)

```powershell
git clone https://github.com/nvnoa57-star/dsh-compaction-slider.git
cd dsh-compaction-slider
./install.ps1
```

脚本自动完成:安装插件包 → 注册 profile 插件行 → 安装 `auto-compact` 预设 → 设为默认预设。每次修改前自动备份到 `$DSH_HOME/install-backups/<时间戳>/`。

安装完成后**重启 dsh web**,新开会话即可看到滑块。

若提示执行策略限制,先执行:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

常用参数:

```powershell
./install.ps1               # 安装(幂等,可重复执行)
./install.ps1 -Force        # 预设已存在时覆盖
./install.ps1 -NoDefault    # 不修改默认预设(需自己在 UI 选择 auto-compact)
./install.ps1 -Uninstall    # 卸载(-Force 同时删除预设)
```

## 手动安装(不用脚本时)

1. **安装插件包**:把 `dsh-compaction-ui`、`dsh-compaction-live` 两个目录放入 `$DSH_HOME\profiles\node_modules\@my-scope\`(可拷贝或建 junction)
2. **注册插件行**:在 `$DSH_HOME\profiles\web\cordis.patch.yml` 追加:
   ```yaml
   - insert:
       - id: compaction-settings
         name: '@my-scope/dsh-compaction-ui'
   ```
3. **安装预设**:把 `presets\auto-compact` 复制到 `$DSH_HOME\.agent-presets\auto-compact`
4. **设为默认**:在 `$DSH_HOME\settings.yaml` 添加:
   ```yaml
   agent-presets:
     default: auto-compact
   ```
5. 重启 `dsh web`

> 无需修改任何 node_modules 内部文件。

## 使用说明

### 滑块在哪

打开 web 页面进入任意会话,消息输入栏 **发送按钮左侧**、ContextMeter 圆环(上下文占用环形指示器)**旁边**,有一个「压缩 XX%」的小 chip:

- 点击 chip → 弹出面板
- 面板内含 **0.4 ~ 1.0** 的滑动条(步长 0.05)、当前触发比例、上下文占用 `~已用/容量`
- 拖动松手即保存(拖动中有 250ms 防抖,保存时显示「保存中…」;失败会显示红色错误)

### 滑块值含义

| 值 | 含义 | 效果 |
|---|---|---|
| 0.4 | 会话占用达到模型上下文的 **40%** 即触发压缩 | 最激进,模型始终工作在窗口前半段,最不易「上下文腐化」;压缩频率最高 |
| 0.8 | 达到 **80%** 触发(默认) | 官方默认水平,保留较多原文 |
| 1.0 | 几乎不主动压缩 | 仅靠溢出恢复兜底,最保守 |

压缩触发时,系统把最早的对话总结为一段 checkpoint,仅保留最近 16% 的原文(保留尾部),之后请求使用压缩后的上下文。

### 生效时机

- **阈值本身**:拖动后对运行中会话在**下一个 step 边界**即时生效
- **压缩后端**:新会话生效(`auto-compact` 预设);安装前创建的旧会话仍使用旧预设,需新建会话

## 工作原理

```
浏览器滑块 ──commands.execute(sessionId, "/threshold 0.65")──▶ host /threshold 命令
                                                                │
                          会话日志追加 command/run 事件(官方已知事件,可重放)
                                                                │
        ┌───────────────────────────────────────────────────────┤
        ▼                                                       ▼
compactionThreshold 会话投影(折叠,默认0.8)          live 压缩后端每次检查逆向扫描日志
        │                                                       │
        ▼                                                       ▼
滑块回显(useProjection)                            重建 thresholdRatio → 官方压缩逻辑
```

- `dsh-compaction-ui`:host 半体注册 `/threshold` 命令与 `compactionThreshold` 投影;浏览器半体渲染滑块
- `dsh-compaction-live`:preset 平面压缩后端,按会话从日志读取最新阈值,其余逻辑 100% 复用官方引擎

详细设计见 [DESIGN.md](DESIGN.md)。

## 常见问题

**Q: 没有看到滑块?**
- 确认在**新开的会话**里(旧会话不加载新预设)
- 确认已重启 dsh web

**Q: 拖了滑块但感觉没变化?**
滑块改变的是触发**比例**,当会话占用还没到该比例时不会压缩。可观察弹窗中的 `~已用/容量` 判断距离阈值有多远。

**Q: 切换会话后阈值不一样?**
这是设计行为:阈值**按会话独立**,每个会话默认 80%,各自可单独调整。

**Q: 滑块显示红色「保存失败」?**
正常情况不会出现;若出现,请把错误文字反馈给插件作者。

**Q: 升级 dsh 后插件失效?**
本方案不修改 node_modules,一般无需重装;若 dsh 主版本变化导致 API 不兼容,请检查版本要求。

## 已知限制

- 滑块是**按会话**设置,非全局
- 聊天里 `/threshold` 命令输入的数值会被 clamp 到 0.4~1.0
- 包名使用占位 scope `@my-scope`,如需发布 npm 请换为真实 scope 并同步修改引用
- 压缩会使其后请求的 KV cache 前缀失效(官方压缩机制固有特性)

## 项目结构

```
dsh-compaction-slider/
├── install.ps1                  # 一键安装/卸载脚本
├── dsh-compaction-ui/           # 滑块插件(host 命令/投影 + 浏览器 UI)
│   ├── lib/index.js             #   host 半体:/threshold 命令 + compactionThreshold 投影
│   └── lib/client.js            #   浏览器半体:ThresholdControl 滑块组件
├── dsh-compaction-live/         # preset 压缩后端(按会话读日志)
│   └── lib/index.js             #   LiveCompactionEngine
├── presets/auto-compact/        # 推荐 agent 预设(使用 live 后端)
└── DESIGN.md                    # 完整设计文档
```

## License

MIT(未附带 LICENSE 文件,使用者自行决定)。
