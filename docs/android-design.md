# 安卓端设计规范（WBS 13.x）

> 更新日期：2026-10-22　｜　状态：草案　｜　依据：架构方案 v3 第 8 节、WBS 13.x、client-core 接口（`crates/client-core/src/ffi.rs`）

信息架构和视觉参考 **Claude Android App**（抽屉 + 以对话为中心、暖色中性底、衬线标题、底部胶囊输入框、回复不带气泡）。只借鉴版式和交互习惯，不使用对方的名字、标志、图标和字体文件；品牌名是 ThinkTin。

## 1. 技术选型

| 项 | 决定 |
|---|---|
| 语言 / UI | Kotlin 2.1、Jetpack Compose、Material 3（`androidx.compose.material3`），单 Activity + Navigation Compose |
| 最低版本 | minSdk 26（Android 8.0），targetSdk / compileSdk 35 |
| 工程 | Gradle Kotlin DSL + 版本目录（`gradle/libs.versions.toml`）；模块 `:app`、`:core`（client-core 绑定）、`:design`（主题与组件）、`:data`（仓储、Mock）、各功能模块按需拆 |
| 核心 | `crates/client-core` 的 UniFFI Kotlin 绑定（包 `cn.thinktin.core`），`:core` 模块装 `client_core.kt` 和 `jniLibs`（`tools/client-core/build-android.sh`），JNA 调用，async 函数是挂起函数 |
| 状态 | ViewModel + `StateFlow`，单向数据流（UiState / UiEvent），协程 |
| 依赖注入 | 手写的 `AppContainer`（先不上 Hilt，减少编译时间和 KSP 依赖；需要时再换） |
| 本地存储 | 会话令牌：`EncryptedSharedPreferences`（Keystore 主密钥）实现 client-core 的 `SessionStore`；缓存由 client-core 的 SQLite 负责；界面偏好：DataStore |
| 推送 | 构建变体 `cn`（极光推送）与 `global`（FCM）；SDK 只在对应变体里编译 |
| 图片 / 二维码 | Coil；扫码用 ML Kit 或 ZXing（13.9 再定） |
| 测试 | JVM 单元测试（JUnit 4，Robolectric 与 Compose 测试规则都基于它；kotlinx-coroutines-test、Turbine）；Compose UI 测试用 Robolectric 在 JVM 上跑（云端没有模拟器）；每个页面至少一条“渲染 + 主要交互”测试 |
| CI | GitHub Actions `android` job：`gradle test`、`lint`、`assembleDebug`；client-core 的 `.so` 用 mobile.yml 的 android job 或本地脚本产出后缓存 |

## 2. 视觉

### 2.1 颜色（Material 3 色板，语义化命名）

| 角色 | 浅色 | 深色 | 用途 |
|---|---|---|---|
| background | `#F7F5F0`（暖米白） | `#1F1E1B` | 页面底 |
| surface | `#FFFFFF` | `#2A2926` | 卡片、输入框、抽屉 |
| surfaceVariant | `#EFEBE3` | `#353430` | 用户消息气泡、工具调用卡片 |
| onBackground / onSurface | `#1F1E1B` | `#F2EFE8` | 正文 |
| onSurfaceVariant | `#6B675F` | `#A8A49B` | 次要文字、时间戳 |
| primary | `#C9653F`（赭橙） | `#E08A64` | 发送按钮、主按钮、选中态 |
| onPrimary | `#FFFFFF` | `#1F1E1B` | |
| secondary | `#4F6F8F`（青灰蓝） | `#8FB0CF` | 链接、信息标签 |
| error | `#B3261E` | `#F2B8B5` | 失败状态、危险操作 |
| success（自定义） | `#3E7D5A` | `#8FCBA6` | 运行成功、在线 |
| warning（自定义） | `#B07A1E` | `#E2B45F` | 等待审批、等待 key |
| outline | `#D9D4CA` | `#45433E` | 分割线、描边 |

