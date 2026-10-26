# iOS App 工程说明（WBS 12.x）

> 更新日期：2026-10-23　｜　分支 `ios-app`　｜　进度见 [docs/progress/ios-app.md](progress/ios-app.md)

iOS App 用 Swift + SwiftUI 原生开发，界面参考 Claude 官方 iOS App 的信息架构和视觉；iOS 与 macOS 共享 `ThinktinKit`；
所有网络、续传、缓存、密码识别、配对验签都在 Rust 的 `client-core` 里（架构方案第 8 节），Swift 经 UniFFI 生成的
`ThinktinCore` 包调用。本文记工程上的决定，给接手的人和 agent 看。

## 1. 原则

1. **界面层不写业务逻辑。** 能放进 `client-core` 的都放进去（已经有了：接口客户端、令牌刷新、事件流续传与去重、SQLite 缓存、
   密码识别、配对验签）。Swift 这边只做：把 `ThinktinCore` 的记录转成界面模型、把事件流归并成对话、导航、动画、系统能力。
2. **界面先用 Mock 做，再接真核心。** `ThinktinKit` 定义 `ClientProtocol`（Swift protocol），`MockClient` 实现它并带一套
   演示数据；`ThinktinCoreAdapter` 用 UniFFI 的 `ThinktinClient` 实现它。预览、快照测试、Linux 上的单元测试全部用 Mock。
3. **能在 Linux 上测的都在 Linux 上测。** 云端会话没有 Xcode。纯 Swift 的部分（领域模型、视图模型、格式化、事件归并、
   计划触发器表达、适配层）用 Linux 上的 Swift 6.2 `swift test`；SwiftUI 视图、平台层只能在 GitHub Actions 的 macOS runner
   上编（每次推送都跑，见第 7 节）。
4. **贴 iOS 的习惯，不复刻 Material。** 导航、列表、表单、分享用系统控件；颜色、字体、留白按第 4 节的设计令牌，看起来像
   Claude App，但不用它的商标和品牌字体。

## 2. 目录结构

```
apps/apple/
  project.yml                 XcodeGen 工程定义（不提交 .xcodeproj；本机和 CI 都 `xcodegen generate`）
  Thinktin/                   iOS App target
    App/                      入口、根导航、依赖装配（AppEnvironment）
    Platform/                 Keychain 会话存储、APNs、LocalAuthentication、Secure Enclave、小组件快照、实时活动、深链
    Intents/                  快捷指令和 Siri（App Intents，12.20）
    Resources/                Assets.xcassets、Localizable.xcstrings、PrivacyInfo.xcprivacy、Info.plist 补充项
    Thinktin.entitlements
  ThinktinWidgets/            Widget Extension（主屏、锁屏小组件 12.20；实时活动的锁屏、灵动岛 12.10）
  Shared/                     App 和扩展共用的源文件（实时活动属性 `RunActivityAttributes`）
  ThinktinKit/                Swift Package（iOS / macOS 共享）
    Package.swift
    Sources/ThinktinKit/      纯 Swift：Models、Client（ClientProtocol、MockClient）、Navigation（路由、深链）、ViewModels、
                              Formatting、Conversation（事件归并）
    Sources/ThinktinUI/       SwiftUI：Design（令牌）、Components、Shell（应用框架）、Screens（按功能分目录，每个功能一个接入点）
    Sources/ThinktinCoreAdapter/  ClientProtocol 的 ThinktinCore 实现（依赖 ThinktinCore 包）
    Tests/ThinktinKitTests/   Linux 和 macOS 都跑
    Tests/ThinktinCoreAdapterTests/  Linux 和 macOS 都跑（经真实的 Rust 核心）
    Tests/ThinktinUITests/    只在 macOS 跑（视图编译、快照）
  ThinktinMac/                macOS App target（P3，14.5 起）
```

`ThinktinCore` 包不提交，构建时生成：macOS 上 `tools/client-core/build-apple.sh target/apple`（xcframework），
Linux 上 `tools/client-core/build-linux-swift.sh target/linux`（本机 `libclient_core.so`）。两者接口一致（同一份 UniFFI 绑定）。
`ThinktinKit/Package.swift` 按平台选其中一个路径。

## 3. 分层

| 层 | 目标 | 内容 | 能在哪编 |
|---|---|---|---|
| 领域模型 | `ThinktinKit/Models` | `Instance`、`Run`、`Plan`、`Trigger`、`Approval`、`InboxItem`、`Credential`、`VaultItem`… 的 Swift 版本：强类型枚举（`RunState`、`InstanceState`、`InboxKind`）、`Date` 而不是毫秒、`Identifiable`、`Sendable` | 任何平台 |
| 客户端协议 | `ThinktinKit/Client` | `ClientProtocol`：和 `ThinktinClient` 一一对应的 async 方法，返回领域模型；`ClientError` 的 Swift 枚举；`MockClient` + `DemoData` | 任何平台 |
| 对话归并 | `ThinktinKit/Conversation` | 把 `InstanceEvent` 序列归并成消息列表（第 5 节），纯函数 + 状态机 | 任何平台 |
| 视图模型 | `ThinktinKit/ViewModels` | `@Observable` 类，持有 `ClientProtocol`，暴露界面状态；不 import SwiftUI | 任何平台 |
| 适配层 | `ThinktinCoreAdapter` | `CoreClient: ClientProtocol`，包装 `ThinktinClient`；`EventListener` 桥接；`KeychainSessionStore` 在 App 的 Platform 里 | 任何平台（Linux 用 .so） |
| 界面 | `ThinktinUI` | 设计令牌、通用组件、各页面；只依赖视图模型 | 仅 Apple |
| 平台层 | `Thinktin/Platform` | 系统能力的实现，注入给视图模型（协议化：`PushRegistrar`、`DeviceSigner`（Secure Enclave）、`LiveActivityControlling`） | 仅 iOS |

