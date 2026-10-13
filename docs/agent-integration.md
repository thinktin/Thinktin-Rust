# ThinkTin Agent 接入说明

> 更新日期：2026-10-13　｜　对应 WBS：6.7 清单、6.9 进程管理、6.10 ACP 客户端、6.11 配置注入、6.13 审批转发与事件上报、17.2 冒烟测试
>
> 依据《ThinkTin 平台架构方案 v3》第 3 节。接入顺序按要求：先 Claude（多种接入方式）和 Codex，再 Pi，最后 OpenClaw 和 Hermes。

## 1. 接入状态

五个 agent 都已接入，并用真实的 agent 程序跑通了冒烟测试：经 `agent-shim` 启动 agent，让它调用本地的模型网关替身，验证回复、工具调用、权限审批、会话接回，以及常驻模式下的取消（取消后 0.1 秒内结束这一轮，下一轮照常）。

| 顺序 | Agent | 锁定版本 | 接入方式 | 模型协议 | 会话接回 | 权限审批经平台 |
|---|---|---|---|---|---|---|
| 1 | Claude | claude-agent-acp 0.90.0（Claude Agent SDK 0.3.296） | `acp`：ACP 适配器（默认） | Anthropic Messages | `session/resume` | 是，工具调用都会征求 |
| 1 | Claude | Claude Code 2.1.296 | `cli`：命令行 stream-json | Anthropic Messages | `--resume` | 是，`can_use_tool` |
| 1 | Codex | codex-acp 2.2.2（Codex 0.160.1） | ACP | OpenAI Responses | `session/resume` | 是，只读模式下改文件、提权执行要审批 |
| 2 | Pi | pi 1.2.0 + pi-acp 0.0.34 | ACP | Chat Completions（默认）、Anthropic Messages、Responses* | `session/load` | 否，Pi 没有权限系统 |
| 3 | OpenClaw | 2026.10.3 | ACP 桥 + Gateway 辅助进程 | Chat Completions（默认）、Anthropic Messages*、Responses* | Gateway 会话键持久化 | 是，执行命令要审批 |
| 3 | Hermes | 0.19.0 | ACP | Chat Completions（默认）、Anthropic Messages* | `session/resume` | 部分，只有危险命令要审批 |

带 * 的协议配置生成器能写，但冒烟测试还没覆盖；其余组合都实测过。

**Claude 的多种接入方式**：同一个 Claude agent 在清单里有两个 harness。`acp` 走 Claude Agent SDK 的 ACP 适配器，功能最全（子 agent、计划、用量）；`cli` 直接驱动 Claude Code 命令行的 stream-json 模式，少一层 Node 适配器，也是 Claude Agent SDK 自己用的协议。用 `--harness cli` 切换，两者共用模型配置和状态目录。

## 2. 部署方式：全部自部署

五个 agent 都是由平台自己部署、在每个实例的沙箱里运行的程序（版本锁定在清单里，装进 Cube 模板），**不使用各家的云服务**：不登录 Claude、ChatGPT、ClawHub、Nous Portal 等账号，不调用 Claude Managed Agents、Codex Cloud 这类托管服务。agent 唯一需要的外部连接是平台自己的模型网关；网关再用用户自带的 key 去调模型（架构方案第 5 节），agent 拿不到任何厂商 key。

开源 agent 默认会在后台连各自的云（检查更新、同步插件市场、拉模型目录、遥测）。为确认这些都关掉了，用 strace 记录 agent 所有进程的 DNS 查询和网络连接（`EGRESS=1 tools/smoke/smoke.sh <agent>`），并把 agent 放进只有本机回环的断网网络命名空间里再跑一遍（`tools/smoke/offline.sh`）：

