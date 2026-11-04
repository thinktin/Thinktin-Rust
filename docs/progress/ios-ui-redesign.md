# ios-ui-redesign

目标：按用户给的参考 App 截图（120 张，2026-11-04，不进仓库）改版 iOS 界面：照页面布局做，按钮这类控件能用系统原生的一律用原生的（`docs/ios.md` 第 1 节第 5 条）。登录页用户自己设计，不照做。

已完成：
- 改版规范 `docs/ios-ui-redesign.md`：视觉语言、导航图、逐页规范（9 组 45 节）、120 张对照表（只改界面 6、部分有 35、纯客户端 18、要后端 50、不适用 11）、要用户拍板的 24 件事、分轮实施计划。逐张分析 + 写规范 + 对抗式核对（抽查 33 张截图、对过 ClientProtocol）由工作流 wf_01a9fc73-32e 完成。
- 第 0 轮·uicheck 桩（规范 2.10）：`Stubs/SwiftUI/SwiftUI+Lists.swift`（`List`、`Form`、`Section`、`LabeledContent`、
  `ContentUnavailableView`、列表 / 表单样式、行的修饰符、`swipeActions`、带预览的 `contextMenu`、`badge`、系统按钮样式和外形、
  工具栏位置和 `ToolbarItemGroup`、`toolbar(_:for:)`、`toolbarTitleDisplayMode`、`searchable(text:isPresented:)`、弹窗重载、
  `fullScreenCover`、`sensoryFeedback`、`LazyVGrid`、`Gauge`、`PasteButton`、材质、形状简写）和 `SwiftUI+Glass.swift`
  （iOS 26 的玻璃、玻璃按钮样式、`Button(role: .close / .confirm)`、`ToolbarSpacer`、`DefaultToolbarItem`、`safeAreaBar`；
  iOS 18 的 `toolbarVisibility`、缩放转场）。
- 第 0 轮·设计令牌（6.2 C）：`paper` / `paperElevated` / `userBubble` / `hairline` 换中性灰，新增 `agentBubble`，`ink` 三档改成系统
  的 `label` / `secondaryLabel` / `tertiaryLabel`（`ThemeToken.systemLabel`；表里的十六进制是叠在 `paper` 上的近似值），标题不再用衬线，
  `Metrics.Radius.card` 16 → 20、新增 `composerCard` 28 和 `Metrics.Avatar`；`themedGroupedBackground()`、`themedRow()`；
  `DesignTokenTests` 和 docs/ios.md 第 4 节跟着改。
- 第 0 轮·`Design/Glass.swift`（规范 2.6、2.7、2.10）：`CloseButton`（iOS 26 带 `ButtonRole.close`）、`ConfirmButton`（`.confirm`，保存中转圈）、
  `glassButtonStyle(.regular / .prominent)`（旧系统 `.bordered` / `.borderedProminent`）、`glassBackground(in:interactive:)`（旧系统
  `.regularMaterial`）、`GlassGroup`（`GlassEffectContainer`）、`floatingBar(edge:)`（`safeAreaBar` / `safeAreaInset`）、
  `GlassToolbarSpacer(.fixed / .flexible)`、`BottomBarSearchItem`（只有 iOS）、`hidesSharedGlassBackground()`、`toolbarBadge(_:)`、
  `zoomTransitionSource` / `zoomNavigationTransition`（iOS 18，macOS 不做）。测试 `NativeControlsTests` 顺带把第 1 轮要换的系统控件
  （`List`、`Form`、`LabeledContent`、`ContentUnavailableView`、左滑、长按预览、搜索、工具栏位置）都用一遍，macOS CI 用真 SDK 编它，
  桩的签名对不上会在那里露出来。
- 第 0 轮·`Components/InstanceAvatar.swift`（规范 2.4、6.9 C）：首字头像，底色按名字的 FNV-1a 散列从 8 色色板里取（跨进程稳定，
  避开强调色和状态色，白字对比度 4:1 以上），右下角可选状态角标（`.instance` / `.run` / `.custom`），读屏念“名字，状态”；
  尺寸用 `Metrics.Avatar`。`AgentMonogram` 删掉，6 个调用处（agent 目录、agent 详情、实例详情、模型 key 列表和详情、开源许可）
  换成它，旁边有名字的照旧对读屏隐藏。测试 `InstanceAvatarTests`。
- 第 0 轮·`Components/FilterChipBar.swift`（规范 2.8）：横向滚动的单选筛选胶囊，系统按钮 + `glassButtonStyle`（选中 `.prominent`），
  外面包 `GlassGroup`，可带数，换选中时有选择触感；`value` 重复的只留第一个，点已选中的不改值。泛型 `Value: Hashable`，
  “全部”用 `nil` 的那个胶囊。还没有调用处：`PlansFilterChip`（计划、产出物、触发器编辑）第 1 轮由 D 线换。测试 `FilterChipBarTests`。