## 4. 设计令牌（参考 Claude iOS App）

Claude App 的特点：暖色纸张底色、极少的强调色、标题用衬线、正文用无衬线、assistant 的回复不带气泡、用户消息是浅色圆角卡片、
底部输入框是圆角大胶囊、左侧抽屉放对话列表。我们取其感觉，不用其品牌资产。

| 令牌 | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `accent` | `#C96442` | `#D97757` | 发送按钮、选中态、链接、运行中的进度 |
| `paper` | `#FAF9F5` | `#262624` | 页面底色 |
| `paperElevated` | `#FFFFFF` | `#30302E` | 卡片、抽屉、输入框 |
| `userBubble` | `#EFEDE4` | `#3A3936` | 用户消息卡片 |
| `ink` | `#141413` | `#F0EEE6` | 主文字 |
| `inkSecondary` | `#5E5D59` | `#B4B2A9` | 次要文字、时间 |
| `inkTertiary` | `#8E8D87` | `#80807A` | 占位、禁用 |
| `hairline` | `#E5E3DA` | `#3F3E3A` | 分隔线、边框 |
| `success` / `warning` / `danger` | `#2E7D4F` / `#B7791F` / `#C0392B` | `#4A9E6E` / `#D4973A` / `#E05A4C` | 运行状态、审批、失败 |

- 字体：标题 `.fontDesign(.serif)`（系统的 New York），正文默认系统字体（SF）；全部用 Dynamic Type 的语义字号。
- 圆角：卡片 16，输入框 24，小控件 10。间距 4 的倍数。
- 状态色只用于状态，不用于装饰。运行状态与颜色：排队 / 启动中 `inkSecondary`，运行中 `accent`，等待（审批 / 电脑 / key / 子任务）`warning`，
  成功 `success`，失败 `danger`，取消 `inkTertiary`；重试等待（`backoff`）和认不出的状态同排队。实例状态：运行中、启动中、创建中是会呼吸的点，
  已暂停、已删除 `inkTertiary`，已归档是空心点。规则在 `ThinktinUI/Design/StatusTone.swift`，中英文状态名和安卓设计规范一致。
- 深色模式、动态字体、VoiceOver 标签是每个页面的验收项，不是后补的。

## 5. 事件流怎么变成对话

一个实例的事件流（`InstanceEvent`，按 `seq` 递增）是“运行日志”，对话页面按 **运行（Run）** 分组显示：每个运行一条用户消息
（`Run.prompt`），后面跟 agent 的输出。归并规则（`ThinktinKit/Conversation`，纯函数，有单元测试）：

| 事件 `kind` | 载荷（`payload_json`） | 界面 |
|---|---|---|
| `agent.message` | `{text}`，多条连续的拼成一段 | assistant 文本（Markdown），带“AI 生成”标识 |
| `agent.thought` | `{text}` | 可折叠的“思考”块，默认折叠，带“AI 生成”标识 |
| `agent.tool_call` / `agent.tool_call_update` | `{tool_call_id, title, kind, status, raw}` | 工具调用卡片：标题、状态（进行中 / 完成 / 失败），展开看 `raw` |
| `agent.platform_tool_call` | `{call_id, name, arguments}` | 同上，显示为“平台工具：计划 / 产出物 / 委派 / 保险箱” |
| `agent.plan` | `{entries}` | agent 的待办清单卡片，带“AI 生成”标识 |
| `agent.permission_requested` / `agent.permission_resolved` | `{request_id, title, options, tool_call, attempt, approval_id}` / `{request_id, option_id, by, attempt, approval_id, approval_state}` | 审批卡片：未决时显示选项按钮（调 `decide_approval`），已决显示结论（`ApprovalOutcome`：你批准了 / 你拒绝了 / 按预授权 / 已过期 / 已作废）。一个运行里按 `(attempt, request_id)` 认（shim 每次尝试都从 `perm-1` 重新编号）；有 `approval_id` 直接关联审批记录；`approval_state` 是 `expired` 的显示已过期（平台判的超时 shim 回的是 `by: user`）；尝试比运行当前的小的、运行已经结束的待处理卡片作废（backend-core 的 docs/agent-integration.md 第 6 节） |
| `vault.requested` / `vault.fulfilled` / `vault.declined` | `{request_id, name, purpose, fields}` | 保险箱表单卡片（填账号密码，只进保险箱）；已处理显示结果 |
| `run.state` | `{state, reason, attempt}` | 运行状态行：等待类状态显示原因和下一步（去配 key、去审批、等电脑上线） |
| `artifact.published` | `{artifact_id, name, version, size}` | 产出物卡片，点开预览 / 分享 |
| `pipeline.step_started` / `delegate.started` | `{step, run_id, instance_id}` / `{child_run_id, instance_id, to, title}` | 子运行链接卡片，进运行树 |
| `plan.needs_confirmation` | `{plan_id, title, change}` | “agent 新建 / 修改了计划，待确认”卡片，跳到计划页 |
| `plan.cancelled` | `{plan_id, title}` | “agent 取消了计划 X”系统行 |
| `instance.state` | `{state}`，没有 `run_id` | 不进时间线：更新对话页页头和抽屉里的实例状态（“正在唤醒”，已归档的从模板重建会慢一些） |
| `approval.decided` | `{approval_id, state, option_id, request_id, attempt}` | 更新对应的审批卡：先按已关联的审批 id，再按 `(attempt, request_id)`，老的服务端没有这两个键时这个运行里只有一张未决卡片才算它 |
| `vault.used` / `agent.vault_reveal` | `{names}` / `{call_id, refs}` | “用了保险箱里的 github”提示行（只有名字） |
| `agent.usage`、`agent.turn_started`、`agent.turn_ended`、`agent.ready`、`agent.update` | — | 不进时间线（`turn_ended` 结束流式状态，`stop_reason` 为 refusal / max_tokens / max_turn_requests 时显示提示行；`usage` 显示在运行详情） |
| `agent.error`、`agent.session_lost`、`agent.exited`、`run.log_truncated` | `{message}` 等 | 系统提示行 |