| Agent | 默认会连的外部地址（已关闭） | 关闭方式 | 审计结果 |
|---|---|---|---|
| Claude（两种方式） | 无 | 环境变量关自动更新和非必要外联 | 无外联；断网可用 |
| Codex | `github.com`、`chatgpt.com`（插件市场同步） | `features.plugins = false`，另关 `apps`（ChatGPT 连接器） | 无外联；断网可用 |
| Pi | 无 | `PI_OFFLINE`、`PI_SKIP_VERSION_CHECK` | 无外联；断网可用 |
| OpenClaw | `catalog.openclaw.ai`（模型目录）、`api.anthropic.com`、`clawhub.ai`（技能和插件市场） | `models.catalogRefresh`、`update.checkOnStart`、`telemetry` 关闭，`OPENCLAW_CLAWHUB_URL` 指向本机空端口 | 仍有一处：Gateway 启动约 90 秒后拉 ClawHub 插件目录（地址写死且有域名白名单，配置关不掉），只读元数据，不带数据；由沙箱出网策略拦截（2.7）。断网可用 |
| Hermes | 无（会探测网关是不是本地推理服务，只打网关地址） | — | 无外联；断网可用 |

所以沙箱的出网策略（WBS 2.7）按“默认拒绝、只放行模型网关”配置即可，agent 不依赖任何外部服务。

## 3. 结构

```
平台（编排服务）
   │  JSON Lines：ShimCommand ↓ / EventEnvelope ↑（crates/proto/src/shim.rs）
   ▼
agent-shim（沙箱里，crates/agent-shim）
   ├─ 配置注入：按清单生成 agent 的模型配置，base URL 指向模型网关
   ├─ 进程管理：环境变量白名单、独立进程组、崩溃按退避重启、Gateway 等辅助进程
   ├─ harness
   │    ├─ acp：JSON-RPC over stdio，initialize → session/new|resume|load → session/prompt
   │    └─ claude-stream-json：claude -p --input-format stream-json，initialize 控制请求握手
   └─ 预授权策略：范围内自动批准，范围外拒绝或交给用户
   │
   ▼
开源 agent ──（沙箱令牌）──▶ 模型网关 {gateway}/anthropic、{gateway}/openai/v1
```

- **清单**：`crates/catalog/manifests/*.toml`，由 `catalog` crate 解析和校验。校验包含平台规则：禁止自更新、禁止在线技能市场、辅助进程只能监听回环地址、清单不能设置 `THINKTIN_` 开头的变量、非开源许可证必须写说明。
- **平台协议**：`agent-shim serve` 从 stdin 读指令（`prompt`、`cancel`、`permission_decision`、`shutdown`），往 stdout 写带序号的事件（`ready`、`message_chunk`、`tool_call`、`permission_requested`、`turn_ended`、`agent_exited`、`session_lost` 等）。以后换成连编排服务的长连接，消息体不变。
- **ACP 的实现方式**：shim 只用到 ACP 的一小部分，所以直接手写 JSON-RPC，没有用官方 Rust SDK。发出去的请求按规范构造，收到的消息宽松解析：各家都有自己的扩展（`_meta`、未标准化的 `sessionUpdate`），认不出的原样透传为 `agent_update`，不会因为一个新字段断开。shim 不声明文件系统和终端能力，agent 用自己的工具在沙箱里干活。

## 4. 配置注入

沙箱令牌只放在环境变量 `THINKTIN_SANDBOX_TOKEN` 里。配置文件里只写变量名，所以每次唤醒轮换令牌都不用改文件，文件里也不会出现任何凭证。agent 的环境变量从空白开始，只放行 PATH、语言、代理、CA 证书这几类系统变量，shim 自己环境里的其他东西（比如别的凭证）不会漏给 agent。

| Agent | 生成的文件（相对 agent 的 HOME） | 关键环境变量 | 其他设置 |
|---|---|---|---|
| Claude | 无 | `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_MODEL`、`CLAUDE_CONFIG_DIR` | 关自动更新和非必要外联 |
| Codex | `.codex/config.toml`：自定义供应商 `thinktin`，`env_key = THINKTIN_SANDBOX_TOKEN`，`wire_api = "responses"`；`features.plugins = false`、`features.apps = false` | `CODEX_HOME`、`MODEL_PROVIDER`、`INITIAL_AGENT_MODE=read-only` | 关更新检查、插件市场（会连 GitHub 和 chatgpt.com）、ChatGPT 连接器 |
| Pi | `.pi/agent/models.json`、`.pi/agent/settings.json` | `PI_CODING_AGENT_DIR`、`PI_OFFLINE`、`PI_SKIP_VERSION_CHECK` | 关遥测 |
| OpenClaw | `.openclaw/openclaw.json`：Gateway 只监听回环、供应商 `thinktin`、`tools.exec.mode = ask`、`security.installPolicy.enabled = true`、`update.checkOnStart = false`、`models.catalogRefresh.enabled = false`、`telemetry.enabled = false` | `OPENCLAW_STATE_DIR`、`OPENCLAW_GATEWAY_TOKEN`（每次启动随机生成）、`OPENCLAW_CLAWHUB_URL` 指向本机空端口 | 关自动更新、版本检查、模型目录刷新、遥测、Bonjour、ClawHub |
| Hermes | `.hermes/config.yaml`（写成 JSON，YAML 兼容）：供应商 `custom`，`key_env = THINKTIN_SANDBOX_TOKEN` | `HERMES_HOME` | — |

