# ios-w2/12.4-models

目标：WBS 12.4 模型 key 配置（iOS / macOS 共用的 ThinktinKit + ThinktinUI）。从 `ios-app`（`648cc7d`）切出，实现提交在 `6bcdc61`，之后由审查者在同一分支上对抗式审查并修，做完由 ios-app 会话合并。

已完成：
- 视图模型（`ThinktinKit/ViewModels/Models/`，只依赖 Foundation / Observation）：`CredentialsModel`（key 列表，在用 / 停用分组）、`AddCredentialModel`（厂商表或自定义 https 地址、本地校验和服务端一致、第三方 AI 数据共享的明示同意、拒收原因本地化并显示在对应字段下面）、`CredentialDetailModel`（改备注、启用 / 停用、换 key、删除前查哪些路由在用、最近 30 天用量）、`ModelRoutesModel`（main 必填在前、fast 可选、自定义别名、每个别名最多 3 个备用、按 `agent.canUse` 过滤 key、保存前确认数据共享）、`UsageModel`（7 / 30 / 90 天、按天补 0、四种分组）、`ThirdPartyAIConsentStore`（给 12.5 首次发消息前再拦一次用）、`ModelsText`（中英文文案和规则；这几页没有 agent 写的字段，不带 AI 生成标识）。
- 界面（`ThinktinUI/Screens/Models/`）：key 列表、添加 key（sheet）、key 详情（改备注、换 key 两个 sheet）、模型路由编辑器（有未保存修改时返回换成“放弃修改”）、用量看板（Swift Charts 按天柱状图）；`ModelsDestination` 接上 `.credentials`、`.addCredential`、`.credential`、`.modelRoutes`、`.usage`。每个页面有浅色 / 深色、中文 / 英文的 #Preview。
- 桩：`tools/apple/uicheck/Stubs/Charts/`、`Stubs/SwiftUI/SwiftUI+Models.swift`（SecureField、Picker、tag、textInputAutocapitalization、autocorrectionDisabled、navigationBarBackButtonHidden）。
- 审查修复（第二个提交）：
  - 唤醒等 key 的运行：服务端的 `wake_waiting_runs` 只把下次尝试时间改成现在，状态要等执行器接手才变，接口一返回就数“操作后还在等的”总是和操作前一样多，原来会说“还有 N 个任务在等 key，可能是别的别名有问题”。改成只说操作前在等的 N 个马上重试（`KeyWakeResult(retried:)`），操作后照样拉一次运行刷新缓存。
  - 删除 key：已删除实例的路由服务端还留着（实例是软删除），会让删除一直 409，而 App 看不到这些路由。409 后重查引用还是空的就说明原因、不再让删（`hasHiddenReferences`），建议停用；409 的原因不再在错误提示和按钮下面各说一遍。
  - 停用：还没查到哪些别名在用时也先确认（原来直接停用）。
  - 添加 key：服务端拒收的原因显示在对应的字段下面（和安卓一样），改了那个字段就清掉（原来改了地址，套餐地址的提示还留着）；同意绑定到接收方，自定义地址换了主机要重新勾，几个不同主机都写进同意的那一句。
  - 上游模型名、加别名的输入框不自动大写、不纠错（原来 iOS 会把 `claude-…` 改成 `Claude-…`，厂商那边找不到模型）。
  - 用量看板：换时间范围时清掉上一个范围的数据（原来加载中、加载失败时把 30 天的总数显示成 90 天的）；旧范围、旧分组的结果晚回来不再覆盖。
  - 保存路由前确认数据共享的那段话说的是这个实例（原来说“用这把 key 的实例”）。
- 验证：Linux 上 599 个测试通过；uicheck（UIKit、AppKit、`test`）都过；`swift format lint --strict` 0 条。

进行中：无。

下一步：
- 合进 ios-app 后在 macOS CI 上看真实 SwiftUI / Charts 编译和界面测试。
- 后端 11.9 做完（改每日上限、`/v1/vendors` 给订阅类 key 前缀和套餐地址）后接到添加 key 和 key 详情：每日上限可改、订阅类 key 在本地先拦。

坑和决定：
- MockClient（共享文件，没改）和服务端不一致的地方：删除还在路由里的 key 不回 409；`setModelRoutes` 收停用的 key（服务端回 invalid “credential … is not usable”）；不模拟唤醒等 key 的运行；`usage` 不管时间范围；添加 key 不填备注时 Mock 用厂商名，服务端存空字符串（界面两种都按“没备注显示厂商名”处理）。测试里用 `failNext` 模拟服务端的回应。
- 已删除实例的模型路由服务端不清（`delete_instance` 只改状态），删 key 时一直算“在用”：要后端在删实例时清掉路由，或者删 key 时不数已删除实例的路由。
- 同意记录按设备记（`UserDefaults`，退出登录不清，见 `ThirdPartyAIConsentStore` 的说明）；说明改版改 `currentVersion`。
- 复用 12.3 的 `AgentsGroup`、`AgentsRow`、`AgentsNotice`、`AgentsChoiceRow`、`AgentsTagRow`、`AgentsLoadingView`、`agentsPageLayout()` 和 12.2 的 `CheckboxRow`、`FieldMessage`。
- Charts 的桩把图表闭包当成不在主线程隔离域里（比真实 SDK 严），图表代码只用先取好的值。