- 事件流的回调在后台线程，视图模型切回主线程再更新。
- `on_reset(oldest_seq, latest_seq)`：本地事件作废，清空后从 `cached_events` / 服务端重新加载。
- `StreamStatus`：`connecting` / `reconnecting` 在顶部显示细条；`signed_out` 回登录页；`account_frozen` 显示冻结页；`not_found` 回实例列表；
  `upgrade_required`（服务端回 426，339e191 起）进升级页、停掉所有事件流（`AppModel` 统一处理）；`stopped` 只表示调用方自己停的。
- 账号解冻后要重新订阅：从冻结页回来的页面本来就会重新出现；一直留着的页面看 `AppModel.resubscribeRequest`（`onChange` 时重新订阅）。

## 6. 错误处理

`ClientError`（UniFFI 枚举）在适配层转成 Swift 的 `ClientError`，界面按它决定做什么：

| 错误 | 处理 |
|---|---|
| `SignedOut` | 清状态、回登录页 |
| `AccountFrozen` | 冻结提示页（保留登录态，解冻后照常） |
| `UpgradeRequired` | 全屏“请升级”，带 App Store 链接 |
| `Api(status, code, …)` | `rate_limited` 按 `retry_after_secs` 提示；`conflict` 刷新后重试；`invalid` 显示表单错误；`not_found` 回上一级 |
| `Api(409, *_limit, …)` | 数量到了上限（11.9 起的约定：码以 `_limit` 结尾、状态 409，`APIErrorCode.isQuantityLimit`）：`ErrorRecovery.limitReached`，横幅不给重试按钮（原样重试没用），文案说先删掉一些。`instance_limit`（实例数，领养、团队模板领养）是“实例数已达上限，删掉不用的实例再领养”；这个版本不认识的 `*_limit` 用通用的“数量已达上限” |
| `Network` | 行内可重试的提示；列表页显示缓存数据并标“离线” |
| `ContainsSecrets(count)` | 发送前的密码拦截弹层（11.6）：一键存进保险箱并换成引用，或坚持发送 |
| `unsupported(feature)` | 协议里先加了、client-core 还没导出的方法才会抛（11.7 合入后现在没有这种方法）；界面显示“这个功能还没开放”，不给重试 |
| 其他 | 通用错误提示，带“复制详情” |

接口的说明（ThinktinCore 里 339e191 起叫 `detail`，ThinktinKit 的 `ClientError` 里还叫 `message`）是英文、给开发者看的，
界面显示按错误码本地化的文案（`ClientError.localizedMessage`，横幅经 `ErrorPresentation`）。服务端以后还会加错误码：
client-core（11.9 起）把不认识的码原样放进 `Api.code`，ThinktinKit 里是 `APIErrorCode.unknown(原文)`，不会当成解析失败。
界面怎么处理（`recovery`、文案）：`*_limit` 按数量上限；别的按 HTTP 状态归到上表认识的码（`APIErrorCode.handling(status:)`，
docs/i18n.md 第 3 节“不认识的按状态给通用文案”）：404 / 410 当不存在、409 当冲突、400 / 422 当填写不对、403 当没权限、
429 / 503 稍后再试，其余（包括 401，登录失效由 client-core 按码判断）是通用错误。码本身原样留着，`isNotFound` 这类判断、
能不能重试（`isRetryable`，和 client-core 一样只看码）不受影响。IM 渠道、保险箱条目、实时活动的上限现在还是 422 `invalid`，
以后改成 `*_limit` 时自动走上面那一行。