模型别名用 `--model main:131072:8192` 的形式传入（上下文窗口、最大输出可省），第一个是默认模型，名为 `fast` 的别名给 Claude 的轻量任务用。网关按“令牌 → 实例 → 别名”查出真实的厂商和模型（架构方案 5.5）。

## 5. 权限审批

预授权范围按 ACP 的工具类别表达：`read`、`edit`、`delete`、`move`、`search`、`execute`、`think`、`fetch`、`switch_mode`、`other`，`*` 表示全部。范围内的请求 shim 直接选“只允许这一次”；范围外的按策略拒绝，或者发 `permission_requested` 等用户决定，默认最长等 24 小时（4.7）。工具类别是沙箱里的 agent 自己报告的，只表达用户意图；安全边界是 microVM。

各家的审批行为不一样，冒烟测试里确认过：

- **Claude**：命令行默认的权限模式不会来征求许可，shim 显式传 `--permission-mode default`。
- **Codex**：默认的 agent 模式让 Codex 自己用模型（`codex-auto-review`）审批，会绕过平台，还会额外调用一个别名。清单把它设成只读模式，改文件和提权执行都要征求许可。Codex 的拒绝选项叫 `cancel`，选中后整轮以 `cancelled` 结束，而不是让模型换个办法。
- **OpenClaw**：默认不审批（full）。配置里设 `tools.exec.mode = ask` 后，执行命令的审批经 ACP 转给平台。带 shell 重定向的命令 OpenClaw 无法安全绑定，会直接拒绝。
- **Hermes**：只有它判定为危险的命令（如 `rm -rf`）才审批，普通命令直接执行。
- **Pi**：没有权限系统，工具直接执行。

## 6. 会话接回

shim 把当前会话 id 记在 `~/.thinktin/shim-session.json`（工作区卷上）。agent 重启或沙箱唤醒后：

1. agent 声明 `sessionCapabilities.resume` 就用 `session/resume`，否则声明了 `loadSession` 就用 `session/load`。
2. 接回时 agent 重放的历史（Hermes 在 resume 时也会重放）直接丢弃，不算进新的一轮。
3. 接不回来就开新会话，上报 `session_lost`，由编排服务补发续跑简报（4.5）。

两个例外：

- **OpenClaw**：ACP 桥的会话 id 只在内存里，重启后接不回来。所以桥用 `--session agent:main:thinktin` 固定绑定到 Gateway 的一个会话键，历史由 Gateway 持久化。每次 `session/new` 都接着同一段对话，`ready` 里的 `session_restored` 为假，但上下文还在。
- **Claude 命令行**：新会话用 `--session-id` 指定 id，接回用 `--resume`。要接回的会话不存在时命令行会在握手前退出，shim 改开新会话。

## 7. 已知问题与后续工作