主题跟随系统，设置里可固定浅色 / 深色。动态取色（Material You）关闭，保持品牌色稳定。

### 2.2 字体

- 标题、问候语、空状态大字：`FontFamily.Serif`（系统 Noto Serif / Noto Serif CJK），字重 Regular，字号 28–34sp，行高 1.2。
- 正文、按钮、列表：`FontFamily.Default`（系统无衬线），正文 16sp / 行高 24sp，次要 14sp，标签 12sp。
- 代码块、工具调用参数：`FontFamily.Monospace` 13sp。
- 不打包字体文件（体积和许可证），先用系统字体；需要时再按 `docs/licenses.md` 登记后加入。

### 2.3 形状与间距

- 圆角：卡片 16dp，输入框胶囊 28dp，气泡 18dp（用户消息右下角 4dp），按钮 20dp。
- 页边距 16dp，列表项高 56dp 起，段落间距 12dp，消息间距 20dp。
- 不用阴影分层，用 `surface` 与 `background` 的对比和 1dp `outline` 分割。

### 2.4 图标

Material Symbols（Outlined），24dp；品牌标志用简单的几何形（后续由 1.4 视觉规范定）。

## 3. 信息架构与导航

```
MainActivity
 ├─ 抽屉（ModalNavigationDrawer）
 │   ├─ 搜索
 │   ├─ 新对话（选实例 / 领养）
 │   ├─ 收件箱（未读角标）
 │   ├─ 计划
 │   ├─ 团队与流水线
 │   ├─ 我的 agent：实例列表（名字、agent、状态点）
 │   └─ 底部：头像 + 名字 → 设置
 ├─ 主区（NavHost）
 │   ├─ home            首页（问候语 + 输入框 + 最近运行）
 │   ├─ chat/{instance} 对话（运行时间线 + 输入框）
 │   ├─ run/{run}       运行详情 / 运行树
 │   ├─ catalog         Agent 目录 → agent/{id} 详情 → 领养
 │   ├─ instance/{id}   实例设置（重命名、版本、模型别名、删除）
 │   ├─ plans           计划列表 → plan/{id} → 编辑
 │   ├─ teams           团队 → team/{id} → 流水线编辑
 │   ├─ inbox           收件箱 → 跳转到运行 / 审批 / 计划
 │   ├─ approvals       审批队列 → approval/{id}
 │   ├─ keys            模型 key 与用量 → 添加 key
 │   ├─ vault           密码保险箱 → 条目 / 填写请求
 │   ├─ devices         设备列表
 │   └─ settings        设置（账号、语言、外观、通知、IM 渠道、开源许可、关于、注销）
 └─ 登录流（login → code）独立导航图，未登录时替换整个主区
```

- 返回栈：抽屉入口的页面都是顶级目的地（`popUpTo(home)`），其余是子页面。
- 深链（两端一致）：`thinktin://run/{id}`、`thinktin://approval/{id}`、`thinktin://plan/{id}`、`thinktin://instance/{id}`、`thinktin://vault/request/{id}`、`thinktin://inbox`、`thinktin://inbox/{id}`，推送点击用它们跳转；`thinktin://approvals`（审批中心）是 iOS 小组件用的，安卓也认；推送载荷里的字段两端共用服务端的定义（`notify::PushMessage` 的 `tt_*` 数据）。

## 4. 页面规范

### 4.1 登录（13.2）

- 两步：手机号（国家码选择，默认 +86）→ 验证码（6 位，自动聚焦、倒计时重发）。
- 顶部衬线大标题“欢迎使用 ThinkTin”，底部同意隐私政策与用户协议的说明。
- 错误码映射：`rate_limited` 显示剩余秒数；`account_frozen` 跳到冻结说明页；网络错误用 Snackbar。

### 4.2 首页（13.3 / 13.5）

