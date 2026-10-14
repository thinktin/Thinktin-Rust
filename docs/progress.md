# 开发进度

> 按 [WBS](wbs.md) 推进，P1 优先、按依赖顺序。每个工作包做完：实现 → 测试 → fmt / clippy → 提交推送。
> 云端会话每 2 小时由定时任务唤醒一次，从这里接着做。

## 已完成

| WBS | 内容 | 位置 |
|---|---|---|
| 6.7（部分） | Agent 清单格式、校验、内置清单（Claude 两种接入、Codex、Pi、OpenClaw、Hermes） | `crates/catalog` |
| 6.9、6.10、6.11、6.13 | agent-shim：进程管理、ACP 客户端、Claude Code stream-json、配置注入、审批转发、事件上报 | `crates/agent-shim` |
| 17.2 | 真实 agent 冒烟测试集（工具调用、审批、会话接回、取消、出网审计、断网运行） | `tools/smoke` |
| 9.1 | 密钥库：按用户 DEK 的信封加密 | `crates/keyvault` |
| 4.4 | 沙箱令牌 | `crates/auth/src/sandbox_token.rs` |
| 9.2–9.7 | 模型网关：鉴权路由、流式透传、计量、限额熔断、SSRF 防护、厂商适配表；安全审查及修复 | `crates/llm-gw`、[文档](llm-gateway.md) |
| 6.1、6.3 | 沙箱抽象（按 E2B 接口）、本地开发后端 | `crates/sandbox` |
| 6.12 | 平台工具桥：MCP 注入、调用归属当前一轮；Claude（两种接入）、Codex、Hermes 实测通过 | `crates/agent-shim/src/bridge.rs`、[接入说明第 5 节](agent-integration.md) |
| 7.1、7.2、7.6（计算部分） | 触发时间计算：cron / RRULE / 一次性、时区和夏令时、确定性抖动、补跑策略 | `crates/orchestrator/src/schedule.rs` |
| 4.1、4.2（密码学部分） | 签名令牌通用格式、访问令牌、手机号规范化、验证码、刷新令牌 | `crates/auth` |
| 10.1 | 推送通道接口、APNs | `crates/notify` |
| 3.1、3.2 | 领域类型（实例、计划、触发器、运行状态机、审批、事件、授权范围）；接口版本协商与错误模型 | `crates/proto/src/domain.rs`、`api.rs` |
| 3.3、3.4 | 数据模型与迁移（RLS、复合外键防跨用户引用、事件按月分区）；按角色开启的事务和各表仓储（运行领取、租约、接管、出箱、审计） | `crates/store` |
| 3.5 | 主程序组装：配置加载、健康 / 就绪检查、版本接口、优雅停机、后台任务管理 | `crates/server` |
| 4.1、4.2 | 手机号验证码登录（按手机号限频、尝试次数上限、发送通道可替换）、设备会话（刷新令牌轮换、旧令牌重用即吊销整个会话）、退出登录只下线本设备、远程下线、冻结、注销即销毁 | `crates/auth/src/service.rs`、`sms.rs` |
| 6.4 | 实例生命周期：领养（锁定模板版本）、唤醒（按需建沙箱、恢复暂停、沙箱丢失时从模板重建）、暂停、归档、重建（升级 / 回滚）、删除后回收；空闲巡检（有运行在执行时不动、近期有计划触发的不归档） | `crates/control` |
| 7.2、7.6 | 调度循环：多副本扫描到点触发器、补跑策略（只补一次 / 全部 / 跳过）、确定性削峰抖动、规则失效的触发器停用并审计 | `crates/orchestrator/src/scheduler.rs` |
| 7.3、7.4、7.7、7.9 | 执行器：领取（租约）→ 唤醒沙箱 → 换沙箱令牌 → 在沙箱里启动 agent-shim → 交任务 → 事件写运行日志（文字流合并）→ 审批转给用户 → 续租（发现取消、被接管）→ 预算（时长、步数、以网关计费为准的 token）→ 成功 / 失败 / 退避重试；停机时交给别的副本续跑 | `crates/orchestrator/src/executor.rs`、`exec.rs` |
| 7.5 | 出箱投递：按设备推送通道发送、失效令牌清理、指数退避、过期丢弃 | `crates/orchestrator/src/outbox.rs` |
| 3.5（续） | 主程序带后台任务：调度、执行、投递、实例巡检、事件分区和验证码维护；`[worker]`、`[sandbox]`、`[push.apns]` 配置 | `crates/server/src/workers.rs` |
| 5.1、5.2、5.3、9.8 | 接入网关：账号、设备、agent 目录、实例、模型别名、运行、计划与触发器（规则校验、计划授权）、审批、模型 key（按用户 DEK 加密、只显示后 4 位、审计）；实例事件流（WebSocket 补发 + 实时、Postgres 通知唤醒、过期位置 reset、心跳重新核对会话）；REST 分页补发 | `crates/gateway`、[server 的 `[api]` 配置](../README.md) |
| 7.8 | 平台工具 thinktin.schedule：agent 查看、新建、修改、取消计划（新建和修改要用户在 App 里确认后生效；只能动自己实例的计划；计划授权不超过发起调用的运行） | `crates/orchestrator/src/tools.rs` |
| 8.1 | 团队与团队模板：成员（一个负责人）、从现有团队生成模板、按模板一键领养整个团队 | `crates/store/src/teams.rs`、`crates/gateway/src/routes/teams.rs` |
| 8.2 | 运行树：父子运行、流水线根运行等待子任务（`waiting_children`）、整树停止（`POST /v1/runs/{id}/cancel?tree=true`） | `crates/store/src/runs.rs` |
| 8.3 | 流水线（DAG）执行：计划带步骤时触发成流水线根运行；依赖满足的步骤并行启动（每步按步骤实例签发收窄的子授权）；一步失败停掉其余步骤、根运行失败并通知 | `crates/orchestrator/src/pipeline.rs`、`crates/store/migrations/0002_collaboration.sql` |
| 8.4 | 产出物服务：按用户 DEK 加密后存对象存储（本地目录后端）、同名再发布是新版本、按运行树 / 实例索引；平台工具 thinktin.artifacts（发布、列出、读取、取到工作区）；下载接口按附件返回 | `crates/orchestrator/src/artifacts.rs`、`tools.rs`、`crates/gateway/src/routes/artifacts.rs` |
| 8.5 | 交接说明：下游步骤的任务里附上游摘要和产出物清单，启动前把上游产出物复制到下游工作区 `handoff/` | `crates/orchestrator/src/pipeline.rs`（`handoff_prompt`、`HandoffCopier`） |
| 10.3 | 国内 Android 推送：经极光推送 REST v3 覆盖华为、荣耀、小米、OPPO、vivo 厂商通道（设备推送通道 `unipush`、令牌是 registration_id）；按系统消息发，只带 id；各厂商消息分类参数可配置；失效令牌、限频、配额、鉴权错误分别处理；`[push.jpush]` 配置 | `crates/notify/src/jpush.rs` |
| 10.4 | 收件箱：每条通知（运行结果、审批、计划确认）和推送在同一个事务里写进收件箱，按去重键只记一条；推送带收件箱 id；审批处理完自动已读；流水线步骤不单独通知；接口分页、未读数、按 id 或“到某条为止”标已读、标未读、删除 | `crates/store/src/inbox.rs`、`crates/orchestrator/src/outbox.rs`（`Notice`）、`crates/gateway/src/routes/inbox.rs` |
| 9.2–9.5（接库） | 模型网关接控制面数据库：`serve --database-url` 用 `thinktin_llmgw` 角色读实例、路由、凭证密文、用户包裹 DEK、授权状态（短时缓存，沙箱对不上时重读）；用量批量写进用量表（带运行授权，执行器按它算预算）；按 key 每日预算以用量表汇总为准（多副本共享） | `crates/llm-gw/src/pg.rs`、`crates/store/src/llmgw.rs` |
| 17.1 | 端到端测试：真实控制面（接口 + 后台任务）+ 本地沙箱 + agent-shim + 按 Pi 方式配置的假 agent + 接数据库的模型网关 + 模拟厂商，用 client-core 走完登录、存 key、领养、配别名、下任务、事件流、用量、收件箱；执行器把实例的模型别名（按授权收窄）交给 agent | `crates/e2e/tests/main_chain.rs` |
| 15.2 | 租户隔离测试：RLS 覆盖检查（新表忘了开会失败）、36 个跨用户访问用例、模型网关的跨用户 / 换沙箱 / 吊销 / 收窄授权（网关现在按授权的别名范围放行） | [审计记录](security-audit.md) |
| 15.4 | 密钥与日志审计：key 流转路径、主链路上自动检查 key 不进沙箱和日志、令牌不落盘；含密钥的结构调试输出全部打码；已知残留 | [审计记录](security-audit.md) |
| 11.1 | UniFFI 工程：client-core 出 Swift（`ThinktinCore`）/ Kotlin（`cn.thinktin.core`）绑定；xcframework + Swift Package、Android 库工程 / AAR 打包脚本（`mobile` 编译配置、16 KB 页对齐）；经 C ABI 的冒烟测试 | `crates/client-core/src/ffi.rs`、`tools/client-core/` |
| 11.2 | 接口客户端：版本头、统一错误模型（按错误码区分重新登录 / 重试 / 提示）、访问令牌过期自动刷新（并发只刷一次）、刷新令牌失效清会话；会话交给原生端的安全存储 | `crates/client-core/src/api.rs` |
| 11.3 | 事件流：WebSocket 按序号续传、去重、指数退避加抖动重连、空闲超时、握手 401 / 4001 关闭时刷新令牌再连、会话失效或实例不存在时停止 | `crates/client-core/src/events.rs` |
| 11.4 | 本地缓存：SQLite 存实例、运行、事件（续传位置）、收件箱；离线标已读先记本地、联网补发；缓存按用户隔离，退出登录清空 | `crates/client-core/src/cache.rs`、`client.rs` |
| 4.3、4.4（换取） | 运行授权：签发、范围只能收窄的子授权、连带吊销、有活动自动续期；退出登录不影响；用授权换绑定沙箱的令牌 | `crates/auth/src/grants.rs` |

