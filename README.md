# dsh-compaction-slider

DSH(DeepSeek Harness)上下文压缩阈值滑块插件 —— 在 web 输入栏的上下文使用量圆环旁提供实时滑块,拖动即可调整自动压缩的触发比例(`thresholdRatio`,范围 **0.4 ~ 1.0**),无需改配置、无需重启,下一个 step 边界即生效。

适用于想让长会话「永远不撞上下文上限」、同时不想牺牲模型工作能力的场景:滑块值越小压缩越激进(更早压缩旧历史),越大越保守(保留更多原文)。

---

## 功能特性

- **实时滑块**:消息输入栏 ContextMeter 圆环(发送键左侧)旁新增「压缩 XX%」chip,点击弹出 0.4~1.0 滑动条
- **全局生效**:一次拖动,所有会话共用;对运行中的会话在下一个 step 边界即时生效
- **持久化**:滑块值写入 `$DSH_HOME/settings.yaml`,重启不丢失
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

脚本自动完成:安装插件包 → 注册 profile 插件行 → 放行 settings 命名空间 → 安装 `auto-compact` 预设 → 设为默认预设。每次修改前自动备份到 `$DSH_HOME/install-backups/<时间戳>/`。

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
./install.ps1 -SkipApiProxy # 跳过 apiproxy 放行(仅当你的 dsh 版本已原生放行时)
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
3. **放行 settings 命名空间**:编辑 dsh 安装目录下 `dsh-host-apiproxy\lib\index.js`,在 `WEB_SETTINGS_NAMESPACES` 数组中加一行 `"compaction",`(全局 npm 安装路径,如 `%APPDATA%\npm\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-host-apiproxy\lib\index.js`)
4. **安装预设**:把 `presets\auto-compact` 复制到 `$DSH_HOME\.agent-presets\auto-compact`
5. **设为默认**:在 `$DSH_HOME\settings.yaml` 添加:
   ```yaml
   agent-presets:
     default: auto-compact
   ```
6. 重启 `dsh web`

## 使用说明

### 滑块在哪

打开 web 页面进入任意会话,消息输入栏 **发送按钮左侧**、ContextMeter 圆环(上下文占用环形指示器)**旁边**,有一个「压缩 XX%」的小 chip:

- 点击 chip → 弹出面板
- 面板内含 **0.4 ~ 1.0** 的滑动条(步长 0.05)、当前触发比例、上下文占用 `~已用/容量`
- 拖动松手即保存(拖动中有 250ms 防抖,保存时显示「保存中…」)

### 滑块值含义

| 值 | 含义 | 效果 |
|---|---|---|
| 0.4 | 会话占用达到模型上下文的 **40%** 即触发压缩 | 最激进,模型始终工作在窗口前半段,最不易「上下文腐化」;压缩频率最高 |
| 0.8 | 达到 **80%** 触发(官方默认) | 保留最多原文,但接近上限时模型可靠性下降 |
| 1.0 | 几乎不主动压缩 | 仅靠溢出恢复兜底,最保守 |

压缩触发时,系统把最早的对话总结为一段 checkpoint,仅保留最近 16% 的原文(保留尾部),之后请求使用压缩后的上下文。

### 生效时机

- **阈值本身**:拖动后对运行中会话在**下一个 step 边界**即时生效
- **压缩后端**:新会话生效(`auto-compact` 预设);安装前创建的旧会话仍使用旧预设,需新建会话

## 工作原理

```
浏览器滑块 ──settings.mutate──▶ $DSH_HOME/settings.yaml
                                   │ compaction.thresholdRatio
                                   ▼
agent 预设中的 dsh-compaction-live(子类化官方 BasicCompactionEngine)
  每次 agent/pre-step 压力检查都重读 settings 中的 thresholdRatio
  重建阈值后调用官方压缩逻辑(总结 / 保留尾部 / 工具结果裁剪 / 溢出恢复)
```

- `dsh-compaction-ui`:host 半体注册 `compaction` settings 命名空间;浏览器半体渲染滑块
- `dsh-compaction-live`:preset 平面压缩后端,实时读取滑块值,其余逻辑 100% 复用官方引擎

详细设计见 [DESIGN.md](DESIGN.md)。

## 常见问题

**Q: 没有看到滑块?**
- 确认在**新开的会话**里(旧会话不加载新预设)
- 确认已重启 dsh web
- 确认 `WEB_SETTINGS_NAMESPACES` 已包含 `compaction`(重跑 install.ps1)

**Q: 滑块显示「设置未开放」/ 拖动无效?**
apiproxy 放行名单被覆盖(dsh 升级后常见),重跑 `./install.ps1` 即可。

**Q: 拖了滑块但感觉没变化?**
滑块改变的是触发**比例**,当会话占用还没到该比例时不会压缩。可观察弹窗中的 `~已用/容量` 判断距离阈值有多远。

**Q: 升级 dsh 后插件失效?**
`npm update` 会覆盖 apiproxy 放行与 preset,重跑 `./install.ps1` 修复;若 dsh 主版本变化,请先确认 API 兼容(见 DESIGN.md)。

## 已知限制

- 滑块是**全局设置**(所有会话共用),非按会话
- `npm update` 会覆盖 apiproxy 放行,需重跑安装脚本
- 包名使用占位 scope `@my-scope`,如需发布 npm 请换为真实 scope 并同步修改引用
- 压缩会使其后请求的 KV cache 前缀失效(官方压缩机制固有特性)

## 项目结构

```
dsh-compaction-slider/
├── install.ps1                  # 一键安装/卸载脚本
├── dsh-compaction-ui/           # 滑块插件(host settings 注册 + 浏览器 UI)
│   ├── lib/index.js             #   host 半体:注册 compaction 命名空间
│   └── lib/client.js            #   浏览器半体:ThresholdControl 滑块组件
├── dsh-compaction-live/         # preset 压缩后端(实时读阈值)
│   └── lib/index.js             #   LiveCompactionEngine
├── presets/auto-compact/        # 推荐 agent 预设(使用 live 后端)
└── DESIGN.md                    # 完整设计文档
```

## License

MIT(未附带 LICENSE 文件,使用者自行决定)。