- 顶栏：左抽屉按钮，中间当前实例名（可切换），右溢出菜单。
- 没有实例：衬线问候 + “领养一个 agent”主按钮 + 目录精选卡片。
- 有实例：衬线问候（按时段：早上好 / 下午好 / 晚上好）、底部输入框、“最近运行”列表（状态点 + 摘要 + 相对时间）。

### 4.3 对话（13.5）

- 时间线按运行分组：每个运行一个区块，区块头显示触发来源（用户 / 计划 / 流水线 / 委派）、状态、耗时、token。
- 用户消息：右对齐、`surfaceVariant` 气泡。
- agent 文本：左对齐、无气泡、Markdown 渲染（标题、列表、代码块、链接）。
- 工具调用：可折叠卡片，头部“图标 + 工具名 + 一句话摘要 + 状态”，展开显示参数与结果（等宽字体），出网 / 文件 / 电脑操作用不同图标。
- 审批：内嵌卡片，标题、说明、选项按钮（批准 / 拒绝 / 一直允许），24 小时倒计时；拒绝直接发，批准在 13.9 之后要生物识别签名，之前走普通确认。
- 产出物：卡片（文件名、大小、类型），点开预览或下载。
- 状态条：运行中显示“正在…”的细进度条；等待审批 / 等待 key / 等待电脑显示警告色横幅并给出操作入口。
- 输入框：胶囊，左“+”（附件：先只有图片与文件占位）、中多行文本、右发送（主色圆钮），运行中变为停止按钮。
- 发送前密码拦截：`detect_secrets` 有命中则弹底部表单（名字、用途、账号、密码预填），确认后 `save_secret_from_message` 替换为 `[vault:名字]` 再发；“仍然发送”需二次确认。
- 续传：进入页面先 `cached_events`，再 `subscribe`；断线显示顶部提示，重连后自动补齐。

### 4.4 Agent 目录与领养（13.3）

- 目录：卡片列表（名字、一句话、许可证标签、接入方式）。
- 详情：介绍、版本、许可证与上游链接、支持的能力；“领养”按钮 → 命名 + 选模型别名（可跳过，用默认）。
- 实例设置：重命名、版本（升级 / 回滚，提示下次唤醒生效）、模型别名与降级链、删除（二次确认）。

### 4.5 模型 key 与用量（13.4）

- key 列表：厂商图标、标签、后 4 位、每日限额、状态（禁用 / 正常）。
- 添加：选厂商（预置品牌 + 自定义）→ 填 key（密码输入、粘贴检测）→ 自定义地址（https 校验）→ 可选每日 token 限额；提交错误（订阅类 key、地址不合规）用字段级提示。
- 用量：按天柱状、按实例 / 模型 / key 切换的表格，总计卡片。

### 4.6 计划（13.6）

- 列表：标题、实例、下次触发（相对时间）、状态（运行中 / 暂停 / 待确认）。
- 待确认的 agent 创建计划置顶，卡片带“确认”“拒绝”。
- 编辑：目标（多行）、触发（每天 / 每周 / 每月 / 自定义 cron / 一次性，时区默认设备时区）、策略（预算、超时、审批超时动作）。
- 详情：触发器列表、运行历史（状态、时长、摘要）、暂停 / 恢复、删除。

### 4.7 团队与流水线（13.7）

- 团队：成员实例卡片，保存为模板。
- 流水线编辑：步骤列表（拖动排序），每步选实例、写提示词、勾依赖步骤；底部“运行一次 / 保存为计划”。
- 运行树：缩进树（父运行 → 子运行），每行状态点、实例名、耗时，可单独停止；顶部“停止整棵树”。

### 4.8 收件箱与推送（13.8）

- 收件箱：按天分组，未读加粗，类型图标（完成 / 失败 / 审批 / 计划待确认 / 填写请求）；点击跳转；下拉同步，上拉加载更多；全部已读。
- 通知渠道：`tt_approval`（审批、电脑审批、保险箱请求，高优先级，有声音）、`tt_results`（其余，默认），id 和服务端 `[push.fcm]` / `[push.jpush]` 的默认值一致；常驻通知的 `progress`（低）等用到时再加。
- 推送令牌：登录后与应用启动时 `set_push_token(channel, token)`，`channel` 为 `unipush`（极光）或 `fcm`（服务端的 `PushChannelKind`）。推送 SDK 在用户登录（同意隐私政策）之后才启动。