## 6.1 深链与推送

和安卓端（[docs/android-design.md](android-design.md) 第 3 节）用同一套深链，推送点击、收件箱跳转、实时活动都走它：
`thinktin://run/{id}`、`thinktin://approval/{id}`、`thinktin://plan/{id}`、`thinktin://inbox`（可带 `/{id}`）、
`thinktin://vault/request/{id}`、`thinktin://instance/{id}`；小组件还用 `thinktin://approvals`（审批中心，安卓也认）和
`thinktin://active`（进行中，只有 iOS 有这一页）。电脑上的配对二维码 `thinktin-pair:v1?…`（12.9）也注册了：
用系统相机扫到时打开 App，弹出配对（`.pairComputer`，配对码填好），和安卓一样。推送 payload 里的字段（收件箱 id、运行 id、审批 id）由服务端
`notify` 定义，两端共用。Universal Links 等上线前再配。

实现在 `ThinktinKit/Navigation`（12.16）：`DeepLink` 解析深链（认不出的格式、多余的路径段、不像 id 的 id 一律不认），
`PushPayload` 解析推送的 `userInfo`（`tt` 下的 `kind`、`subtype`、`instance`、`run`、`approval`、`plan`、`inbox`、`vault_request`，
约定见 backend-core 的 docs/push.md 第 3、4 节），`Router` 跳转；推送送达、点开都先交给 `AppModel.receive(push:)` / `open(push:)`。规则：

- 深链和推送打开后，返回栈是“根（当前实例的对话）→ 目标页”，和安卓的冷启动一致；`thinktin://instance/{id}` 打开实例详情
  （安卓也是实例设置页），并把它设成当前实例。
- 推送去哪：审批 → 审批详情（没有审批 id 时运行详情，再没有就是审批中心）；运行完成 / 失败 → 运行详情（没有运行 id 时实例的对话，
  再没有就是收件箱里的那一条）；保险箱请求（`vault_request`）→ 填写请求页（`.vaultRequest`，没有请求 id 时同运行完成）；计划待确认
  （`plan_confirm`）→ 计划确认页（`.confirmPlan`，没有计划 id 时计划列表）；其他提醒 → 先看子类型（`approval_skipped` 去运行详情，
  `im_channel_disabled` 去 IM 渠道设置），再按计划 → 运行 → 实例的对话 → 收件箱里的那一条 → 收件箱，取第一个有 id 的。推送里有实例 id
  时顺带切到这个实例。点开后 `AppModel.open(push:)` 把 `PushPayload.inboxItemID` 那一条标已读（12.8）。
- 推送的系统回调（12.8）在 App 的 `AppDelegate`（`@UIApplicationDelegateAdaptor`，`AppEnvironment` 也由它建，冷启动点开通知时
  回调可能比界面先到）：启动时设通知中心的代理、登记通知类别（`PushCategory`，docs/push.md 第 2 节，只有 `APPROVAL` 有“拒绝”按钮）、
  登录之后（同意了隐私政策，12.17）每次启动都向 APNs 注册（不等用户允许通知，令牌先拿到；`ThinktinApp` 跟着 `AppModel.phase`）；设备令牌交给 `AppModel.didReceivePushToken`（登录着就 `setPushToken`，
  同一个不重复报，没登录时登录带上）；前台送达的照样显示横幅，`receive(push:)` 后刷新角标；点通知上的“拒绝”调
  `AppModel.rejectFromNotification`（查一次审批，还待处理才选拒绝选项，不用本机验证、不打开 App）。请求通知权限
  （`SystemPushRegistrar.register()`）在用到时才做：引导的最后一步（12.17，`\.notificationAuthorizer`）。
- 角标和已送达的通知（`DeliveredNotifications`，App 里是 `UNUserNotificationCenter`）：App 图标的角标跟着收件箱的未读数；
  退出登录、换账号时清掉已送达的通知、角标设成 0（推送里没有用户 id）。推送不带 `content-available`，没有后台模式。
- 子类型（`NotificationSubtype`，开放字符串，收件箱条目的 `subtype` 同一套）：`account_frozen` 显示冻结页；`account_restored` 重查账号、
  重新订阅事件流、同步收件箱；`stopped_all` 刷新角标；都在 `AppModel.receive(push:)` 里，各功能不用管。
- 推送通道：Debug 构建（开发证书签名，`aps-environment` 是 development）报 `apns_sandbox`，Release 报 `apns`
  （`AppConfiguration.usesAPNsSandbox`、`PushRegistration.forThisBuild(deviceToken:)`）。
- 没登录、冻结、要升级时深链和推送先记下（`Router.pendingRoute`），回到正常状态再跳，同一条只跳一次。

## 6.3 小组件与快捷指令（12.20）

- **主屏、锁屏小组件**（`ThinktinWidgets`，小号、中号、锁屏长方形）：未读、待审批、进行中三个数。扩展不连服务端、不带客户端核心，
  只读 App 写进 App Group（`group.cn.thinktin.Thinktin`，两个 target 的 entitlements）的快照 `widget-snapshot.json`
  （`WidgetSnapshot`，只有几个数和时间，没有任务原文、实例名：锁屏谁都看得见）。`AppModel` 在角标变了、退出登录、启动时没登录时写
  （数没变不重写；一个接一个写，后写的不被先写的盖掉），App 的 `AppGroupWidgetSink` 写完让 WidgetKit 刷新。扩展每半小时自己再读一次
  （“几分钟前更新”）。文案跟着系统语言（扩展读不到 App 里选的语言）。点小组件打开收件箱，中号的三格各自深链到收件箱、审批中心、进行中。
