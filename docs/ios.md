# iOS App 工程说明（WBS 12.x）

> 更新日期：2026-10-22　｜　分支 `ios-app`　｜　进度见 [docs/progress/ios-app.md](progress/ios-app.md)

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
    Platform/                 Keychain 会话存储、APNs、LocalAuthentication、Secure Enclave、实时活动、深链
    Resources/                Assets.xcassets、Localizable.xcstrings、PrivacyInfo.xcprivacy、Info.plist 补充项
    Thinktin.entitlements
  ThinktinKit/                Swift Package（iOS / macOS 共享）
    Package.swift
    Sources/ThinktinKit/      纯 Swift：Models、Client（ClientProtocol、MockClient）、ViewModels、Formatting、Conversation（事件归并）
    Sources/ThinktinUI/       SwiftUI：Design（令牌、组件）、Screens（按功能分目录）、Previews
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
| 平台层 | `Thinktin/Platform` | 系统能力的实现，注入给视图模型（协议化：`PushRegistrar`、`BiometricSigner`、`LiveActivityController`） | 仅 iOS |

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
| `agent.permission_requested` / `agent.permission_resolved` | `{request_id, title, options, tool_call}` / `{request_id, option_id, by}` | 审批卡片：未决时显示选项按钮（调 `decide_approval`），已决显示结果和由谁决定（用户 / 策略 / 超时） |
| `vault.requested` / `vault.fulfilled` / `vault.declined` | `{request_id, name, purpose, fields}` | 保险箱表单卡片（填账号密码，只进保险箱）；已处理显示结果 |
| `run.state` | `{state, reason, attempt}` | 运行状态行：等待类状态显示原因和下一步（去配 key、去审批、等电脑上线） |
| `artifact.published` | `{artifact_id, name, version, size}` | 产出物卡片，点开预览 / 分享 |
| `pipeline.step_started` / `delegate.started` | `{step, run_id, instance_id}` / `{child_run_id, instance_id, to, title}` | 子运行链接卡片，进运行树 |
| `plan.needs_confirmation` | `{plan_id, title, change}` | “agent 新建 / 修改了计划，待确认”卡片，跳到计划页 |
| `plan.cancelled` | `{plan_id, title}` | “agent 取消了计划 X”系统行 |
| `instance.state` | `{state}`，没有 `run_id` | 不进时间线：更新对话页页头和抽屉里的实例状态（“正在唤醒”，已归档的从模板重建会慢一些） |
| `approval.decided` | `{approval_id, state, option_id}` | 更新对应的审批卡（按运行关联，见 ios-packages.md 12.15） |
| `vault.used` / `agent.vault_reveal` | `{names}` / `{call_id, refs}` | “用了保险箱里的 github”提示行（只有名字） |
| `agent.usage`、`agent.turn_started`、`agent.turn_ended`、`agent.ready`、`agent.update` | — | 不进时间线（`turn_ended` 结束流式状态，`stop_reason` 为 refusal / max_tokens / max_turn_requests 时显示提示行；`usage` 显示在运行详情） |
| `agent.error`、`agent.session_lost`、`agent.exited`、`run.log_truncated` | `{message}` 等 | 系统提示行 |

- 事件流的回调在后台线程，视图模型切回主线程再更新。
- `on_reset(oldest_seq, latest_seq)`：本地事件作废，清空后从 `cached_events` / 服务端重新加载。
- `StreamStatus`：`connecting` / `reconnecting` 在顶部显示细条；`signed_out` 回登录页；`account_frozen` 显示冻结页；`not_found` 回实例列表。

## 6. 错误处理

`ClientError`（UniFFI 枚举）在适配层转成 Swift 的 `ClientError`，界面按它决定做什么：

