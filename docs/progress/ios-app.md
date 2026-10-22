# ios-app

目标：iOS App（WBS 12.x）。Swift + SwiftUI 原生开发，界面参考 Claude iOS App 的信息架构与视觉；iOS / macOS 共享 `ThinktinKit`；经 UniFFI 调 `crates/client-core`（`ThinktinCore` Swift 包，由 `tools/client-core/build-apple.sh` 打出）。分支从 `backend-core`（`82b60b5`）切出，后端接口以那里为准。

认领：iOS 会话（session_01GuCp3KRgqaK6Kzynw6udRn）在做，2026-10-22 01:10 起（北京时间）。12.x 全部由本分支负责；`backend-core` 会话请不要重做 12.x。client-core（11.x）接口如有变动，请在 `docs/progress.md` 里记一句，本分支定期合 `backend-core`。

已完成：
- 分支与进度文件（本文件）。
- `tools/client-core/build-linux-swift.sh`：Linux 上的 ThinktinCore Swift 包（同一份 UniFFI 绑定，链本机 `libclient_core.so`），云端会话能编译、测试 ThinktinKit 的纯 Swift 部分和适配层。
- `docs/ios.md`：工程说明（目录、分层、设计令牌、事件归并规则、错误处理、深链、构建与 CI）。
- `docs/gen_wbs.py`：补回 1.6、9.11、9.12、11.6、13.12 五行（逐字照 wbs.md），重新生成 wbs.md / wbs.csv。
- WBS 细化（`21a824f`）：12.x 从 11 个包 54 人日细化为 23 个包 114 人日（P1 89）；后端前置 4.7、5.5、5.6、10.6、10.7、11.7、11.8；每包的实现要点在 `docs/ios-packages.md`，开发顺序和目录分工在 `docs/ios.md` 第 8、9 节。
- 12.1（`66ebc7e`，macOS CI 待确认）：ThinktinKit（模型、ClientProtocol、ClientError、MockClient、ConversationReducer、格式化）、ThinktinCoreAdapter（CoreClient、桥接）、ThinktinUI（设计令牌、基础组件、欢迎页 RootView）、XcodeGen 工程与 App 骨架（Keychain 会话、隐私清单、文案表）、`.github/workflows/ios.yml`（Linux + macOS 两个作业）、`apps/apple/.swift-format`、`tools/apple/uicheck`（Linux 上用桩 SwiftUI 类型检查界面和 App 代码）。Linux 上 187 个测试通过，严格格式检查干净。
- 合进 backend-core（`a4e8ba2`、`d448aeb`）：带进 11.7（33 个新方法）、10.6（实时活动，含评审修复）、4.7（审核账号，App 不用改）、5.5（内容举报）。
- iOS CI 第一次全绿（run 39720152852，`b015212`）：Linux 作业、macOS 上 Xcode 26.6 编 App 和模拟器测试都通过。
- 合进 backend-core 的 11.8 前半（`ccf928f`）：listRuns、cachedEventsBefore、setAcceptLanguage、upgradeRequired、日志接口、Run.waitCode、Credential.activeProtocol、AgentInfo 的介绍 / 上游 / 许可说明；现有代码不用改就能编。
- 11.7 / 10.6 / 5.5 接入：ThinktinKit 新模型（设备、设备消息、结构化计划策略、计划修改、补跑、团队与模板、内容举报、实时活动限制），ClientProtocol 共 97 个方法，MockClient 全部实现并按服务端规则校验；CoreClient 全部接上真实核心，不再有 `unsupported`；Linux 上 277 个测试通过，严格格式检查、uicheck 两种都过。审查修了一处：下线本机时设备 id 按大小写比较，没退出本地登录。
- 12.16 应用框架与导航（W1 第一轮）：`ThinktinKit/Navigation`（`AppRoute` 41 个页面及其功能 / 出现方式 / 离线策略 / 中英文标题，`DeepLink`、`PushPayload`、`Router`）；`ViewModels/Shell`（`AppModel`：登录状态四态、启动先缓存再刷新、角标、冻结重查、强制升级停事件流、连接横幅、离线、当前实例记忆；`ObservedClient`：包住客户端，任何调用的全局错误、登录 / 退出自动切换）；`ThinktinUI/Shell`（`AppShell`：导航栈 + 抽屉 + 实例切换菜单 + 全局横幅 + 冻结页 / 升级页 / 新任务）；14 个功能目录的接入点 `Screens/<功能>/<功能>Destination.swift`（占位页，约定见 docs/ios.md 9.1）；App 的 `onOpenURL` 交给 `Router`。Linux 上 344 个测试通过，uicheck 两种和 `test`（33 个界面测试）都过，严格格式检查干净。

