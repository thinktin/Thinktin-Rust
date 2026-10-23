# ios-w2/12.6-plans

目标：WBS 12.6 计划管理（iOS / macOS 共用的 ThinktinKit + ThinktinUI）。从 `ios-app`（`c229459`）切出，做完由 ios-app 会话合并。

已完成：
- 视图模型（`ThinktinKit/ViewModels/Plans/`，只依赖 Foundation / Observation）：
  - `PlanListModel`：全部计划一次拉完，按实例筛选在本地做（流水线有一步在这个实例上的也算）；分组：待确认（置顶，角标数）、按时运行（下一次早的在前，没有下一次的排后）、已暂停；暂停 / 恢复（等确认的不发请求）、删除。
  - `PlanDetailModel`：计划 + 运行历史（`listRuns(filter: .plan(id))`，根运行，按 `before` 翻页，一页 20）；暂停 / 恢复（`canResume` 对等确认的为 false）、删除；“修改规则”= 加新的再删旧的，满 10 条时先删后加。
  - `PlanEditorModel` + `PlanPolicyDraft` + `TriggerDraft`：新建（`createPlan`，带策略、补跑）、编辑（`updatePlan(PlanChange)` 只带改了的字段；触发器先删后加；中途失败已做的不重做，`isPartiallySaved`）；标题 ≤100、目标 ≤8000 按 Unicode 标量数（和服务端 `chars().count` 一致）；策略的数字框空的是不限；超时、时长按服务端 `check_policy` 的范围。
  - `TriggerDraft`：每天 / 每周几 / 每月几号 / 一次性 / 高级 cron / RRULE，时区默认设备时区；生成 `Schedule`（RRULE 自动补 `DTSTART;TZID=`）；已有规则拆回来（认得出的 cron 用常用写法）；写法之间换时带上已填的；保存前的检查和服务端 `Schedule::parse_new`、`check_min_interval`（5 分钟）对应。
  - `ScheduleForecast`：**决定在本地预测**接下来几次触发：cron 按 croner 4 的语义（“日”“周”都不是 `*` 时满足一个就算、夏令时跳过的固定时刻挪到跳过之后），RRULE 按 dateutil / rrule crate 的语义（YEARLY…HOURLY、INTERVAL、COUNT、UNTIL、BYMONTH、BYMONTHDAY、BYDAY 含序号、BYHOUR、BYMINUTE、WKST）；算不了的写法（`L`/`W`/`#`、BYSETPOS、EXDATE…）返回 nil，界面只描述、写“以服务端为准”。
  - `PlanConfirmModel` + `PlanDiff` + `PlanSnapshotStore`：确认页“改了什么”拿 App 这次运行里见过的生效版本比（只在内存里，不落盘）；没见过的：agent 新建（`createdBy == .agent` 且版本号 2）说“新建了”，别的说“没有旧版本可比，请完整核对”；按 revision 确认，冲突时重新拉、标出和刚才看的版本的差别、再确认；已经不用确认了的给提示。
  - `PlanStatus`、`PlansText`（中英文文案；AI 生成标识规则表 `PlansText.isAIGenerated(_:in:)`：标题、目标、步骤提示词在 agent 建的或等确认的计划上标，运行摘要标，失败原因、App 生成的规则描述不标）。
- `Formatting/ScheduleDescription` 增量：RRULE 的 TZID 和用户时区不同时注明（UTC 的写 UTC）；多个日子 / 时刻、MONTHLY 的“第 1 个周一”“最后一个周五”、负数 BYMONTHDAY、YEARLY 的 BYMONTH、COUNT / UNTIL；说不准的写法（BYSETPOS、DAILY 带 BYDAY 等）不描述。原有测试照旧通过。
- 界面（`ThinktinUI/Screens/Plans/`）：`PlansDestination` 接上五个路由；`PlanListScreen`（筛选条、待确认卡片“查看并确认 / 删除”、分组、更多菜单）、`PlanDetailScreen`（头部、等确认提示、规则失效标红 + “修改规则 / 删除”、目标、触发规则、策略、流水线只读 + 去流水线编辑器、运行历史翻页、暂停 / 恢复 / 删除）、`PlanEditorScreen`（实例、标题 / 目标带字数、触发规则列表、策略、补跑、预授权工具开关页）、`TriggerEditorView`（写法切换、时刻 / 日期选择、周几 / 几号方块、cron / RRULE 输入、时区选择页、实时描述和接下来 5 次）、`PlanConfirmScreen`（agent 做了什么、改了什么、改过的块标“改过”、确认 / 修改后确认 / 删除、结果页）。每个页面都有浅色中文、深色英文的 #Preview。
- 桩：`tools/apple/uicheck/Stubs/SwiftUI/SwiftUI+Plans.swift`（`DatePicker`、`DatePickerComponents`、`labelsHidden()`）。
- 测试：`Tests/ThinktinKitTests/Plans/`（预测、触发器编辑、描述、状态与文案、列表、详情、编辑、确认）；`Tests/ThinktinUITests/Plans/PlansScreensTests.swift`（每个路由两种外观 + AX3、各种状态、触发器编辑器每种写法、选择页、小组件出图）。Linux 上 595 个测试通过；uicheck（UIKit、AppKit、`test` 59 个）都过；`swift format lint --strict` 0 条。

进行中：无。

下一步：
- 合进 ios-app 后在 macOS CI 上看真实 SwiftUI 编译和界面测试。
- 12.7 的流水线编辑器做好后，详情页“在流水线编辑器里改”就能用（现在是 `.pipelineEditor` 的占位页）。

坑和决定：
- 列表、详情、确认页复用 12.3 的 `AgentsGroup`、`AgentsRow`、`AgentsSectionHeader`、`AgentsNotice`、`AgentsChoiceRow`、`AgentsTagRow`、`AgentsLoadingView`、`agentsPageLayout()`（同一个模块，不另造一套）；以后可以挪到 `Components/` 改成通用名字。
- MockClient 新建的 cron / RRULE 触发器没有 `nextFireAt`（`MockClient.makeTrigger` 只算一次性的），所以 Mock 里新建的计划显示“不会再运行”；真实服务端会算。可以让 Mock 用 `ScheduleForecast` 算（共享文件，没改）。
- cron、RRULE 输入框在 iOS 上只设了英文键盘；12.4 的桩里有 `autocorrectionDisabled`、`textInputAutocapitalization`，合并后可以加上（现在加会和 12.4 的桩重复声明）。
- 等确认的计划服务端不给 `nextFireAt`，确认页的“确认后第一次”是本地预测的。
- 服务端的最小触发间隔是配置项（默认 5 分钟，agent 工具写死 5 分钟），App 按 5 分钟在本地先拦；档位更严的服务端会回 invalid，界面按错误码显示“填写的内容不正确”。
