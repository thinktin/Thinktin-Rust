# claude/determined-lovelace-vn0j5h

目标：2026-10-25 用户让“看上一个 agent 的进度，把工作梳理清楚，继续开干，不用停；额度恢复就自动开干”。三条线（后端 `backend-core`、iOS `ios-app`、安卓 `android-app`）10-23 起按用户要求暂停，原来的三个会话已经找不到了，由本会话（session_01JYVuTJTo78Zrenhct8Bkw5）接着做。

## 分支

- 本分支是**集成分支**：从 `ios-app`（`c0d6c54`）切出，合了 `android-app`（`43ce7c7`），两边都已经合到 `backend-core` 的 `67f9e7a`。合并只在 `docs/gen_wbs.py` 上冲突（11.7 / 11.8 取 iOS 的，13.x 取安卓的），`wbs.md` / `wbs.csv` 重新生成：162 个包、775 人日。
- 会话分配的分支就是这个，按规则不直接推 `backend-core` / `ios-app` / `android-app`。**每个提交只改一条线**（`apps/android/**` + 安卓进度，或 `apps/apple/**` + `tools/apple/**` + iOS 进度，或 `crates/**` 等后端），以后可以逐个 cherry-pick 回各自的分支；用户同意的话也可以直接把各分支快进到这里对应的提交，或者整个分支一起合。
- CI 只在 `main` / `backend-core` 的推送和 PR 上跑，本分支没有 PR 就没有 CI，所以推送前在本机验证：Rust（cargo test，集成测试要 Postgres）、Swift 6.2（Linux，`/opt/swift`）跑 ThinktinKit 和 uicheck、Android SDK（`/opt/android-sdk`）跑 Gradle 的 test / lint / assembleDebug。macOS 上真实 SwiftUI 的编译只能等 iOS CI（PR #8）。
- 自动续跑：每小时一次的定时任务叫醒本会话（见“坑和决定”），撞上用量限额后恢复时自己接着做。

## 现状（2026-10-25 梳理）

### 后端（`backend-core`，进度在 `docs/progress.md`）

P1 后端核心（M1–M9）和 P2 里能在代码层面完成的包都做完了，CI 绿，PR #5 等人审、合并。剩下的：

- **代码上还能做的**：11.9 评审修复（`3d53748`、`ef80477`）的最后一轮复核；安卓已经不读 `PLAN_ONLY_BASES`，可以去掉（先确认 iOS 和测试都不用）。
- **等部署 / 集群（2.2、2.3、2.5、2.7）**：Cube 真实集群联调（6.2、6.6、7.12 整机快照、7.15 预发演练）、出口代理（保险箱请求头注入、沙箱出网白名单）、17.5 正式压测数字、6.8 envd 和模板注册、2.9 集群与第一次发布。
- **等人拍板**：5.6 运行附件（等 1.1）；16.5 法务复核（`docs/licenses.md` 第 6 节）；短信、KMS 服务商按默认接了阿里云，待确认；15.5 每个 agent 的负责人和季度演练；`mobile.yml` 合到 main 后实跑一次。

### iOS（`ios-app`，进度在 `docs/progress/ios-app.md`，PR #8 草稿）

已完成 12.1、12.2、12.3、12.4（已审查）、12.5、12.6、12.12、12.16，和 backend-core `67f9e7a` 对齐。Linux 上 846 个测试，uicheck 83 个。

下一步（按原计划）：
1. 对抗式审查 12.5、12.6、12.12（合并前没审）。
2. 合并后留下的小项（ComposerBar 共用、`InstanceEventKind.instanceState`、`AppRoute.artifact`、BiometricGate、`MockClient.makeTrigger` 的下次触发时间、用词统一、设置里的跳转等，见 iOS 进度文件“下一步 2”）。
3. 第三轮：12.7 团队与流水线、12.8 推送与收件箱、12.15 审批中心、12.17 引导与空状态、12.18 产出物。
4. 之后：12.13、12.10、12.20、12.21、12.19，12.11 最后；12.9 随 macOS（P3）。
5. uicheck 的盲区（`#if os(iOS)` 分支查不到）。

### 安卓（`android-app`，进度在 `docs/progress/android-app.md`，PR #7 草稿）

已完成 13.1、13.2、13.3、13.4、13.16，破坏性改动适配，和 backend-core `67f9e7a` 对齐。437 个 debug 测试 + 163 个 release 变体，lint 0 错误。

下一步（按原计划）：
1. 13.5 对话与运行过程：已有大量代码（`ui/chat/` 下 7 个文件和测试），停在部分改动的快照上（`ba78a8d`）。先对照 WBS 13.5 和设计规范第 8 节补齐，再评审、修复、验证。
2. 13.6 计划 → 13.8 推送与收件箱 → 13.13 设置 → 13.7 团队与流水线 → 13.11 / 13.12，之后 P2 的 13.10、13.14。