- **快捷指令和 Siri**（App 的 `Intents/`）：全部停止、查待审批数、给实例下任务、暂停 / 恢复计划；逻辑在 ThinktinKit 的 `QuickActions`
  （有测试），App Intents 只是外壳。都在 App 的进程里跑（快捷指令在后台拉起 App，不打开界面），和界面共用 `AppEnvironment.shared`
  的同一个客户端，所以不用把 Keychain 里的会话、缓存库共享给扩展；做完刷新角标，小组件跟着变。下任务时任务里像有密码或 key 就不发
  （快捷指令里弹不了拦截面板，要在 App 里先存进保险箱）。“全部停止”不再问一遍：它是急停按钮。标题、参数名、短语是中文，英文在
  `Localizable.xcstrings`、`AppShortcuts.xcstrings`；做完说的话跟着 App 里选的界面语言（`QuickActionText`）。
- **没做的**：控制中心的“全部停止”（iOS 18 的 `ControlWidget`，按钮的意图在扩展的进程里跑，要把会话放进共享的 Keychain 访问组、
  扩展里另建客户端，等最低版本升到 iOS 18 或真要做时再说）；分享扩展（docs/ios-packages.md 12.20 一节提过，WBS 没列）。

## 6.4 实时活动（12.10）

约定见 backend-core 的 docs/live-activities.md（类型名 `RunActivityAttributes`、驼峰键名、Unix 秒）。

- **属性**：`apps/apple/Shared/RunActivityAttributes.swift`，App 和 `ThinktinWidgets` 两个 target 都编它（project.yml 的
  `sources` 里都有 `Shared`）；`ContentState` 就是 ThinktinKit 的 `RunActivityContentState`。App 的 Info.plist 有
  `NSSupportsLiveActivities`。
- **逻辑**在 ThinktinKit 的 `LiveActivityModel`（`AppModel.liveActivities`，Linux 上有测试），系统那一侧藏在
  `LiveActivityControlling` 后面；App 的 `SystemLiveActivities` 用 ActivityKit 实现它，并把推送令牌（`pushTokenUpdates`）、
  用户划掉（`activityStateUpdates`）、远程开启的新活动（`activityUpdates`）、推送开启令牌（iOS 17.2 起）转给模型。
  - 自己发的任务（`ObservedClient` 看到 `sendMessage` 成功，报 `ClientActivity.runStarted`）自动开，设置里能关；运行页上
    “在锁屏上显示”手动开。只开根运行。
  - 拿到令牌就 `registerLiveActivity`；服务端拒绝（运行结束 10 分钟以上、不是自己的）就在本地马上结束。用户划掉了
    `endLiveActivity`。启动、回到前台（`AppModel.sceneDidBecomeActive`）、登录后 `resume()`：对一遍开着的、令牌再报一次。
  - 前台跟事件流（每个有实时活动的实例一条）：状态马上变，每个工具调用加一步（子运行的步数等后台推送，推过来的数是准的），
    运行结束在本地结束；进后台（`sceneDidEnterBackground`）停掉，靠后台推送。
  - 设置里“计划运行时也显示”（默认关）：打开才把推送开启令牌报给服务端，关掉时清掉；报过的记在 `UserDefaults`，不重报，
    失败了下次 `resume` 再报。
  - 退出登录、换账号：开着的都在本地马上结束（标题是上一个账号的实例名）。
- **界面**（`ThinktinWidgets/RunLiveActivity.swift`）：锁屏横幅和灵动岛只有实例名、状态（和对话里的状态行同一套说法，
  `LiveActivityText`）、步数、耗时（还在跑的用 `Text(timerInterval:)`，不用推送也会走）；等审批、key 要处理时图标是橙色。
  点开去运行详情。

## 6.5 手机控制电脑（12.9）

协议见 docs/pairing.md（配对、审批、能力令牌；消息经设备中继，第 6 节的正文格式），手机这边：

- **逻辑**在 ThinktinKit 的 `ComputerLinkModel`（`ViewModels/Computer/`，Linux 上有测试）：编码、验签藏在 `PairingCodec`
  后面（适配层的 `CorePairingCodec` 调 client-core，测试向量和 Rust 一致），签名藏在 `DeviceSigner` 后面（App 的
  `SecureEnclaveSigner`）。状态按账号存在 `UserDefaults`：配好的电脑（电脑公钥、配对时手机的公钥）、等确认的配对、收下的审批请求
  （服务端收下就确认掉了，处理了或过期了再删）、签发过的令牌。
- **配对**：设置 → 登录设备 → 电脑 → 配对：扫码（VisionKit，`PairingCodeScanner`；不能扫时粘贴配对码）→ 确认是自己账号的电脑 →
  面容 ID 签配对回复（`pair_response`）→ 每 3 秒收一次消息等电脑的确认（`pair_confirm`，用二维码里的电脑公钥验）→ 记下电脑。
  邀请过期还没等到算失败。
