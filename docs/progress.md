# 开发进度

> 按 [WBS](wbs.md) 推进，P1 优先、按依赖顺序。开发分支是 `backend-core`：实现 → 测试 → fmt / clippy → 提交推送（每次推送 CI 都跑）。做的过程中随时推送，不让代码只留在会话的沙箱里。合进 `main` 走 PR，由人审过再合并。
> 会话中断后由看门狗定时任务接着做（每 2 小时检查一次，`backend-core` 超过 2 小时没有新提交就开新会话按这里继续），进度以这里为准。

## 已完成

| WBS | 内容 | 位置 |
|---|---|---|
| 6.7 | Agent 清单格式、校验、内置清单（Claude 两种接入、Codex、Pi、OpenClaw、Hermes）；版本锁定（实例锁在领养时的版本）、旧版本保留（换新版时旧清单进 `manifests/archive`）、升级与回滚（`POST /v1/instances/{id}/version`，下次唤醒按新版本重建沙箱，工作区保留） | `crates/catalog`、`crates/control` |
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
| 2.1（Rust 部分） | CI：格式、clippy、全部测试（Postgres 服务容器，`THINKTIN_REQUIRE_DB=1` 保证集成测试真跑）、客户端核心绑定冒烟；手动触发的 xcframework / Android 库打包 | `.github/workflows/` |
| 2.8（Rust 部分） | 可观测性：每次运行的日志挂在 `run` span 下（运行、实例、第几次）；Prometheus 指标（接口按路由模板的请求数和耗时、运行结果和耗时、计划触发数、推送结果；模型网关的请求、计费 token、拒绝原因），在单独的内网端口提供（`[observability] metrics_listen`、`llm-gw serve --metrics-listen`）；密钥打码见审计记录 | `crates/server/src/observability.rs` |
| 15.3 | agent 加固基线：每个内置 agent 关自更新、遥测、技能 / 插件市场，控制台只听回环（Hermes 新增：不在运行时装 Node、技能内联命令不执行、不跑后台技能整理，真实 Hermes 冒烟通过）；测试逐个守住，新接 agent 不登记会失败 | [基线](agent-hardening.md) |
| 17.1 | 端到端测试：真实控制面（接口 + 后台任务）+ 本地沙箱 + agent-shim + 按 Pi 方式配置的假 agent + 接数据库的模型网关 + 模拟厂商，用 client-core 走完登录、存 key、领养、配别名、下任务、事件流、用量、收件箱；执行器把实例的模型别名（按授权收窄）交给 agent | `crates/e2e/tests/main_chain.rs` |
| 15.1 | 威胁建模：资产、信任边界，按沙箱里的 agent、多 agent 协同、客户端与接入网关、模型网关、数据存储、调度执行、推送逐项列出威胁、已落地对策（指向代码和测试）和剩余风险；上线前待办排序 | [威胁模型](threat-model.md) |
| 15.2 | 租户隔离测试：RLS 覆盖检查（新表忘了开会失败）、36 个跨用户访问用例、模型网关的跨用户 / 换沙箱 / 吊销 / 收窄授权（网关现在按授权的别名范围放行） | [审计记录](security-audit.md) |
| 15.4 | 密钥与日志审计：key 流转路径、主链路上自动检查 key 不进沙箱和日志、令牌不落盘；含密钥的结构调试输出全部打码；已知残留 | [审计记录](security-audit.md) |
| 16.4（技术部分） | 注销即销毁：除了销毁 DEK，还删除提示词、摘要、事件、收件箱、计划、审批、团队、产出物索引、推送记录（含已送达的），产出物密文排队从对象存储删除，手机号和设备信息去标识化；先锁用户行，和并发写入互斥；逐表测试 | [说明](compliance.md#5-注销wbs-164-的技术部分) |
| 16.3 | AI 生成内容标识：agent 生成的事件、收件箱条目带标识位；系统通知正文加“【AI 生成】”；下载产出物带元数据头（隐式标识），纯文本和 Markdown 末尾加显式标识；推送文字的内容过滤（命中换成中性提示）；`[compliance]` 配置 | [说明](compliance.md) |
| 9.9 | 降级链：每个别名按顺序最多 3 个备用 key + 上游模型；401/402/403/429/503/529 或连不上时在交给 agent 之前换下一个，超时不换（避免重复扣费）；失败的 key 按 Retry-After 冷却、排到最后；每次尝试各记用量；停用、超预算、不支持协议的 key 直接跳过 | [说明](llm-gateway.md#降级链99) |
| 9.10 | 用量看板数据：`GET /v1/usage` 按天（用户时区）、实例、模型、key 汇总请求数、各类 token、估算和失败次数，附总计；client-core 的 `usage()` | `crates/gateway/src/routes/usage.rs`、`crates/store/src/usage.rs` |
| 9.12 | 主流模型品牌预置：新增 Anthropic、OpenAI、Google Gemini、xAI、Mistral、火山方舟、BytePlus、百度千帆、腾讯混元 TokenHub（国内、新加坡）、阶跃星辰，逐家按官方文档核对（腾讯原混元 API 已于 2026-09-30 停服，改走 TokenHub）；适配表挪到 `proto`，模型网关和接入网关共用；`GET /v1/vendors` 和 client-core 的 `vendors()` 给 App 列出可选厂商；保存 key 时只收预置厂商或 `custom`，按前缀拒绝订阅类 key（新增腾讯 Token Plan、Claude 订阅 OAuth 令牌），自定义端点填了套餐专用地址也拒绝 | `crates/proto/src/vendors.rs`、`crates/gateway/src/routes/vendors.rs`、[模型网关文档第 11 节](llm-gateway.md) |
| 6.2 | Cube 沙箱后端：按 CubeSandbox 的 E2B 兼容接口实现沙箱的创建、查询、暂停、恢复（`connect`）、快照、从快照恢复、销毁、工作区卷；进程走 envd 的 Connect 协议（输出流转管道、标准输入转发、SIGKILL），文件走 envd 的 `/files`；数据面可经 CubeProxy 按 Host 头路由；默认拒绝出网只放行白名单、数据面要带 envd 和流量令牌；控制服务重启后重新取令牌；`[sandbox.cube]` 配置。模拟服务测试通过，真实集群联调待 2.3 | `crates/sandbox/src/cube.rs`、[说明](sandbox-cube.md) |
| 5.4 | 限流与防刷：已登录请求按设备、按用户的令牌桶（默认每分钟 600、1200 次）；未登录接口（发码、登录、刷新令牌）按来源地址限频，发验证码按来源地址每小时限次数（手机号自己的限制原来就有）；注册风控：新注册按来源地址每天、全站每小时设上限，验证码校验通过后才占名额，已注册的账号不受影响；每个用户同时打开的事件流有上限；IPv6 按 /64 计，可信任负载均衡的 `X-Forwarded-For`；超限返回 429 和 `Retry-After`；`[api.limits]` 配置。计数在各副本内存里，需要全站精确计数时换 Redis | `crates/gateway/src/limits.rs` |
| 4.6 | 账号冻结与全部停止：运维命令 `thinktin-server admin freeze / unfreeze / show`（手机号或用户 id，记操作人和原因，输出里手机号打码）；冻结时取消所有运行、沙箱令牌立即作废，登录、刷新、接口返回 `account_frozen`（403），事件流以 4003 关闭，调度和执行跳过，授权和计划保留、解冻后照常；用户“全部停止”（`POST /v1/me/stop-all`）取消运行、吊销全部运行授权、暂停全部计划，之后在实例上发起运行、恢复计划时自动重新签发授权；“下线其他设备”（`POST /v1/devices/sign-out-others`，可顺带全部停止，对应架构里“修改密码时可选停止全部 agent”）；每一步记审计、通知用户；client-core 的 `AccountFrozen` 错误和事件流状态（不清会话）、`stop_all()`、`sign_out_other_devices()` | `crates/orchestrator/src/account.rs`、`crates/server/src/admin.rs`、[威胁模型 3.3](threat-model.md) |
| 9.11 | 密码保险箱：条目（名字、用途、账号、密码）按用户 DEK 加密、单独的密文域，接口不返回密码；可限定实例；agent 的平台工具 `vault_list`（只给名字和用途）、`vault_request`（App 弹表单，用户填的值只进保险箱，填好后在实例上接着跑一轮）；沙箱里的 `thinktin-vault` 按名字把值注入环境变量、标准输入或参数，执行器核对授权和实例、记审计；运行日志、摘要、审批落盘前，模型网关转发前，把保险箱里的值换成 `[vault:名字]`（认得各种转义写法），网关读不到保险箱就不转发。出口代理注入请求头等 2.7 | [说明](vault.md)、`crates/orchestrator/src/vault.rs`、`crates/agent-shim/src/vault_helper.rs` |
| 11.6 | 输入里的密码拦截：client-core 本地识别消息里的密码和 key（私钥块、已知格式的 key 和 JWT、网址里的密码、跟在“密码 / password / api key / token”后面的值、像 key 的随机串；引用和占位符不算），`send_message` 有命中就返回 `ContainsSecrets` 不发（用户确认后可 `allow_secrets` 强发）；`save_secret_from_message` 存进保险箱并把消息里的值换成 `[vault:名字]`；保险箱条目和 agent 填写请求的接口（列表、详情、新建、修改、删除、填写、拒绝）；FFI 的 `detect_secrets`（UTF-16 下标）、`redact_message`、`unique_vault_name`。界面并入 12.4 / 13.4。服务端兜底：用户坚持发送或旧客户端没拦的，建运行时把保险箱里已有的值换成引用再存库 | `crates/client-core/src/secrets.rs`、`client.rs`、`api.rs`、`ffi.rs`、`crates/gateway/src/routes/runs.rs`、[保险箱说明第 7 节](vault.md) |
| 11.1 | UniFFI 工程：client-core 出 Swift（`ThinktinCore`）/ Kotlin（`cn.thinktin.core`）绑定；xcframework + Swift Package、Android 库工程 / AAR 打包脚本（`mobile` 编译配置、16 KB 页对齐）；经 C ABI 的冒烟测试 | `crates/client-core/src/ffi.rs`、`tools/client-core/` |
| 11.2 | 接口客户端：版本头、统一错误模型（按错误码区分重新登录 / 重试 / 提示）、访问令牌过期自动刷新（并发只刷一次）、刷新令牌失效清会话；会话交给原生端的安全存储 | `crates/client-core/src/api.rs` |
| 11.3 | 事件流：WebSocket 按序号续传、去重、指数退避加抖动重连、空闲超时、握手 401 / 4001 关闭时刷新令牌再连、会话失效或实例不存在时停止 | `crates/client-core/src/events.rs` |
| 11.4 | 本地缓存：SQLite 存实例、运行、事件（续传位置）、收件箱；离线标已读先记本地、联网补发；缓存按用户隔离，退出登录清空 | `crates/client-core/src/cache.rs`、`client.rs` |
| 7.11 | 等待电脑与等待 key：执行器从模型网关的调用记录认出 agent 卡在 key 上（失效、欠费、没有能用的 key 连续两次；限流、繁忙持续两分钟；一轮结束时放宽），停下这一轮、转入“等待额度 / key”，放掉租约和执行名额，要用户处理的才推送；新增、换 key、启用 key、改模型路由时唤醒，欠费和额度用完每小时自己试、限流和繁忙几分钟后再试；从等待里接着跑不占重试次数；计划策略加 `wait_timeout_secs`（默认 24 小时），超时结束运行（策略是暂停计划的同时暂停）。网关对“一把 key 都没用上”也记一条 `unavailable`。等电脑的唤醒（macOS 设备登录）和超时一并备好，电脑工具随 14.x | `crates/orchestrator/src/waits.rs`、`executor.rs`、`crates/store/migrations/0010_run_waits.sql` |
| 7.10 | 离线审批策略：预授权范围（计划策略的 `preauthorized_tools`，shim 直接批准、不推送）、审批队列（列表、决定、推送里直接拒绝）、超时策略（跳过 / 暂停计划 / 失败）。这次补上：平台按审批的时限判超时（沙箱被空闲回收暂停时 shim 的计时器不走）；跳过时告诉 agent 不做这一步、接着跑，并通知用户跳过了什么；没有计划的运行按失败处理 | `crates/orchestrator/src/executor.rs`（`poll_approvals`、`on_approval_timeout`） |
| 8.6 | 共享预算与权限收窄：整棵运行树共用根运行的 token 上限（执行器续租时加上树里别的运行已经用掉的，超了就停下这一轮、判失败）；子运行的授权从父运行的授权收窄出来（范围不超过父运行、有效期不超过它、父授权吊销时一起失效） | `crates/orchestrator/src/executor.rs`、`crates/store/src/grants.rs` |
| 8.7 | 委派工具 `delegate`、`delegate_list`：只给团队负责人；子任务是父运行下的子运行，在成员自己的沙箱里用它自己的 key 跑；工具立刻返回，负责人这一轮结束时还有子任务没做完就转入“等待子任务”、放掉租约；子任务都结束后平台把结果（完成 / 失败 / 取消、总结）作为新消息交给它接着跑，交过的不再交，不占重试次数；父运行失败时停掉没做完的子孙；子任务的完成不单独推送 | `crates/orchestrator/src/delegate.rs`、`crates/store/migrations/0011_delegation.sql` |
| 8.8 | 委派护栏：最多 3 层；不能交给自己或链上已经在等它的 agent（循环会互相等死）；一次运行最多 10 个子任务；成员只能是负责人自己团队里的实例 | `crates/orchestrator/src/delegate.rs` |
| 6.5 | 唤醒与预热：计划快到点（默认提前 2 分钟）时，它要用的、暂停着的实例（计划自己的和流水线第一批步骤的）由巡检提前唤醒，到点时 agent 马上能干活；空闲暂停原来就有，有运行在执行时不暂停 | `crates/control/src/lib.rs`（`sweep`）、`crates/store/src/instances.rs`（`instances_to_prewarm`） |
| 7.13 | 副作用幂等：有副作用的平台工具（建、改、取消计划，发布产出物，委派，请用户填密码）按“运行 + 工具 + 参数”只执行一次，agent 重试（或同一轮里重复调）时直接复用上次的结果，不会多建一个计划、多委派一个子任务；失败的不记，可以再试 | `crates/orchestrator/src/executor.rs`（`call_tool`）、`crates/store/migrations/0012_tool_calls.sql` |
| 7.14 | 接管 agent 自带定时：清单写 `heartbeat = "platform"` 的，配置生成器关掉 agent 自带的定时和心跳（OpenClaw：`cron.enabled = false`、`OPENCLAW_SKIP_CRON=1`、心跳 `every = "0m"`；Hermes：定时任务只在它的 gateway 守护进程里触发，沙箱里不起，再加 `cron.allow_agent_scheduling = false`）；目录测试保证归平台管的清单都配了能关的生成器。计划一律走平台工具 `schedule_*` | `crates/agent-shim/src/config.rs`、`crates/catalog/src/manifest.rs` |
| 7.12 | 断点续跑：重试时看 agent 的会话有没有接回，接回了只加续跑说明，没接回（换了机器、会话丢了）就附上平台从运行日志整理的续跑简报（最近调用的工具、最后说的话、中断原因）；委派过子任务的提醒别重复委派。沙箱丢失按模板重建 + 工作区卷 + 会话接回原来就有；整机快照恢复等 Cube 联调（2.3） | `crates/orchestrator/src/executor.rs`（`resume_brief`） |
| 11.5 | 配对与验签协议（P3，提前做：12.9、13.9 的审批与签名要用）：手机和电脑扫码交换 P-256 公钥、双方签名确认，云端只转发；高危操作的审批消息（参数摘要、说明摘要、决定、有效期）由手机签、电脑验；普通操作的能力令牌（目录、应用、有效期）；签名接受 DER 和 r‖s、高 S 规整；测试向量由 OpenSSL 独立生成 | `crates/client-core/src/pairing.rs`、[说明](pairing.md) |
| 1.6（服务端部分） | 多语言：用户的语言偏好（`zh-CN` 默认、`en`；新用户按设备的 `Accept-Language` 定，`PATCH /v1/me` 改，客户端核心 `set_locale`）；平台写的推送、收件箱、等 key 的状态说明、推送里的 AI 标识、下载文本的标识，以及交给 agent 的续跑、委派、交接说明都按用户的语言输出；接口错误由客户端按错误码翻译 | `crates/orchestrator/src/texts.rs`、[说明](i18n.md) |
| 4.1（短信通道） | 阿里云短信服务（SendSms）：国内号码用国内签名和验证码模板，其他国家和地区用国际 / 港澳台模板（可选）；RPC 签名（HMAC-SHA1）按阿里云文档的示例核对；只有 `OK` 算发出，限流等报阿里云的错误码、不带验证码；`[sms.aliyun]` 配置，AccessKey 走环境变量；没配服务商时接口只能开 `api.dev_sms`（本地开发） | `crates/auth/src/sms/aliyun.rs` |
| M6（续） | S3 兼容对象存储：产出物密文放 AWS S3、阿里云 OSS、腾讯云 COS、MinIO（`[storage] provider = "s3"`，访问密钥走环境变量）；请求按 AWS Signature V4 签名、正文哈希一起签，签名按 AWS 文档的两个示例核对，假 S3 按收到的请求重新验签跑通上传、下载、删除 | `crates/orchestrator/src/s3.rs` |
| 17.3（服务端部分） | 常驻场景测试（端到端）：用户设好计划后关掉 App、退出登录，调度器照样到点建运行、执行器用计划的运行授权跑完；再登录时收件箱有结果，退出期间的事件按序号补回、一条不少。App 那一侧（12.8、13.8 的后台刷新、断网重连）随客户端做 | `crates/e2e/tests/main_chain.rs` |
| 17.4 | 多 agent 协同测试：委派最多 3 层（一条负责人链往下传，第 4 跳被拒，结果一层层交回、只有根运行推送）；一次运行最多 10 个子任务（第 11 个返回错误、不建子运行）；流水线里没有依赖的步骤一起排队、在各自的实例上同时执行，下游等它们都完成；失败传播、循环、共享预算原来就有测试 | `crates/orchestrator/tests/executor.rs`、`pipeline.rs` |
| 4.3、4.4（换取） | 运行授权：签发、范围只能收窄的子授权、连带吊销、有活动自动续期；退出登录不影响；用授权换绑定沙箱的令牌 | `crates/auth/src/grants.rs` |
| 评审 | 后端核心的对抗式评审（租户隔离、账号会话、调度执行、agent 边界、接口面、数据与推送六个维度，45 条发现逐条复现后修复，每条带回归测试）。要点：刷新令牌历史防重放、丢响应可重试；agent 输出全程有上限；审批不占执行名额、跨暂停和重试；租约启动期间续租、续不上自停；RRULE 计算有界、DTSTART 前移；计划确认绑定版本、agent 建计划有上限且授权挂在调用方下；授权树、运行树连带吊销 / 取消；沙箱令牌带代数，运行结束即作废；调度合并积压、冻结账号不调度；预授权的工具调用不发审批推送；推送只发给登录着的设备；注销在活跃账号上也能完成；公网入口限请求头和请求时长；事件流全过期时发 reset；客户端会话没了立即清缓存 | `crates/store/migrations/0007_review_fixes.sql` 及各模块测试 |

## 进行中

- 后端 P2 的工作包已完成，`backend-core` → `main` 的 PR 是 #5，等用户审、合并。
- **云 KMS（2.6 的代码部分，上线前置）**：主会话在做（2026-10-16 18:58 起）：`Kms` 改成异步、按主密钥 id 分派（换主密钥后老的 DEK 照样解得开），接阿里云 KMS（Encrypt / Decrypt，主密钥不出 KMS）；`[kms] provider = "aliyun"`。
- **6.6 工作区卷与快照管理（部分）**：7 天归档（销毁沙箱、留工作区卷）、删除后回收原来就有；按用户加密、增量存储要靠 Cube 的存储能力，等 2.3 部署后联调时做。
- **4.5 biscuit 能力令牌（推迟）**：逐级收窄已经由服务端的运行授权树做到（4.3：子授权范围只能收窄、有效期跟着父授权、连带吊销；委派和流水线都用它）。biscuit 的长处是持有者离线收窄、对方离线验签，现在用不上：子运行都由编排服务签发。等电脑工具（14.x）需要电脑端离线验签时再引入 `biscuit-auth`（这个环境也加不了新依赖）。
- 认领规则：开工前在这里写“谁在做、几点开始”并马上推送；两小时内有人认领过的包别重做，挑下一个没人认领的。

## 里程碑（后端核心，P1）

| 里程碑 | WBS | 内容 | 状态 |
|---|---|---|---|
| M1 基础 | 3.1、3.2、3.3、3.4、3.5 | 领域类型、协议版本；Postgres 表结构与迁移、带 TenantCtx 的仓储和 RLS；server 组装、配置、健康检查、优雅停机 | 完成 |
| M2 身份与授权 | 4.1、4.2、4.3 | 手机号登录（验证码发送可替换）、设备会话（访问令牌 + 按设备的刷新令牌）、运行授权（签发、续期、吊销、范围）；接上沙箱令牌 | 完成（访问令牌每次请求查库核对会话，M5 加缓存） |
| M3 执行面 | 6.1、6.2、6.3、6.4 | 沙箱抽象（按 E2B 接口）、Cube 后端、本地开发后端、实例生命周期 | 完成（Cube 后端已按接口规范实现并用模拟服务测过，真实集群联调待 2.3 部署） |
| M4 编排 | 7.1–7.7、7.9 | 计划与触发器（cron / RRULE / 一次性，带时区）、调度循环、运行状态机、执行租约、出箱、补跑、预算护栏、运行日志 | 完成（端到端测试：计划到点 → 真实 agent-shim → 结果与通知；Redis 热数据待 M5 事件流） |
| M5 接入网关 | 5.1–5.3、9.8 | REST 接口、WebSocket 事件流、按序号续传；key 管理接口 | 完成（会话核对每次查库、热数据走 Postgres 通知；需要时加缓存 / Redis；短信通道待选型） |
| M6 平台工具与协同 | 6.12、7.8、8.1–8.5 | MCP 桥接、thinktin.schedule、团队、运行树、流水线、产出物、交接说明 | 完成（对象存储有本地目录和 S3 兼容两种后端） |
| M7 通知 | 10.1、10.3、10.4 | 收件箱、APNs、国内厂商推送（接口 + 统一推送服务适配） | 完成（国内推送先走极光，见待决问题 5；厂商直连按需补） |
| M8 客户端核心 | 11.1–11.4 | UniFFI、接口客户端、事件流续传、本地缓存 | 完成（打包脚本需要在 macOS / 装了 NDK 的机器上实跑验证） |
| M9 端到端 | 17.1、15.2、15.4、16.3 | 本地沙箱 + 模拟厂商跑通主链路；租户隔离测试；密钥与日志审计；AI 生成内容标识 | 完成（标识的元数据字段、非文本文件的标识方式、内容安全服务待定，见待决问题 6–8） |

## 已拍板（2026-10-14）

- **问题 1**：**Claude 全球提供**，不分国内站、海外站。**Claude agent 什么 key 都能接**（任何厂商的 Anthropic 兼容接口、用户自己配的中转站），不限于 Anthropic 官方凭证。已知风险：Anthropic 文档说不支持把 Claude Code 接到非 Claude 模型，地区政策点名 Claude Code 不支持中国大陆、香港、澳门（见 [接入说明 2.1 节](agent-integration.md)）。
- **问题 2**：**一个全球产品**，不分国内站、海外站，后面做多语言（WBS 1.6）。暂不接其他 agent；以后要接，优先 DeepSeek。清单和厂商表里的 `sites` 字段以后去掉。
- **问题 3**：agent 通过 thinktin.schedule 新建、修改的计划，**要用户确认才生效**：先暂停并推送提醒，用户在 App 里点确认（恢复）才开始跑；取消不用确认。
- **问题 4**：架构方案第 14 节按方案里的建议：运行授权 90 天、有活动自动续期；审批 24 小时没人处理就暂停计划；多 agent 协同先做流水线，委派放 P2。
- **问题 5**：国内 Android 推送**先接极光**（一个接口覆盖华为、荣耀、小米、OPPO、vivo，按“系统消息”发，各厂商的消息分类在厂商后台申请后填进 `[push.jpush.vendors]`）。另外**提供 APK 安装包直接下载**（WBS 13.12）。上线前要确认极光的商用条款和费用、隐私政策里披露第三方推送 SDK、各厂商推送权限的申请条件。
- **问题 6**：下载的非文本产出物（代码、JSON、PDF、图片……）**不加显式标识**，只有元数据里的隐式标识；纯文本、Markdown 末尾保留一行“本内容由人工智能生成”（`[compliance] label_downloads` 可关）。
- **问题 7**：**不接第三方内容审核服务**，只保留推送的本地关键词过滤。
- **问题 8**：隐式标识的元数据字段按默认：`Label`、`ContentProducer`、`ProduceID`（按 GB 45438-2025 的公开解读）；服务提供者名称或编码在 `[compliance] content_producer` 配置，备案后填正式编码。
- **问题 9**：对话、提示词、运行摘要**不整体加密**。改做**密码保险箱**（WBS 9.11、11.6），参照 Muse：用户在对话框里要发密码时，不收明文，弹出表单让用户填账号密码，存进保险箱（按用户 DEK 加密），对话里只留名字；agent 需要账号密码时也是发起一个表单请求。agent 用的时候由沙箱里的助手按名字注入命令，不进 agent 的上下文；模型网关转发前再把保险箱里的值从请求里抹掉，模型永远看不到明文。
- **问题 10**：**平台接任何 LLM key**：预置主流**模型品牌方**自己的官方接口（WBS 9.12）；聚合平台、中转站不预置，用户自己填接口地址和 key，配好就能用。自定义地址必须是 https、解析到公网地址（防 SSRF）。

## 待决问题

新的问题出现时记在这里，未拍板前按括号里的默认做。

- **短信服务商**：正式上线登录要真的发短信。（已按默认接了阿里云短信服务：国内和国际 / 港澳台都走同一个接口；签名和验证码模板要在阿里云控制台申请，下来后填进 `[sms.aliyun]`。要换腾讯云短信再加一个实现。）
- **云服务商**：KMS 要接一家云。（默认阿里云 KMS，和对象存储 OSS、短信同一家；换别家再加一个实现。）