进行中：
- W1 第一轮（工作流 wf_54cd35af-e50；第一次 wf_4136b616-413 被用量限额打断，没留下改动）：11.8 接入（worktree，分支 `ios-w1/11.8`）和 12.16 应用框架同时做，合并后再（路由、深链、抽屉、全局状态、每个功能目录的 `XxxDestination` 接入点），然后 12.2、12.3、12.5、12.6 在各自的 git worktree 里并行，分别提交到 `ios-w1/12.2-account`、`ios-w1/12.3-agents`、`ios-w1/12.5-conversation`、`ios-w1/12.6-plans`，由本会话合并回 ios-app。
- iOS CI 第一次完整跑（run 39687813304，`66ebc7e`）的结果：Linux 作业全绿；macOS 上 Rust 交叉编译与打包（约 9 分钟）、真实 SwiftUI 编译 ThinktinKit + ThinktinUI、xcodegen、Xcode 26.6 编译 App 并在 iPhone 17 Pro 模拟器（iOS 26.5）上跑 App 冒烟测试都通过；214 个测试里只有“抽屉：打开和关闭”失败（关着的抽屉理想宽度本来就是 0，测试断言写错了），已修，随 11.7 接入一起推送。

下一步：
0. W1 第一轮合并后（W1 第 1.5 轮）：合 backend-core（到 2efd3d1 之后：11.8 全部完成）并做：(a) 去掉 `CoreClient.revokeDevice` 的兜底 `logout()`（b61abc5 起 client-core 自己清）；(b) **修 ConversationReducer 的审批卡关联**：shim 每次尝试都从 `perm-1` 重新编号，卡片要按 `(run_id, attempt, request_id)` 认，现在只按 run + request_id 会把第 2 次尝试的审批并到第 1 次的卡片上；`agent.permission_resolved` 的 `approval_state == "expired"` 显示“已过期”而不是“你拒绝了”；attempt 小于运行当前尝试（`run.state` 的 attempt）的待处理卡片作废（规则见 backend-core 的 docs/agent-integration.md 第 6 节）；(c) `Approval` 的 request_id / attempt / decided_option / decided_at_ms、`getApproval`（点旧推送、收件箱进来先查它）；(d) Credential.protocols / AgentInfo.active_protocol（12.4 选 key 要求 credential.protocols 包含 agent.active_protocol）；(e) 计划列表带 triggers / steps / next_fire_at_ms / invalid_triggers、Trigger.disabled_reason = "invalid_rule"（12.6 直接用，不用逐个拉详情）；(f) Run.wait_code 已在第一轮接入，确认 device_offline 也认；(g) 后端约好的破坏性改动（ClientError / PairingError 的 message 改名、StreamStatus 加 UpgradeRequired）一起改适配层。
1. 修 macOS CI 暴露的问题直到全绿，然后 12.1 的公共文件（ClientProtocol、模型、Theme）只加不改。
2. W1 四条线并行（`docs/ios.md` 第 8 节）：A 12.16 → 12.2 → 12.12 → 12.17；B 12.3 → 12.4 → 12.8；C 12.5 → 12.18；D 12.6 → 12.7；12.15 由先空的线做。
3. W2：12.13、12.10、12.20、12.21、12.19；12.11 最后；12.9 随 macOS（P3）。