- **审批**：电脑的高危操作（`approval_request`，推送 `computer_approval` 打开审批中心）在审批中心最上面一组：说明（AI 生成）、
  工具、参数；批准、拒绝都要面容 ID 签名（`approval_decision`）。只收配好的电脑发来的、没过期的。
- **能力令牌**：配好的电脑右边“更多”→ 授权目录和应用（完整路径、bundle id、有效期 1 小时到 7 天）→ 签名发过去（`capability`）；
  列表里随时吊销（`revocation`，不用签名）。解除配对时先吊销发给它的令牌。
- **密钥**：Secure Enclave 的 P-256（`.biometryCurrentSet`），句柄存 Keychain。录入了新面容（生物识别的登记状态变了）就失效，
  页面提示生成新密钥、重新配对。没有 Secure Enclave（模拟器）或没设生物识别时不能签，页面说明原因。
- 电脑那边（14.8，macOS App）还没做：要照 docs/pairing.md 第 6 节显示二维码、验 `pair_response`、回 `pair_confirm`。

## 6.2 离线时每个页面怎么显示

client-core 只缓存实例、运行、事件、收件箱（cache.rs 的几张表）。所有页面用同一个离线横幅（`AppShell` 统一放在页面顶部，
文案按 `AppRoute.offlinePolicy`），离线时写操作一律禁用，只有收件箱标已读例外（先在本地生效，联网后补发）。

| 策略 | 页面 | 横幅 |
|---|---|---|
| 有缓存（`cached`） | 首页、实例对话、运行详情、运行树、进行中、实例详情、收件箱 | “离线，显示的是缓存内容” |
| 没有缓存（`unavailable`） | 计划、审批、模型 key、模型路由、用量、保险箱、团队、agent 目录、产出物、IM 渠道、登录设备、账号 | “离线，暂无数据。联网后会自动刷新。”，页面显示空状态 |
| 不用联网（`local`） | 设置中心、关于、开源许可、搜索（只搜本机缓存）、登录、冻结页、升级页 | 不显示 |

退出登录和注销都会清掉缓存，换账号后不能显示上一个账号的数据（`AppModel` 同时清掉实例、角标和导航）。

## 7. 构建与测试

- **本机（macOS）**：`brew install xcodegen`，`tools/client-core/build-apple.sh target/apple`，`cd apps/apple && xcodegen generate`，
  打开 `Thinktin.xcodeproj`。
- **Linux / 云端会话**：`tools/client-core/build-linux-swift.sh target/linux`，然后 `cd apps/apple/ThinktinKit && swift test`
  （只编译 Linux 能编的目标，`Package.swift` 里按 `os(Linux)` 排除 `ThinktinUI`）。
- **CI（`.github/workflows/ios.yml`）**：
  1. `kit-linux`（ubuntu）：装 Swift，构建 client-core，生成 Linux 包，`swift test`；
  2. `app-macos`（macos-26，Xcode 26）：`build-apple.sh --ci` 只编模拟器和 macOS 的 arm64 两个切片打 xcframework（省时间）；
     `swift build --build-tests` 整个 `ThinktinKit`（含 ThinktinUI）；`xcodegen generate`；挑一个不高于所选 Xcode 模拟器 SDK 的 iPhone，
     `xcodebuild test` 跑 App 的 `ThinktinTests` 和 `ThinktinUITests`；最后 macOS 本机 `swift test`（适配层经 macOS 切片跑一遍）。日志传成 artifact。
  `kit-linux` 最后还有严格模式的 `swift format lint`。
- 代码风格：`swift format`（Swift 6 工具链自带），配置在 `apps/apple/.swift-format`（App 和 ThinktinKit 共用，4 格缩进、120 列、
  其余是 swift-format 6.2 的默认规则全量导出）。CI 跑严格模式的 lint，**提交前先 `swift format -i -r apps/apple`**。
- **Linux 上检查界面代码**：`tools/apple/uicheck/run.sh`（`appkit` 查 macOS 路径，`test` 顺带跑 ThinktinUITests；UIKit 版连 App target 和
  小组件扩展一起查）。SwiftUI、UIKit、AppKit、Security、OSLog、UserNotifications、Charts、WidgetKit、AppIntents、ActivityKit 换成桩模块（签名照 iOS 17 / macOS 14 SDK），能发现类型错误和并发检查问题，代替不了 macOS CI 的真实编译。
  桩模块缺 API 时照 Apple 文档补进 `tools/apple/uicheck/Stubs/`，不要为了过检查改 App 代码。写完界面推送前跑一遍。
  `prep.py` 把 ThinktinUI 里 `#if` 行的 `os(iOS)` / `os(macOS)` 换成 `canImport(UIKit)` / `canImport(AppKit)`：UIKit 版查 iOS
  分支、AppKit 版查 macOS 分支（之前 Linux 上两个都是假，只查了 `#else`）。只有 iOS 有的接口在桩里放进 `#if canImport(UIKit)`。

## 8. 工作包与开发顺序