| 错误 | 处理 |
|---|---|
| `SignedOut` | 清状态、回登录页 |
| `AccountFrozen` | 冻结提示页（保留登录态，解冻后照常） |
| `UpgradeRequired` | 全屏“请升级”，带 App Store 链接 |
| `Api(status, code, …)` | `rate_limited` 按 `retry_after_secs` 提示；`conflict` 刷新后重试；`invalid` 显示表单错误；`not_found` 回上一级 |
| `Network` | 行内可重试的提示；列表页显示缓存数据并标“离线” |
| `ContainsSecrets(count)` | 发送前的密码拦截弹层（11.6）：一键存进保险箱并换成引用，或坚持发送 |
| `Unsupported(feature)` | 只在 Swift 侧有：client-core 还没导出的方法（11.7 落地前）由 `CoreClient` 抛出，`MockClient` 照常实现。提示“暂未开放”、不重试（`ErrorRecovery.featureUnavailable`），入口最好直接隐藏或置灰 |
| 其他 | 通用错误提示，带“复制详情” |

接口的 `message` 是英文、给开发者看的，界面显示按错误码本地化的文案。

## 6.1 深链与推送

和安卓端（[docs/android-design.md](android-design.md) 第 3 节）用同一套深链，推送点击、收件箱跳转、实时活动都走它：
`thinktin://run/{id}`、`thinktin://approval/{id}`、`thinktin://plan/{id}`、`thinktin://inbox`（可带 `/{id}`）、
`thinktin://vault/request/{id}`、`thinktin://instance/{id}`。推送 payload 里的字段（收件箱 id、运行 id、审批 id）由服务端
`notify` 定义，两端共用。Universal Links 等上线前再配。

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
- **Linux 上检查界面代码**：`tools/apple/uicheck/run.sh`（`appkit` 查 macOS 路径，`test` 顺带跑 ThinktinUITests）。SwiftUI、UIKit、AppKit、
  Security、OSLog 换成桩模块（签名照 iOS 17 / macOS 14 SDK），能发现类型错误和并发检查问题，代替不了 macOS CI 的真实编译。
  桩模块缺 API 时照 Apple 文档补进 `tools/apple/uicheck/Stubs/`，不要为了过检查改 App 代码。写完界面推送前跑一遍。

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
| 12.16 | `Navigation/`（路由、深链解析、全局状态） | `Shell/`（抽屉、实例切换、全局横幅） |
| 12.2 | `ViewModels/Account/` | `Screens/Account/`（登录、设备、注销） |
| 12.3 | `ViewModels/Agents/` | `Screens/Agents/`（目录、领养、实例详情） |
| 12.4 | `ViewModels/Models/` | `Screens/Models/`（key、路由、用量） |
| 12.5 | `ViewModels/Conversation/` | `Screens/Conversation/`（时间线、输入框、事件卡片、运行详情） |
| 12.6 | `ViewModels/Plans/` | `Screens/Plans/` |
| 12.7 | `ViewModels/Teams/` | `Screens/Teams/`（团队、流水线编辑器、运行树） |
| 12.8 | `ViewModels/Inbox/` | `Screens/Inbox/`；推送注册在 App 的 `Platform/` |
| 12.12 | `ViewModels/Settings/` | `Screens/Settings/`（设置中心、开源许可、关于） |
| 12.13 | `ViewModels/Vault/` | `Screens/Vault/` |
| 12.14 | `ViewModels/ImChannels/` | `Screens/ImChannels/` |
| 12.15 | `ViewModels/Approvals/` | `Screens/Approvals/`（审批卡组件给 12.5 嵌入） |
| 12.17 | `ViewModels/Onboarding/` | `Screens/Onboarding/` |
| 12.18 | `ViewModels/Artifacts/` | `Screens/Artifacts/` |
| 12.10、12.20 | — | App 的 Widget Extension target（`project.yml` 里另起 target） |

每个工作包的测试放在对应的 `Tests/ThinktinKitTests/<功能>/`（视图模型，Linux 能跑）和 `Tests/ThinktinUITests/<功能>/`（只在 macOS 跑）。