### 4.9 设置（13.13）

- 账号：手机号、昵称、语言（跟随系统 / 中文 / English，调 `set_locale`）、外观。
- 安全：设备列表（当前设备标记、远程下线）、下线其他设备（可勾选“同时停止全部 agent”）、全部停止（危险操作，二次确认）。
- 通知、IM 渠道（P4）、密码保险箱入口。
- 关于：版本、检查更新（13.12）、开源许可（读 `assets/thinktin-licenses/inventory.json` 与 `NOTICES.md`）、隐私政策、用户协议、注销账号。

## 5. 文案与多语言

- 所有文案进 `strings.xml`（`values` 中文、`values-en` 英文），不写死在代码里。
- 服务端错误按 `code` 映射到本地文案；`message` 只进日志。
- 时间显示：相对时间（刚刚、5 分钟前、昨天 20:30），超过一周显示日期；时区用设备时区。
- 数字：token 用千分位；大于 1 万显示“1.2 万”（中文）或“12k”（英文）。

## 6. 无障碍与适配

- 所有图标按钮带 `contentDescription`；颜色对比度 4.5:1 以上；支持字号缩放到 200%。
- 适配刘海与手势导航（`enableEdgeToEdge`）；横屏与平板先保证不崩、不要求专门布局。
- 输入法弹起时输入框跟随（`imePadding`）。

## 7. Mock 与离线

- `:data` 模块有 `MockThinktinClient`，覆盖 client-core 的全部接口，用假数据演示所有页面，`debug` 构建可在设置里切换“演示模式”。
- 页面先从缓存（`cached_*`）渲染，再联网刷新；断网时顶部显示“离线，显示的是缓存内容”。

## 8. 数据契约速查（来自 client-core / proto）

客户端只和 `cn.thinktin.core.ThinktinClient`（UniFFI 生成）打交道：id 都是字符串，时间是 Unix 毫秒（`*_at_ms`），结构不固定的部分是 JSON 字符串（`payload_json`、`tool_call_json`、`policy_json`）。

### 8.1 状态取值

| 字段 | 取值 | 界面 |
|---|---|---|
| `Instance.state` | `provisioning` / `running` / `paused` / `archived` / `deleted` | 状态点：创建中（灰闪）、运行中（绿）、已暂停（灰）、已归档（空心）、已删除（不显示） |
| `Run.state` | `queued` / `starting` / `running` / `waiting_approval` / `waiting_device` / `waiting_quota` / `waiting_children` / `backoff` / `succeeded` / `failed` / `cancelled` | 排队、启动中、运行中（进度条）、等待审批 / 等待电脑 / 等待 key（警告色横幅）、等待子任务、重试等待、成功（绿）、失败（红）、已取消（灰） |
| `Run.source` | `user` / `plan` / `pipeline` / `delegate` / `ask` | 运行区块头：你 / 计划 / 流水线 / 委派 / 队友提问。`ask`（8.11）是别的 agent 问这个实例的问题，`prompt` 是 agent 写的，不能显示成“你”，要标 AI 生成；不认识的来源也不要当成用户发的 |
| `Run.wait_code` | `invalid` / `no_balance` / `unavailable` / `rate_limited` / `overloaded`（`waiting_quota`）、`device_offline`（`waiting_device`）、`answer`（`waiting_children`，只在等队友回答） | 等待横幅的下一步；不认识的按 `state` 显示 |
| `Run.kind` | `agent` / `pipeline` | 流水线根运行只显示子运行汇总 |
| `Approval.state` | 见 `proto::domain::ApprovalState`（`pending` 等） | 待处理 / 已批准 / 已拒绝 / 已超时 |
| `ApprovalOption.kind` | `allow_once` / `allow_always` / `reject_once` / `reject_always` | 批准 / 一直允许 / 拒绝 / 一直拒绝 |
| `InboxItem.kind` | `run_finished` / `run_failed` / `approval` / `computer_approval` / `info` | 完成（绿勾）、失败（红叉）、审批（警告铃）、电脑审批（电脑图标）、提醒（信息） |
| `StreamStatus` | `Connecting` / `Live` / `Reconnecting{retry_in_ms}` / `SignedOut` / `NotFound` / `AccountFrozen` / `Stopped` | 顶部连接提示；`SignedOut` 回登录页，`AccountFrozen` 冻结说明页 |
| `ClientError` | `Network` / `SignedOut` / `UpgradeRequired` / `AccountFrozen` / `Api{status, code, message, retry_after_secs}` / `Decode` / `Cache` / `ContainsSecrets{count}` / `InvalidArgument` / `Internal` | 网络：Snackbar 重试；SignedOut：回登录；UpgradeRequired：升级提示；Api 按 `code` 映射文案 |
| `User.locale` | `zh-CN` / `en` | 设置里的语言 |