- 第 0 轮这一份的 Linux 检查（2026-11-04，最后一次提交上）：ThinktinKit `swift test` 988 个全过；uicheck UIKit、AppKit 都编过；
  `run.sh test` 的 ThinktinUITests 131 个全过（新加 `NativeControlsTests`、`InstanceAvatarTests`、`FilterChipBarTests`）；
  App 的 `ThinktinTests` 16 个过 11 个，挂的 5 个是要 App 包的（Info.plist、PrivacyInfo、小组件 appex、`~/Library` 路径），
  Linux 上本来就过不了（docs/handoff-ios.md 第 88 行）；`swift format lint --strict` 零条。macOS CI 还没看（推送后跑）。

决定（2026-11-04）：用户问“发的那套 UI 怎么没照着改”，按规范第 6 节的建议开工，用户随时可以改：
6.1 A + A1（实例列表为根、去掉抽屉，抽屉的入口放首页左下“工作台”）；6.2 C（中性灰底和卡片、强调色留橙色、agent 回复加气泡、
字体全用系统的）；6.3 A（保持 iOS 17，iOS 26 的接口在 Design/Glass.swift 里回退）；6.4 A（“+”直接弹领养表单）；6.5 A（设置用 sheet）；
6.6 A（沿用“实例”）。其余 18 项按建议。

进行中：第 0 轮底座的后几步（导航、Shell 和最小首页、启动屏、截图脚本、docs/ios.md 6.1 / 9.1）还没人认领。

下一步：
1. 第 0 轮剩下的（规范 7.2 第 5 行起）：路由（3.3：`.home` 永远是根、`.conversation` 压栈、`.settings` sheet、`.search` 回首页、
   `.plans(instanceID:)`、`.adopt(agentID:)`、`sheetPath` 和第二层 sheet、深链返回栈 3.4）；最小首页 `Shell/Home/`，去掉抽屉和
   `InstanceSwitcher`，同时删掉 `solidTopScrollEdge()`；各功能接入点跟上新路由；启动屏资源；截图脚本的 `THINKTIN_OPEN_SCREEN`；文档。
   首页直接用这一份的东西：`InstanceAvatar(name, size: Metrics.Avatar.list, badge:)`、`toolbarBadge(_:)`、`BottomBarSearchItem()`、
   `GlassToolbarSpacer(.fixed, placement: .bottomBar)`、`hidesSharedGlassBackground()`、`ContentUnavailableView` + `BrandLogo`；
   sheet 的关闭用 `CloseButton`，主操作用 `ConfirmButton`。
2. 推送后看 macOS CI（`.github/workflows/ios.yml`）：Glass.swift 的 `if #available` 分支和新测试只有真 SDK 才验得出来。
3. 第 1 轮五条线并行；第 2 轮纯客户端新功能；第 3 轮等后端。

坑和决定：
- 参考截图是别家产品、里面有用户的账号信息，仓库公开，所以**不进仓库**；规范里只用自己的话写布局和交互，不写参考 App 的名字。以后的会话要看截图，请用户再发一次压缩包。
- Router 现在只有一层 sheet，设置改成 sheet 后里面再跳转会把设置关掉：第 0 轮要先改 Router（规范 3.3）。
- `ToolbarContentBuilder.buildLimitedAvailability` 在 SDK 里是 iOS 17.5 / macOS 14.5 才有，比最低版本高：`.toolbar { if #available(...) { … } }`
  在真实 SDK 上编不过。按系统版本放的工具栏项（iOS 26 的 `ToolbarSpacer`）一律用 Design/Glass.swift 的 `ToolbarContent` 帮手，
  桩里也故意不给这个方法。Linux 上不检查 iOS / macOS 的版本，漏写 `if #available` 只有 macOS CI 查得出来。
- 桩里 `PlainButtonStyle` 改成和 SDK 一样的 `PrimitiveButtonStyle`，`ToolbarContent` 有了 `body` 要求、`_ConditionalContent` 去掉了约束。
- Glass.swift 的帮手按系统版本分支时用显式 `return`（opaque 返回类型可以按 `if #available` 取不同的底层类型），不用 `@ViewBuilder`：
  后者会包一层 `AnyView`，工具栏认不出里面的按钮。`CloseButton` 的标签自己给（系统按角色生成的标签跟系统语言，不跟 App 的界面语言）。
- 文字三档改成系统色以后，`Theme.ink` 在浅色是纯黑、深色是纯白（`BrandLogo` 的罐体线条也跟着变）；`ThemeToken.light` / `dark`
  对这三档只是近似值，别拿来画界面。
- `CredentialSummary.monogram`、`AgentCatalogCard.monogram`（ThinktinKit）界面上不再用了（头像自己按名字算），留给对应的线收拾。
- 桩还没补的（第 0、1 轮用不到）：PhotosUI 的 `PhotosPicker`、`MagnifyGesture`、`AccessibilityNotification`、StoreKit 的
  `SubscriptionStoreView`；用到的那一轮照 SDK 补。
- 自画的 `Card`、`GroupedSection` 还画一像素描边（规范 2.1 说卡片不画描边）：第 1 轮各线换成 `List` / `Form` 时一起去掉，这一步没动。
