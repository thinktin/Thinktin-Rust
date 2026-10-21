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
- 合进 backend-core（`a4e8ba2`）：带进 11.7（33 个新方法）和 10.6（实时活动）。

进行中：
- 11.7 / 10.6 接入：ThinktinKit 加新模型、ClientProtocol 加 33 个方法、MockClient 实现；CoreClient 接上；测试（工作流 wf_e31bb6fd-adb）。
- iOS CI 第一次完整跑（run 39687813304，`66ebc7e`）：看 macOS 上真实 SwiftUI / Xcode 的编译结果。

下一步：
1. 修 macOS CI 暴露的问题直到全绿，然后 12.1 的公共文件（ClientProtocol、模型、Theme）只加不改。
2. W1 四条线并行（`docs/ios.md` 第 8 节）：A 12.16 → 12.2 → 12.12 → 12.17；B 12.3 → 12.4 → 12.8；C 12.5 → 12.18；D 12.6 → 12.7；12.15 由先空的线做。
3. W2：12.13、12.10、12.20、12.21、12.19；12.11 最后；12.9 随 macOS（P3）。

坑和决定：
- 后端前置包（2026-10-22）：backend-core 已认领 11.8、10.7、4.7、5.5（`docs/progress.md` 7b085b7），顺序 10.6 评审 → 11.8 → 10.7 → 4.7 → 5.5；11.8 顺带做计划列表带下次触发时间、Run / run.state 的结构化等待原因码、跨实例的进行中运行列表。5.6 运行附件等 1.1 拍板。新接口只加不改，做完在 `docs/progress.md` 已完成表里写 FFI 新增了什么，本分支合 backend-core 时接上。
- 12.10 实时活动的约定（backend-core 10.6，83f68ba…39234ba，详见 backend-core 的 `docs/live-activities.md` 第 3 节）：类型名必须是 `RunActivityAttributes`，静态属性 `runId`、`instanceId`、`title`；`ContentState` 是 `state`（运行状态字符串）、`steps`（Int）、`startedAt`、`endedAt`（可选，Unix 秒整数，驼峰键名，ActivityKit 用默认 JSONDecoder 解）。client-core 新方法：`register_live_activity(run_id, token)`（`pushTokenUpdates`，十六进制，变了再调）、`end_live_activity(run_id)`、`set_live_activity_start_token(token?)`（`pushToStartTokenUpdates`，用户打开“计划运行时显示实时活动”才登记，关掉传 nil）；只有 iPhone / iPad 能登记。服务端只远程开启计划到点的根运行，用户自己发起的由 App 自己开；远程开启的在 `Activity<RunActivityAttributes>.activityUpdates` 里拿到后照样 `register_live_activity`。推送里没有摘要和 agent 文字。
- client-core 没导出的接口（设备列表与下线、注销、改计划与触发器、团队与模板、换 key、产出物列表与删除、收件箱删除和标未读、runs 分页）：2026-10-22 backend-core 会话已认领 11.7（P1，记在 `docs/progress.md`，c2c3825；只加不改已有签名，做完一组提交一组）；实时活动推送 10.6（P2）等 11.7 做完再定，在那之前没人认领。两行由本分支加进 `gen_wbs.py`。落地前 Swift 的 `ClientProtocol` 先定义这些方法、`MockClient` 实现、`CoreClient` 抛 `ClientError.unsupported`。
- 安卓会话（session_01T2zubC6hDr9ZZR3ihhPP5b）在分支 `android-app` 做 13.x，设计规范在 `docs/android-design.md`；深链格式、事件 kind → 界面的规则两端保持一致。
- `docs/gen_wbs.py`：只改 `AREAS["12 iOS App"]` 这一块；backend-core 手改进 wbs.md 但没进脚本的五行（1.6、9.11、9.12、11.6、13.12）按 wbs.md 逐字补回脚本（安卓分支也这么补，内容相同）。wbs.md / wbs.csv 是生成物，合并时后合的一方重新跑 `python3 docs/gen_wbs.py docs/wbs.md docs/wbs.csv`，不手工解冲突。
- 云端会话是 Linux，没有 Xcode：SwiftUI 代码靠 GitHub Actions 的 macOS runner 编译和跑测试（每次推送都跑）；纯 Swift 逻辑（模型、视图模型、格式化、状态机）用 Linux 上的 Swift 6.2 工具链本地 `swift test`。
- Xcode 工程不手写 pbxproj，用 XcodeGen 的 `project.yml` 生成（CI 和本机都 `xcodegen generate`）。
- 用量限额：2026-10-21 17:45 前后撞上五小时限额，12.1 骨架工作流的三个 agent 和 WBS 审查者中断，21:33 重置后恢复（已写的文件先按 WIP 提交，`c11a0eb`）。现在有每 3 小时一次的定期检查（`trig_01Wt6oEwQkA7pisCjcDZQZJB`）叫醒本会话续跑；12.x 全部完成后停用。