## 进行中

见下方“里程碑”。

## 里程碑（后端核心，P1）

| 里程碑 | WBS | 内容 | 状态 |
|---|---|---|---|
| M1 基础 | 3.1、3.2、3.3、3.4、3.5 | 领域类型、协议版本；Postgres 表结构与迁移、带 TenantCtx 的仓储和 RLS；server 组装、配置、健康检查、优雅停机 | 完成 |
| M2 身份与授权 | 4.1、4.2、4.3 | 手机号登录（验证码发送可替换）、设备会话（访问令牌 + 按设备的刷新令牌）、运行授权（签发、续期、吊销、范围）；接上沙箱令牌 | 完成（访问令牌每次请求查库核对会话，M5 加缓存） |
| M3 执行面 | 6.1、6.3、6.4 | 沙箱抽象（按 E2B 接口）、本地开发后端、实例生命周期 | 完成（6.2 Cube 后端待 2.3 部署） |
| M4 编排 | 7.1–7.7、7.9 | 计划与触发器（cron / RRULE / 一次性，带时区）、调度循环、运行状态机、执行租约、出箱、补跑、预算护栏、运行日志 | 完成（端到端测试：计划到点 → 真实 agent-shim → 结果与通知；Redis 热数据待 M5 事件流） |
| M5 接入网关 | 5.1–5.3、9.8 | REST 接口、WebSocket 事件流、按序号续传；key 管理接口 | 完成（会话核对每次查库、热数据走 Postgres 通知；需要时加缓存 / Redis；短信通道待选型） |
| M6 平台工具与协同 | 6.12、7.8、8.1–8.5 | MCP 桥接、thinktin.schedule、团队、运行树、流水线、产出物、交接说明 | 完成（对象存储先做本地目录后端，S3 / OSS 后端随部署补） |
| M7 通知 | 10.1、10.3、10.4 | 收件箱、APNs、国内厂商推送（接口 + 统一推送服务适配） | 完成（国内推送先走极光，见待决问题 5；厂商直连按需补） |
| M8 客户端核心 | 11.1–11.4 | UniFFI、接口客户端、事件流续传、本地缓存 | 完成（打包脚本需要在 macOS / 装了 NDK 的机器上实跑验证） |
| M9 端到端 | 17.1、15.2、15.4、16.3 | 本地沙箱 + 模拟厂商跑通主链路；租户隔离测试；密钥与日志审计；AI 生成内容标识 | 待开始 |