12.x 共 23 个工作包（WBS 2026-10-22 细化，见 [wbs.md 第 12 节](wbs.md)），每个包做的时候要注意的事（页面清单、边角情况、依据）
在 [ios-packages.md](ios-packages.md)。开发顺序：

| 波次 | 内容 |
|---|---|
| W0 | 合 `backend-core`（带进 11.7），收尾 12.1：适配层接上 11.7 的接口、设计令牌与基础组件、测试、CI 跑绿；之后 12.1 的公共文件（`ClientProtocol`、模型、`Theme`）只加不改 |
| W1 | 四条线并行，每条线只改自己的功能目录：A 12.16 → 12.2 → 12.12 → 12.17；B 12.3 → 12.4 → 12.8；C 12.5 → 12.18；D 12.6 → 12.7；12.15 由先空下来的线做 |
| W2 | 12.13、12.10（等 10.6）、12.20、12.21、12.19；P3 的 12.9 随 macOS（14.5 起）；12.11 最后做（还要等 16.1、16.2） |
| 待拍板 | 12.22 运行附件、12.23 App 内购买（等 1.1） |

## 9. 工作包与目录的对应

| 工作包 | ThinktinKit（纯 Swift） | ThinktinUI（SwiftUI） |
|---|---|---|
| 12.1 | `Models/`、`Client/`、`Conversation/`、`Formatting/`、`Support/` | `Design/`、`Components/`、`RootView.swift` |
| 12.16 | `Navigation/`（路由、深链、推送解析、`Router`）、`ViewModels/Shell/`（`AppModel`、`ObservedClient`） | `Shell/`（`AppShell`、抽屉、实例切换、全局横幅、冻结页、升级页、占位页） |
| 12.2 | `ViewModels/Account/` | `Screens/Account/`（登录、设备、注销） |
| 12.3 | `ViewModels/Agents/` | `Screens/Agents/`（目录、领养、实例详情） |
| 12.4 | `ViewModels/Models/` | `Screens/Models/`（key、路由、用量） |
| 12.5 | `ViewModels/Conversation/` | `Screens/Conversation/`（首页、时间线、输入框、事件卡片、运行详情、运行树、进行中） |
| 12.6 | `ViewModels/Plans/` | `Screens/Plans/` |
| 12.7 | `ViewModels/Teams/` | `Screens/Teams/`（团队、团队模板、流水线编辑器；运行树用 12.5 的，补流水线节点） |
| 12.8 | `ViewModels/Inbox/` | `Screens/Inbox/`；推送注册在 App 的 `Platform/` |
| 12.12 | `ViewModels/Settings/` | `Screens/Settings/`（设置中心、开源许可、关于） |
| 12.13 | `ViewModels/Vault/` | `Screens/Vault/` |
| 12.14 | `ViewModels/ImChannels/` | `Screens/ImChannels/` |
| 12.15 | `ViewModels/Approvals/` | `Screens/Approvals/`（审批卡组件给 12.5 嵌入） |
| 12.17 | `ViewModels/Onboarding/` | `Screens/Onboarding/` |
| 12.18 | `ViewModels/Artifacts/` | `Screens/Artifacts/` |
| 12.21 | `ViewModels/Search/` | `Screens/Search/` |
| 12.20 | `ViewModels/Widgets/`（快照、`QuickActions`） | App 的 `Intents/`、`Platform/WidgetSnapshotWriter.swift`；`ThinktinWidgets/`（Widget Extension） |
| 12.10 | `ViewModels/LiveActivities/`（`LiveActivityModel`、`LiveActivityText`） | `Screens/Settings/LiveActivitySettingsSection.swift`（设置里的一组、运行页的按钮）；App 的 `Platform/SystemLiveActivities.swift`、`Shared/`；`ThinktinWidgets/RunLiveActivity.swift` |

每个工作包的测试放在对应的 `Tests/ThinktinKitTests/<功能>/`（视图模型，Linux 能跑）和 `Tests/ThinktinUITests/<功能>/`（只在 macOS 跑）。

### 9.1 接入点：各功能只改自己的目录（12.16 起）

应用框架（12.16）把所有页面都定义成 `AppRoute`（`ThinktinKit/Navigation/AppRoute.swift`），每个页面属于一个功能
（`AppRoute.feature` → `AppFeature`）。每个功能有一个接入点文件 `ThinktinUI/Screens/<功能>/<功能>Destination.swift`：

```swift
struct PlansDestination: View {
    let route: AppRoute          // .plans、.plan(id)、.newPlan(instanceID:)、.editPlan(id)
    var body: some View { … }    // 按 route 分派到本目录里的页面
}
```

`AppShell` 的导航栈根、`navigationDestination(for: AppRoute.self)`、sheet 都经过 `Shell/AppDestination.swift`，按 `route.feature`
交给对应的接入点，并在页面顶部统一放连接横幅和离线横幅。做一个功能时：

1. 只改 `Screens/<功能>/`、`ViewModels/<功能>/`、`Tests/ThinktinKitTests/<功能>/`、`Tests/ThinktinUITests/<功能>/` 里的文件，
   把接入点的占位页（`DestinationPlaceholder`）换成真页面；不改 `Shell/`、`Navigation/`、`RootView.swift`。
