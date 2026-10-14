# agent 加固基线（WBS 15.3）

沙箱里跑的是上游开源 agent，平台不改它们的代码，靠 agent-shim 每次启动时生成的配置把危险的能力关掉。
基线由 `crates/agent-shim/src/config.rs` 的 `every_builtin_agent_meets_the_hardening_baseline` 测试守住：
新接一个 agent 而没有登记它的加固项，测试会失败。

| 要求 | Claude（Agent SDK / Claude Code） | Codex | Pi | OpenClaw | Hermes |
|---|---|---|---|---|---|
| 不自更新、不查新版本 | `DISABLE_AUTOUPDATER=1` | `check_for_update_on_startup = false` | `PI_SKIP_VERSION_CHECK=1`、`PI_OFFLINE=1` | `update.checkOnStart = false`、`OPENCLAW_NO_AUTO_UPDATE=1` | 不在运行时下载 Node（`HERMES_SKIP_NODE_BOOTSTRAP=1`）；`hermes update` 只能手动执行 |
| 不发遥测、反馈 | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | `analytics`、`feedback` 关，`otel.metrics_exporter = "none"` | `PI_TELEMETRY=0` | `telemetry.enabled = false`、`CLAWHUB_DISABLE_TELEMETRY=1` | 没有网络遥测 |
| 关技能 / 插件市场 | — | `features.plugins = false`、`features.apps = false` | — | ClawHub 指向本机空端口；`security.installPolicy` 开启且不配审批命令，安装一律失败 | 技能内联命令不执行、agent 写的技能过安全扫描、不跑后台技能整理（`curator.enabled = false`） |
| 控制台只听回环 | 没有控制台 | 没有控制台 | 没有控制台 | Gateway `bind = "loopback"`，令牌每次启动随机生成 | 不启动仪表盘 |
| 模型只走平台网关 | 网关地址 + 沙箱令牌（环境变量） | 同左（`env_key`） | 同左（`$THINKTIN_SANDBOX_TOKEN`） | 同左 | 同左（`key_env`） |

另外两层不在 agent 配置里：

- **网络**：沙箱出网走白名单，模型流量只能到平台的模型网关（WBS 2.7，部署时配置）；即使 agent 想连技能市场、更新源也连不上。
- **模板**：模板构建时锁定上游版本，冒烟测试通过才上架（WBS 6.8）；升级、回滚由平台控制（WBS 6.7）。