### 8.2 事件流（`InstanceEvent.kind` 与 `payload_json`）

对话页按 `run_id` 把事件归到运行区块；同一运行里按 `seq` 排序。用户的提问不在事件流里，取 `Run.prompt`。

| kind | payload 主要字段 | 渲染 |
|---|---|---|
| `agent.message` | `text` | agent 文本（累积拼接相邻的同类事件后再做 Markdown） |
| `agent.thought` | `text` | 可折叠的“思考过程”，默认收起 |
| `agent.tool_call` | `tool_call_id`、`title`、`kind`（read / edit / search / execute / fetch…）、`status`、`raw` | 工具调用卡片，按 `kind` 选图标；`raw` 展开显示 |
| `agent.tool_call_update` | `tool_call_id`、`status`、`raw` | 更新同 id 卡片的状态（pending / in_progress / completed / failed） |
| `agent.plan` | `entries` | agent 的计划清单（任务列表卡片） |
| `agent.usage` | `raw` | 不进时间线；显示在运行详情里（与 iOS 一致） |
| `agent.permission_requested` | `request_id`、`title`、`options[]{option_id,name,kind}`、`tool_call` | 内嵌审批卡片（真正提交用 `approvals()` / `decide_approval`） |
| `agent.permission_resolved` | `request_id`、`option_id`、`by`（policy / user / timeout / cancelled） | 审批卡片变为已决定 |
| `agent.platform_tool_call` | `call_id`、`name`、`arguments` | 平台工具调用卡片（schedule_*、artifact_*、delegate、agents_list / agent_status、board_read / board_post、ask…） |
| `agent.vault_reveal` | `call_id`、`refs[]` | “使用了保险箱：名字”提示 |
| `agent.turn_started` / `agent.turn_ended` | `stop_reason`（end_turn / max_tokens / max_turn_requests / refusal / cancelled） | 不显示；`turn_ended` 用来结束流式状态，异常 stop_reason（max_tokens、refusal）显示一行说明 |
| `agent.ready` / `agent.session_lost` / `agent.exited` / `agent.update` / `agent.error` | 见 `proto::shim::ShimEvent` | 系统提示行（灰色小字），`agent.error` 用错误色 |
| `run.state` | `state`、`reason`、`attempt`、`wait_code?`、`tree?`、`steps?` | 运行区块头的状态；等待类状态显示横幅并给出下一步（去审批、去配 key、等电脑上线）。`reason` 不要当成本地化文案：waiting_quota 的是服务端按用户语言写的，waiting_approval 的是 agent 写的审批标题，失败原因是英文诊断（比如 `cancelled` 的 `interrupted by a new message` 是被用户的紧急消息打断了，`no answer in time` 是提问超时） |
| `instance.state` | `state`（没有 `run_id`） | 不进时间线；更新页头和抽屉里的实例状态点 |
| `run.log_truncated` | `limit_bytes` | “日志超出上限，后续输出未记录” |
| `pipeline.step_started` | `step`、`run_id`、`instance_id` | 运行树里的子运行入口 |
| `delegate.started` | `child_run_id`、`instance_id`、`to`、`title` | 同上 |
| `ask.sent` | `child_run_id`、`instance_id`、`to`、`question`（问题第一行，agent 写的） | 提问卡片（问谁、问了什么），点进运行树里的回答；标 AI 生成（8.11） |
| `board.posted` | `post_id`、`tags` | 系统行“发到了看板”，点进看板（8.10） |
| `artifact.published` | `artifact_id`、`name`、`version`、`size` | 产出物卡片 |
| `approval.decided` | `approval_id`、`state`、`option_id` | 审批卡片变为已决定 |
| `plan.needs_confirmation` / `plan.cancelled` | `plan_id`、`title`、`change` | 计划卡片，带“去确认”按钮 |
| `hook.received` | `hook_id`、`bytes`、`content_type`（不含内容） | 系统行“webhook 收到了一个事件”（7.1） |
| `vault.requested` / `vault.fulfilled` / `vault.declined` / `vault.used` | `request_id`、`name`、`purpose`、`fields[]` / `names[]` | 填写请求卡片（带表单入口）、使用提示 |