2. 环境里取全局状态和工具：`@Environment(AppModel.self)`（当前实例、实例列表、角标、离线、`refreshBadges()`）、
   `@Environment(Router.self)`（跳转）、`@Environment(\.client)`（调接口）。视图模型照常 `init(client: any ClientProtocol)`，
   传进去的就是环境里的这个。
3. 跳到别的功能的页面：`router.open(.run(id))`（按 `presentation` 压栈 / 弹 sheet / 回到根，会关掉抽屉和 sheet），或
   `NavigationLink(value: AppRoute.run(id))`。打开 `.conversation(id)` 等于切换当前实例、回到根。sheet 页（`.newPlan`、`.editPlan`、
   `.addCredential`、`.onboarding`、`.newTask`）自带导航栈，关掉用 `router.dismissSheet()`。
4. 只在本功能里用、不要深链的子页面（向导的第二步、选择器）不用加 `AppRoute`：在自己的目录里用
   `NavigationLink { 子页面 } label: { … }` 或本地 sheet。要跨功能跳转、要深链的页面才加 case，那是 `Navigation/` 的改动，
   在合并时统一加（加了 case 要补 `feature`、`presentation`、`offlinePolicy`、`title`，`AppRouteTests` 会逐个检查）。
5. 错误：页面只管行内错误（`ErrorBanner`）。登录失效、冻结、要升级不用处理：环境里的客户端是 `ObservedClient`，任何调用遇到
   这些错误都会报给 `AppModel` 切换整页状态；`login` 成功、`logout` / `deleteAccount` / 下线本机之后也会自动切换（12.2 的登录页
   调完 `client.login(...)` 就行）。事件流照常 `client.subscribe(...)`，连接状态会自动汇总成顶部的横幅。
6. 对话页（12.5）的根有导航栏的抽屉按钮和实例切换菜单（`AppShell` 加的），页面自己的按钮放 `.primaryAction`；
   `router.newTaskRequest` 变了时把焦点放进输入框（抽屉里的“新任务”）。
7. 预览用 `.previewShell()`（`.previewShell(.english, scheme: .dark)`）：放进导航栈，注入 Mock 客户端的 `AppModel`、`Router`。
   界面测试的工具在 `Tests/ThinktinUITests/UITestSupport.swift`（`renderInBothAppearances`、`hostAndLayout`）。

`ObservedClient` 要转发 `ClientProtocol` 的每个方法：协议加了方法（比如合 11.8），`ViewModels/Shell/ObservedClient.swift` 要加对应的
一行转发，不加编译不过。

### 9.2 外观与界面语言（12.12）

- 偏好在 `ThinktinKit/ViewModels/Settings/SettingsPreferences.swift`：`SettingsPreferences`（`@Observable`，存 UserDefaults，只是本机的
  显示偏好）有外观（跟随系统 / 浅色 / 深色）和界面语言（跟随系统 / 中文 / English，`displayLanguage` 是实际用的）。App 用
  `SettingsPreferences.shared`；预览、测试 `SettingsPreferences(defaults: nil, systemLanguage: { … })` 只放内存。
- 生效：ThinktinUI 的 `.settingsPreferences()`（`Screens/Settings/SettingsEnvironment.swift`）按外观设 `preferredColorScheme`、按
  界面语言设 `\.displayLanguage`，并把偏好放进环境给设置页。它套在 App 的 `WindowGroup` 里 `RootView(model:)` 上
  （`Thinktin/App/ThinktinApp.swift`），不放进 `RootView` / `AppShell`：预览和界面测试要自己设 `\.displayLanguage` 和深浅色
  （`.previewShell(.english, scheme: .dark)`），放在里面会被盖掉。页面里取界面语言照旧用 `@Environment(\.displayLanguage)`。
- 和服务端同步：`AppModel(client:preferences:)`（App 的 `AppEnvironment` 传 `.shared`，测试、预览不传就不同步）在 `start()` 最开头
  （登录判断之前）调 `LanguageSettingsModel.applyAcceptLanguage()`，新用户按界面语言注册；确认完账号（`me()`）、登录成功、解冻之后各调一次
  `syncOnLaunch(user:)`，`me().locale` 和界面语言不一致才调 `setLocale`，静默进行，失败不挡启动；启动时 `me()` 没拿到（离线）就不同步，
  不再多等一次 `me()`。设置页换语言由 `LanguageSettingsModel.select(_:)` 同步。
- `AppModel.user` 跟着最新的走：任何页面调 `me()`、`setLocale`、`updateProfile` 成功后，`ObservedClient` 报 `.userUpdated`，同一个账号
  还登录着就换上。设置页每次进语言页都按它新建 `LanguageSettingsModel(user:)`：用旧的用户会以为服务端还是原来的语言，换回来时不调
  `setLocale`。
- 建客户端时的 `Accept-Language`：`AppEnvironment.acceptLanguage(displayLanguage:)` 用 `SettingsPreferences.shared.displayLanguage`
  打头，后面跟设备的语言偏好，照 client-core 的规则截到 256 字节内（`AcceptLanguage.header`）。