## 本会话的顺序

先搭环境（Swift 6.2、Android SDK、client-core 本机库），然后两个客户端交替推进，每做完一个包就提交推送、更新本文件：

1. 安卓 13.5 补齐 → 验证 → 推送。
2. iOS 审查 12.5 / 12.6 / 12.12 → 修 → 验证 → 推送。
3. 安卓 13.6；iOS 12.15、12.8；安卓 13.8；iOS 12.7、12.18、12.17；安卓 13.13、13.7……
4. 后端的两个小项穿插着做。

已完成：
- 集成分支（`6375b05`）；本文件（`276f2c5`）。
- 后端：去掉 `PLAN_ONLY_BASES`，`plan_only_base` 逐家查（`854c017`）。
- iOS 审查 12.5 / 12.6 / 12.12，修三处（`85cd7e3`，详见 iOS 进度文件）：举报说明按标量数、agent 待办清单能举报、运行详情停止冲突后刷新。
- 安卓 13.5 收尾（`f93ad4c`）：代码已齐，修运行页深链定位少算一行。
- 安卓 13.6 计划（`21fdc49` 及之前的 `schedule/`）：列表、详情、新建 / 编辑、触发规则面板，本地的 cron / RRULE 预测。全量 test / lint / 打包通过。
- iOS 12.15 审批中心与审批详情（`0ea8a8e`）。
- iOS 12.8 推送与收件箱（`691e1ab`）：收件箱和单条通知页、点开推送标已读、通知上的“拒绝”、APNs 令牌上报、角标和退出登录清通知、
  `AppDelegate`；uicheck 加了 UserNotifications 的桩，App 的推送代码在 Linux 上也做类型检查。866 个测试。

- 安卓 13.8 推送与收件箱：收件箱页面、通知渠道（`tt_approval` / `tt_results`）、推送点开跳转和标已读、令牌上报流程；推送 SDK 没接（要人定，见下）。
  全量 test（app 292）/ lint / 打包通过。

- iOS 12.18 产出物（`c4e0c1a`）：产出物库、产出物详情（预览、分享时文件名带 AI 标识、删除），新路由 `.artifact(id, runID:)`。
- 安卓 13.13 设置、多语言与开源许可（`c2f3b66`）：语言（AppCompat 的应用语言）、通知、关于、开源许可页。app 测试 301 个。
- iOS 12.17 引导：五步清单、换新机检查、登录后才注册 APNs、通知权限在引导最后一步问。876 个测试。

- 安卓 13.7 团队与流水线：团队、模板、团队编辑、计划编辑页里的流水线步骤（本地 DAG 规则同服务端）。app 测试 308 个。

进行中：
- iOS 12.7 团队与流水线（2026-10-26 开始）：团队、模板、团队编辑、流水线编辑器、运行树补停止和等待提示。之后安卓 13.11 / 13.12、iOS 12.13 / 12.10 等。

环境（容器回收后要重装）：Swift 6.2 装在 `/opt/swift`（swift.org 的包，验签）；Android SDK 在 `/opt/android-sdk`（cmdline-tools、platform 35、build-tools 35.0.0，不用 NDK）；`cargo build -p client-core --lib` 出本机库，`tools/client-core/build-linux-swift.sh target/linux` 出 Linux 版 Swift 包。Gradle 直连 Maven Central 没被限流。Gradle 和 Swift 一起跑时 Robolectric 偶尔超时，分开跑。

坑和决定：
- 原来三个会话（backend `session_016LgPcdynywrhrjCq8VVFLt`、iOS `session_01GuCp3KRgqaK6Kzynw6udRn`、安卓 `session_01T2zubC6hDr9ZZR3ihhPP5b`）查不到了，它们 scratchpad 里的工作流脚本和缓存也没了，按各进度文件重新来。
- 定时任务 `trig_01LULryki4Z7mPLXhgSXGWMP`（每小时第 58 分）：叫醒本会话、读本文件接着做；全部做完或用户叫停时删掉。
- 要人定的：iOS 批准审批时设备没设锁屏密码照常批准（`BiometricGateResult.unavailable`），安卓是不许批准，两端不一致。
- 要人定的：安卓推送 SDK（极光闭源、FCM 带 Play 服务许可，和安卓“只用宽松许可证”的约定冲突；极光的权限和 Robolectric 不兼容），详见 `docs/progress/android-app.md`。现在两个渠道的 `FlavorPush` 是空实现。
- Robolectric 的触摸点不到盖在页面上的面板（会落到遮罩上，真机正常）：面板里的控件在测试里用 `SemanticsActions.OnClick`（安卓 README 已知问题）。