未知的 kind 一律显示成灰色系统行，不崩。

### 8.3 调用约定

- `ThinktinClient(config, sessions)`：`sessions` 由 App 实现 `SessionStore`（`load()` / `save(session?)`，`Session{user_id, device_id, access_token, refresh_token}`），存 EncryptedSharedPreferences。
- `platform = "android"`，`cache_path` 指向 `filesDir/thinktin.db`，`device_name` 用 `Build.MODEL`（用户可改）。
- 所有 `suspend` 调用都在 client-core 自己的线程池执行；`EventListener` 回调在后台线程，必须切回主线程再改状态。
- 打开对话页：`cached_runs` + `cached_events(instance, 0, N)` 先渲染 → `subscribe(instance, listener)`；离开页面 `subscription.stop()`。更早的运行用 `older_runs(instance, before, limit)` 翻页（11.7）。
- `on_reset(oldest_seq, latest_seq)`：client-core 已删掉本地事件并把续传位置设到 `oldest_seq`，服务端会把保留期内的事件全部补发。App 要：清空归并状态但保留运行记录并重新调 `runs()`；补发会一次涌入很多事件，视图模型按批提交；比 `oldest_seq` 更早的运行没有事件了（默认保留 30 天），只显示 `prompt`、`summary`、`error` 并标注“过程记录已超过保留期”。
- 11.7 之后 client-core 已导出：`update_profile`、`devices` / `revoke_device`、`send_self_code` + `delete_account`、`instance`、`older_runs`、`instance_artifacts` / `delete_artifact`、`update_plan` / `add_trigger` / `delete_trigger`、`inbox_item` / `mark_inbox_unread` / `delete_inbox_item`、团队与模板（`teams`、`create_team`、`adopt_team_template` 等）、`update_credential` / `replace_credential_secret`、设备消息。App 侧服务接口直接接这些方法，不再需要“暂不支持”。
- 发送：`detect_secrets(text)` 有命中先弹保险箱表单；`send_message(instance, text, allow_secrets=false)` 抛 `ContainsSecrets` 时同样处理。实例正忙时可以选“打断”：`send_urgent_message`（8.12，参数同 `send_message`）停下它正在做的、马上处理这条；默认的 `send_message` 排队。
- 事件触发（7.1）：计划的 webhook `plan_hooks` / `create_plan_hook`（先说明收到的内容会交给 agent 和模型厂商，用户同意了才调；
  返回的 `url`、`token` 只这一次，给用户复制）/ `rotate_plan_hook` / `set_plan_hook_enabled` / `delete_plan_hook`；计划策略
  `notify_success` 关掉以后成功的运行不推送、不进收件箱（见 `docs/event-triggers.md`）。