## 待决问题（需要用户拍板，未拍板前按括号里的默认做）

1. **Claude 是否只上海外站、只接受 Anthropic 系凭证？** Anthropic 的地区政策点名 Claude Code，不支持中国大陆、香港、澳门；托管条款要求不限制它自带的登录方式、每个用户用自己的 Anthropic 或云厂商凭证。（默认：清单暂不改动，上线前必须定；建议只上海外站并找 Anthropic 书面确认。见 [接入说明 2.1 节](agent-integration.md)）
2. **国内站要不要补接 Qwen Code、Kimi Code CLI 这类开源 agent 替代 Claude Code？**（默认：暂不接，先做后端核心）
3. **agent 通过 thinktin.schedule 新建或修改的计划，要不要用户确认才生效？**（默认：要。计划会在没人看着时用用户的 key 反复运行，agent 可能被网页、邮件里的内容诱导；新建、修改后先暂停并推送提醒，用户在 App 里点确认（恢复）才生效；取消不需要确认）
4. 架构方案第 14 节的待决问题。（默认按方案里的建议：运行授权 90 天、有活动自动续期；审批超时 24 小时后暂停计划；多 agent 协同先做流水线，委派放 P2）
5. **国内 Android 推送用哪家？自接各厂商还是统一推送服务？**（默认：先接极光推送，一个接口覆盖华为、荣耀、小米、OPPO、vivo，App 集成极光 SDK 和厂商插件；按“系统消息”发，各厂商的消息分类要在厂商后台申请后填进 `[push.jpush.vendors]`。换个推或厂商直连只需要再实现一个推送通道。上线前要确认：极光的商用条款和费用、隐私政策里披露第三方推送 SDK）