| 问题 | 影响 | 后续 |
|---|---|---|
| Claude Agent SDK 和 Claude Code 二进制是 Anthropic 专有软件（All rights reserved），只有适配器是 Apache-2.0 | 多租户托管前需要法务确认（我们是自部署运行它，不用 Anthropic 的服务） | 16.5 许可证审查 |
| Codex 的自定义供应商只支持 Responses 协议 | 模型网关要提供 `/openai/v1/responses`；只有 Chat Completions 的国内厂商要靠网关做协议转换 | 9.3、9.7 |
| Codex 不认识平台的模型别名，每轮开头输出一句 “Model metadata for `main` not found” 警告 | 用户会看到这句警告 | 生成 `model_catalog_json`，但条目必须带完整的系统提示词，需要在模板构建（6.8）时从 Codex 本身取 |
| Pi 没有权限系统 | 预授权策略管不到 Pi 的工具 | 只靠 microVM 隔离；计划里如果要求审批，就不能选 Pi |
| OpenClaw Gateway 冷启动约 20 秒，还会在工作目录写入 AGENTS.md、SOUL.md 等人设文件 | 唤醒慢；工作目录里多出文件 | 更适合停留在“已暂停”状态（4.10）；人设文件放进模板 |
| 辅助进程（OpenClaw Gateway）中途退出时 shim 不单独监控 | 桥会报错退出，之后按 agent 崩溃重启 | 6.9 增加辅助进程健康检查 |
| Hermes 会把网关地址记进会话（令牌每次从 `key_env` 取，不受影响），网关在回环或内网地址时还会不带凭证探测本地推理服务的接口 | 网关地址变了，旧会话还打旧地址；网关会收到一些无凭证的探测请求 | 沙箱里的网关地址保持固定（比如固定的内部域名）；网关对无凭证请求一律 401 |
| OpenClaw 启动约 90 秒后在后台拉 ClawHub 插件目录，配置关不掉 | 沙箱放行外网时会连 `clawhub.ai`（只读，不带数据） | 沙箱出网策略拦截（2.7） |
| 不支持按会话注入 MCP 的 agent（Pi、OpenClaw），平台工具还没写进它们自己的配置 | `thinktin.schedule` 等平台工具暂时只能注入 Claude、Codex、Hermes | 6.12 MCP 桥接 |
| 平台链路目前是 stdio JSON Lines | 还没接编排服务 | 3.2 协议定义、7.x 编排服务 |

## 8. 本地运行

```sh
cargo build -p agent-shim
cargo test --workspace            # 包含用假 ACP agent 驱动真实 shim 进程的集成测试

# 安装 agent（版本与清单一致；目录随意，把可执行文件放进 PATH）
npm i @agentclientprotocol/claude-agent-acp@0.90.0   # Claude（ACP）；Claude Code 二进制随 SDK 安装
npm i @agentclientprotocol/codex-acp@2.2.2           # Codex
npm i pi-acp@0.0.34 @earendil-works/pi-coding-agent@1.2.0
npm i openclaw@2026.10.3                             # 需要 Node 24.16 以上
pip install "hermes-agent[acp]==0.19.0"

# 冒烟测试：起模型网关替身，经 agent-shim 跑一轮，检查回复和网关日志
tools/smoke/smoke.sh claude
tools/smoke/smoke.sh claude --harness cli
tools/smoke/smoke.sh codex
PROMPT='MOCK_TOOL:Bash:{"command": "touch x", "description": "touch"}' EXPECT=MOCK_DONE \
  tools/smoke/smoke.sh claude --allow-tools execute     # 工具调用 + 预授权

# 自部署检查：记录 agent 所有进程的外联（需要 strace），以及在断网环境里跑（需要 root）
EGRESS=1 tools/smoke/smoke.sh openclaw
unshare -n tools/smoke/offline.sh env -u HTTPS_PROXY -u https_proxy tools/smoke/smoke.sh openclaw

# 常驻模式：正常一轮 → 慢的一轮中途取消 → 再来一轮
tools/smoke/serve_check.py codex

# 手动对接真实网关
THINKTIN_SANDBOX_TOKEN=... target/debug/agent-shim run --agent pi \
  --gateway https://llm-gw.example --model main:131072 --prompt "你好" --format text
```

`tools/mock-llm/mock_llm.py` 是模型网关的替身，提供 Anthropic Messages、Chat Completions 和 Responses 三种协议（流式和非流式），检查每个模型请求都带了沙箱令牌。提示词里写 `MOCK_TOOL:<工具名>:<JSON 参数>` 时，它会返回一次对该工具的调用，用来测工具循环和权限审批；写 `MOCK_SLOW` 时慢慢输出，用来测取消。