- agent 交流（8.9–8.12）：`update_instance(id, InstanceChange{name?, purpose?, peer_access?})` 改名字、用途说明、“允许其他 agent 查我、问我”；看板 `board(tag?, archived, before_id?, limit?)` / `post_to_board(body, tags, allow_secrets)`（像密码的内容同样抛 `ContainsSecrets`）/ `set_board_post_archived` / `delete_board_post`。
- 列表页先用 `cached_*`（实例、运行、收件箱、未读数）渲染，再调网络版刷新。

### 8.4 AI 生成标识（16.3，App 端）

`InstanceEvent.ai_generated` 只对 `agent.message`、`agent.thought`、`agent.plan` 为真，`InboxItem.ai_generated` 由服务端给。其他 agent 写的文字没有标识位，按下表由 App 补标（标识组件统一放 `:design`，文案和 `proto::labels` 的中英文一致：`【AI 生成】` / `[AI-generated]`）：

| 字段 | 标 | 说明 |
|---|---|---|
| `agent.message` / `agent.thought` / `agent.plan` 的文本 | 是 | 按 `ai_generated` |
| 工具调用、平台工具调用的 `title` | 是 | agent 写的 |
| `Approval.title`、`agent.permission_requested.title` | 是 | agent 写的审批标题 |
| `VaultRequest.purpose`、`vault.requested.purpose` | 是 | |
| `created_by = agent` 的计划标题与目标、`plan.needs_confirmation.title` | 是 | 用户建的不标 |
| `delegate.started.title`、委派子运行的 `Run.prompt` | 是 | 负责人 agent 写的，不能显示成“你说” |
| `source = ask` 的 `Run.prompt`、`ask.sent.question` | 是 | 队友 agent 写的问题（8.11），不能显示成“你说” |
| `BoardPost.body` | 按 `ai_generated` | agent 写的标，用户自己写的不标（8.10） |
| `Run.summary`、`Run.error`（agent 写的部分） | 是 | 失败原因是平台诊断，不标 |
| 流水线步骤 prompt 里附带的上游摘要、产出物名 | 是 | |
| 用户自己的 `Run.prompt`、收件箱的系统通知、平台文案 | 否 | |

复制、分享 agent 输出时在末尾追加标识文字（`docs/compliance.md`）。

### 8.5 审批与生物识别

- 云端审批（agent 的 `request_permission`，服务端不验签）在 P1 就会出现：审批卡（对话内）+ 审批中心（跨实例队列，路由 `approvals`）单独成包 13.16。
- 批准前必须先过 `BiometricPrompt`（`BIOMETRIC_STRONG or DEVICE_CREDENTIAL`，没有生物识别时退到锁屏密码）；拒绝不用验证，通知上的“拒绝”按钮直接发。
- 电脑高危操作的签名审批（Keystore / StrongBox 私钥、扫码配对）是 13.9，属于 P3（随 macOS 端）。

### 8.6 几个容易漏的交互

- 删除实例会级联删掉其他计划里引用它的流水线步骤和团队成员：确认框要列出受影响的计划和团队（先查 `plans()`、`teams()`），再删。
- 团队模板一键领养（`adopt_team_template`）出来的实例没有模型路由，一跑就进 `waiting_quota`：领养完成后弹“逐个配置模型”的列表，没配好的成员标红；运行树里卡在等 key 的子步骤要冒泡到根节点显示。
- 触发规则解析失败时调度器会停用触发器（`Trigger.enabled = false`）而不通知：计划详情页显示“规则已失效，已停用”并给“修改规则”入口（`delete_trigger` + `add_trigger`）。
- `artifact_content` 一次返回整个文件（上限 20 MiB），只能转圈不能显示进度；下载时把客户端超时设够长。
- 推送、深链指向流水线子运行时，要落到运行树里对应的节点。