坑和决定：
- PR：`ios-app` → `main` 的草稿 PR #8（2026-10-22 开，用户授权自行决定）。本会话订阅了它的 CI 和评审事件，负责把它保持在绿色；P1 的 iOS 包完成后转为可审阅，合并要人审。后端 PR #5 合进 main 之前，#8 的差异里带着后端改动。
- `CoreClient.revokeDevice` 下线本机时额外调一次 `core.logout()` 清本地会话和缓存（client-core 的 `revoke_device` 只发 DELETE）；已建议 backend-core 在 client-core 里做，做了之后这行可以删。
- 桩 SwiftUI 的 `sizeThatFits` 总是返回提议的尺寸：界面测试别断言“关着的抽屉宽度是 0”这类尺寸（12.16 换掉旧抽屉时去掉了那条测试）。以 macOS CI 为准。
- 12.16 的决定：`thinktin://instance/{id}` 打开实例详情（和安卓一致），推送只有实例 id 时打开实例的对话；运行树页面归 12.5（委派在 P1 就有），12.7 补流水线节点；“进行中”的数现在逐个实例 `runs()` 再本地过滤，合 11.8 时换成 `listRuns`；事件流以 `stopped` 结束时要查 `upgradeRequired()`（`AppModel.streamChanged` 里留了位置）；`ObservedClient` 要给 `ClientProtocol` 的每个新方法加转发；冻结期间整页显示冻结页（不做只读浏览缓存），解冻后对话页重新出现时重新订阅；App Store 链接（`ShellLinks.appStore`）等 12.11 有了 Apple ID 再填。
- 后端前置包（2026-10-22）：backend-core 已认领 11.8、10.7、4.7、5.5（`docs/progress.md` 7b085b7），顺序 10.6 评审 → 11.8 → 10.7 → 4.7 → 5.5；11.8 顺带做计划列表带下次触发时间、Run / run.state 的结构化等待原因码、跨实例的进行中运行列表。5.6 运行附件等 1.1 拍板。新接口只加不改，做完在 `docs/progress.md` 已完成表里写 FFI 新增了什么，本分支合 backend-core 时接上。
- 12.10 实时活动的约定（backend-core 10.6，83f68ba…39234ba，详见 backend-core 的 `docs/live-activities.md` 第 3 节）：类型名必须是 `RunActivityAttributes`，静态属性 `runId`、`instanceId`、`title`；`ContentState` 是 `state`（运行状态字符串）、`steps`（Int）、`startedAt`、`endedAt`（可选，Unix 秒整数，驼峰键名，ActivityKit 用默认 JSONDecoder 解）。client-core 新方法：`register_live_activity(run_id, token)`（`pushTokenUpdates`，十六进制，变了再调）、`end_live_activity(run_id)`、`set_live_activity_start_token(token?)`（`pushToStartTokenUpdates`，用户打开“计划运行时显示实时活动”才登记，关掉传 nil）；只有 iPhone / iPad 能登记。服务端只远程开启计划到点的根运行，用户自己发起的由 App 自己开；远程开启的在 `Activity<RunActivityAttributes>.activityUpdates` 里拿到后照样 `register_live_activity`。推送里没有摘要和 agent 文字。
- client-core 没导出的接口（设备列表与下线、注销、改计划与触发器、团队与模板、换 key、产出物列表与删除、收件箱删除和标未读、runs 分页）：2026-10-22 backend-core 会话已认领 11.7（P1，记在 `docs/progress.md`，c2c3825；只加不改已有签名，做完一组提交一组）；实时活动推送 10.6（P2）等 11.7 做完再定，在那之前没人认领。两行由本分支加进 `gen_wbs.py`。落地前 Swift 的 `ClientProtocol` 先定义这些方法、`MockClient` 实现、`CoreClient` 抛 `ClientError.unsupported`。
- 安卓会话（session_01T2zubC6hDr9ZZR3ihhPP5b）在分支 `android-app` 做 13.x，设计规范在 `docs/android-design.md`；深链格式、事件 kind → 界面的规则两端保持一致。
- `docs/gen_wbs.py`：只改 `AREAS["12 iOS App"]` 这一块；backend-core 手改进 wbs.md 但没进脚本的五行（1.6、9.11、9.12、11.6、13.12）按 wbs.md 逐字补回脚本（安卓分支也这么补，内容相同）。wbs.md / wbs.csv 是生成物，合并时后合的一方重新跑 `python3 docs/gen_wbs.py docs/wbs.md docs/wbs.csv`，不手工解冲突。
- 云端会话是 Linux，没有 Xcode：SwiftUI 代码靠 GitHub Actions 的 macOS runner 编译和跑测试（每次推送都跑）；纯 Swift 逻辑（模型、视图模型、格式化、状态机）用 Linux 上的 Swift 6.2 工具链本地 `swift test`。
- Xcode 工程不手写 pbxproj，用 XcodeGen 的 `project.yml` 生成（CI 和本机都 `xcodegen generate`）。
- 用量限额：2026-10-21 17:45 前后撞上五小时限额，12.1 骨架工作流的三个 agent 和 WBS 审查者中断，21:33 重置后恢复（已写的文件先按 WIP 提交，`c11a0eb`）。现在有每 3 小时一次的定期检查（`trig_01Wt6oEwQkA7pisCjcDZQZJB`）叫醒本会话续跑；12.x 全部完成后停用。
