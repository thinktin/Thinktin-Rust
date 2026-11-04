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
- 第 0 轮·路由（规范 3.3、3.4，7.2 路由那一行，提交 `6594b32`）：
  - `AppRoute`：`.home` 永远是根、归 `.shell`；`.conversation` 压栈（照样记成当前实例）；`.settings`、新加的
    `.adopt(agentID:)`（归 `.agents`，离线 `unavailable`，标题“领养新实例”）是 sheet；`.search` 是 `.root`（回首页、`searchRequest` 加一）；
    `.plans(instanceID:)`（nil 是全部）；`isTopLevel` 只剩工作台的 6 个入口；新加 `returnsToConversation`（实例资料、模型路由、实例的计划和
    产出物、运行详情、运行树、产出物详情）。
  - `Router`：去掉抽屉状态；`openFromDrawer` 改名 `openTopLevel`；`sheetPath`（sheet 自己的栈）、`nestedSheet` + `nestedSheetPath`（第二层，
    最多两层，再开就换掉第二层）；sheet 开着时 `open(.push)` 压进最前面那层的栈，`.conversation` 例外（关掉所有 sheet 再压主栈，主栈里已有
    这个对话就退回到它）；`pop()` 退最前面那层，退到 sheet 的根再退就关掉它；`dismissSheet()` 关最前面那层，`dismissAllSheets()` 全关；
    `selectInstance(id)` 是“首页 → 对话”；`requestNewTask` 同样进对话再加 `newTaskRequest`；新加 `visibleRoute`（眼前的页面）、
    `frontSheet`、`routeBelowSheet`（sheet 底下的页面）、`removeRoutes(of:)`（实例删了：各层栈从它的第一个页面起截掉）。
  - `DeepLink.backStack(to:instanceID:)`：深链和推送的返回栈“首页 → 目标页”，实例的页面“首页 → 对话 → 目标页”；`Router.show` 用它。
  - `AppModel`：当前实例被删时只拿掉它的页面（以前是回到根）；`startNewTask` 没实例时 `openTopLevel(.agentCatalog)`。
  - 界面只改到能编、能用：`AppShell` 的 sheet 换成 `SheetStack`（`NavigationStack(path:)` 绑 `sheetPath`，里面再挂第二层），设置、领养的根页面
    补左上 `CloseButton`；抽屉的开关挪成 `AppShell` 的本地状态（过渡）；首页还不能原地搜索，`searchRequest` 变了先把 `.search` 压上来（过渡）；
    `ShellDestination` 接 `.home`（先放原来的 `ConversationHomeScreen`）；`PlansDestination` 把实例传给 `PlanListScreen(instanceFilter:)`；
    `AgentsDestination` 的 `.adopt`：nil 时 Agent 目录、有 agent 时它的详情（领养照旧在详情里，第 1 轮 C 线换成表单）；
    靠“sheet 关了”刷新的页面（模型 key、模型路由、计划列表）和靠 `topRoute` 的保险箱改看 `visibleRoute`；添加 key 看 `routeBelowSheet`；
    引导的关闭看 `frontSheet`；删实例用 `removeRoutes(of:)`；对话页压栈后没了标题，先放实例名（`inlineNavigationTitle`，B 线换成胶囊）。
    `THINKTIN_OPEN_DRAWER`（`AppConfiguration`、App 冒烟测试）和截图脚本的两张抽屉图去掉了（规范 3.3 那一行）。
  - 文档：docs/ios.md 6.1（返回栈、推送）、6.2（领养没有缓存）、7（截图张数）、9.1 第 3 条（`open` 的新规则、`visibleRoute`）。
  - 测试：`AppRouteTests` 逐个查新 case 的 `feature`、`presentation`、`offlinePolicy`、`title`、`returnsToConversation`；`RouterTests`
    重写（对话压栈和退回、sheet 栈、第二层、系统下滑关掉时清栈、工作台入口、删实例、深链和推送的返回栈、没登录先记下）；`DeepLinkTests`
    加返回栈；`AppModelTests`、`AgentsScreensTests`、`AppShellTests`（加“设置是 sheet”）、`PlansScreensTests` 跟着改。
  - 这一步的 Linux 检查（2026-11-04）：ThinktinKit `swift test` 997 个全过（`CoreClient118Tests` 的 Accept-Language 那条起本地 HTTP，
    整组并行跑时偶尔连不上，单跑和重跑都过，和这次改动无关）；uicheck UIKit、AppKit 都编过；`run.sh test` 133 个全过；App 的
    `ThinktinTests` 16 个过 11 个（还是那 5 个要 App 包的）；`swift format lint --strict` 零条。
- 第 0 轮·Shell 和最小首页（规范 4.2.1 第 0 轮的最小版、6.1 A + A1、6.5 A，7.2 的首页和接入点两行；提交 `70c1847`、`32bbb4c`）：
  - 视图模型（ThinktinKit）：`DrawerEntry` 改名 `WorkbenchEntry`（`systemImage`、`countsTowardTotal`、菜单副标题 `subtitle(count:)`）；
    `ShellBadges.workbenchTotal`（收件箱未读 + 待审批 + 待确认的计划；进行中是状态不是待办，不算）、`workbenchTitle`、
    `workbenchAccessibilityLabel`；新的 `ViewModels/Shell/HomeListModel.swift`：`HomeRow`（最后活动 = 实例的 `lastActiveAt` 和最近一个
    没结束的运行里晚的那个）、`HomeRowPreview`（在等你处理 > 进行中的运行 > 实例的状态）、`HomeList.rows`（去掉已删除的，最后活动新的在前，
    一样新的按名字、再按 id）、`HomeList.timestamp`（今天“14:05”，更早的日期）；`AppModel.homeRows`；`InstanceActivity.latestWaitingState`。
    `Router.path` 的 `didSet`：栈里最上面的对话记成当前实例（首页的行和系统返回手势直接改 `path`，不经过 `open`）；`handledSearchRequest`、
    `hasPendingSearchRequest`、`searchRequestHandled()`：首页比搜索请求晚出现（冷启动深链）时补上，处理过的不再激活，退出登录时丢掉。
  - 界面：新的 `Shell/Home/`：`HomeScreen`（plain `List` + `NavigationLink(value: .conversation(id))`；左上账号头像 `router.open(.settings)`，
    右上“+” `router.open(.adopt(agentID: nil))`；底部工作台菜单 + `GlassToolbarSpacer(.fixed)` + `BottomBarSearchItem()`；
    `.searchable(text:isPresented:)`，有字时列表换成按种类分组的搜索结果（`HomeSearchResults`，用 Search 目录的 `SearchResultRow`）；
    下拉刷新；`ContentUnavailableView` 的空状态（`BrandLogo` + “还没有实例” + “去领养”）、离线没缓存；拉取失败 `ErrorBanner`；回到首页
    时角标太久没刷新就刷新）、`HomeInstanceRow`（48pt `InstanceAvatar` + 状态角标、名字、时间、预览，读屏合成一句）、`WorkbenchMenu`
    （系统 `Menu`，6 项带副标题，按钮上 `toolbarBadge(workbenchTotal)`，点了 `openTopLevel`）。macOS 没有底部条：账号在 `.navigation`，
    工作台和“+”在 `.primaryAction`，搜索栏是工具栏里的。
  - 删掉：`ShellDrawer.swift`、`InstanceSwitcher.swift`、`AppShell` 里的 `RootPage`（抽屉按钮、左缘手势、把 `.search` 压上来的过渡）和
    `isDrawerOpen`、`solidTopScrollEdge()`、`Metrics.drawerMaxWidth`、`ConversationHomeScreen`（`RunTreeScreen.swift`）和它用的
    `ConversationText.homeTitle/homeMessage/browseCatalog`。主栈的根直接是 `AppDestination(route: .home)`，横幅照旧由 `AppDestination` 放。
    `ShellDestination` 的 `.home` 换成 `HomeScreen`；`SearchDestination` 只改了说明（`.search` 不再压栈）。
  - 文档：docs/ios.md 第 5 节 `instance.state` 那行、第 9 节表里 12.16 和 12.5 两行、9.1 第 6 条（对话页没有抽屉按钮了，首页的接法）。
  - 测试：ThinktinKit 新 `HomeListTests`（排序、已删除、预览、时间、演示数据）、`ShellStateTests` 加工作台总角标、菜单项、菜单项的路由
    （开着设置也先关掉再压），`RouterTests` 加“直接改主栈记当前实例”“搜索请求补上一次”，`AppRouteTests` 加“顶级页面正好是工作台的 6 项”；
    `AppShellTests` 的抽屉、实例切换两条换成：首页 → 对话 → 实例资料 → 回首页开设置（sheet）→ 开领养、首页的几种状态、行的预览文字和角标、
    工作台菜单、首页搜索结果；`ConversationScreensTests` 去掉旧首页那一行（换到 `AppShellTests` 的“没有实例”）。
  - 这一步的 Linux 检查（2026-11-04，`32bbb4c` 之后）：ThinktinKit `swift test` 1007 个全过；uicheck UIKit、AppKit 都编过；`run.sh test`
    136 个全过；App 的 `ThinktinTests` 16 个过 11 个（还是那 5 个要 App 包的：Info.plist、URL scheme、隐私清单和多语言资源、小组件 appex、
    `~/Library` 路径）；`swift format lint --strict` 零条。macOS CI 还没看。

决定（2026-11-04）：用户问“发的那套 UI 怎么没照着改”，按规范第 6 节的建议开工，用户随时可以改：
6.1 A + A1（实例列表为根、去掉抽屉，抽屉的入口放首页左下“工作台”）；6.2 C（中性灰底和卡片、强调色留橙色、agent 回复加气泡、
字体全用系统的）；6.3 A（保持 iOS 17，iOS 26 的接口在 Design/Glass.swift 里回退）；6.4 A（“+”直接弹领养表单）；6.5 A（设置用 sheet）；
6.6 A（沿用“实例”）。其余 18 项按建议。

进行中：没有人在做。第 0 轮还剩启动屏资源、截图脚本（`THINKTIN_OPEN_SCREEN`），都还没人认领。

下一步：
1. 第 0 轮剩下的（规范 7.2）：启动屏资源（`tools/apple/brand_assets.py`、`Assets.xcassets`、`project.yml`）；截图脚本加只有 Debug 认的
   `THINKTIN_OPEN_SCREEN`（conversation / plans / artifacts / settings / search / adopt，打开演示数据第一个实例的对应页面；search 用
   `router.open(.search)`，首页会补上激活），截图清单换成规范 7.6 的（`tools/apple/screenshots.sh`、`AppConfiguration.swift`）。
2. 推送后看 macOS CI（`.github/workflows/ios.yml`，只在推 main 和 PR 时跑）：Glass.swift 的 `if #available` 分支、首页工具栏
   （`#if os(iOS)` 里的 `ToolbarContent`、菜单项的两行 `Text`、`toolbarBadge` 在 iOS 26 上的 `.badge`）和新测试只有真 SDK 才验得出来。
3. 第 1 轮五条线并行；第 2 轮纯客户端新功能；第 3 轮等后端。A 线（首页）接着做：长按菜单（4.2.2）、“等你处理”提示行、预览换成最近
   一次运行的摘要（6.7）、`SearchResultsView` 嵌进首页（D 线先交）、空查询时列实例、`NewTaskSheet` 换选择器版式（4.4.5）。

坑和决定：
- 参考截图是别家产品、里面有用户的账号信息，仓库公开，所以**不进仓库**；规范里只用自己的话写布局和交互，不写参考 App 的名字。以后的会话要看截图，请用户再发一次压缩包。
- 路由：sheet 里的页面要刷新别看 `router.sheet == nil` 或 `router.topRoute`（`topRoute` 只看主栈），看 `router.visibleRoute`；
  要知道自己是从哪个页面弹出来的看 `router.routeBelowSheet`。`NavigationLink(value: AppRoute)` 在 sheet 里压进 sheet 的栈（`SheetStack` 绑了
  `sheetPath`），设置根页面的行就是这样进子页的；sheet 页用 `NavigationLink(value:)` 打开会被压栈（引导在设置里就是这样），
  要弹出就用 `router.open`。sheet 被系统下滑关掉时 `Router.sheet` 的 `didSet` 清掉它的栈和第二层。
- 路由：对话改成压栈后 `.conversation(id)` 的新建页拿不到 `newTaskRequest` 的变化（页面在请求之后才建）：`requestNewTask` 新进对话时
  输入框不会自动聚焦，B 线做对话页时在 `onAppear` 里看一下（比如对比上次处理过的 `newTaskRequest`）。
- 路由：安卓还是抽屉结构，深链返回栈两端不一样了（规范 3.4、6.1，要不要跟着改另议）。
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
- 首页：`.searchable` 挂在 `ZStack` 上（不是 `Group`），有字时里面从实例列表换成搜索结果，搜索栏挂的视图不变、不丢焦点。搜索结果第 0 轮是
  `HomeScreen.swift` 里的 `HomeSearchResults`（按种类分组，复用 `SearchResultRow`），D 线拆出 `SearchResultsView` 后换掉。
- 首页：行的预览文字和头像角标（`HomeRowPreview.text`、`avatarBadge`）放在 ThinktinUI 的 `HomeInstanceRow.swift`，因为状态名
  （`RunState` / `InstanceState.localizedName`）在 ThinktinUI 的 `StatusTone.swift`；测试在 `AppShellTests`（`run.sh test` 在 Linux 上跑）。
  开着、闲着的实例写“随时可以接任务”、不画角标（实例的“运行中”和运行的“运行中”分不清）。
- 首页：iOS 17 / 18 上底部条只有工作台菜单（`BottomBarSearchItem` 不放东西），搜索栏照旧在导航栏下面。账号头像用 `InstanceAvatar`
  （按昵称取色），还没拉到用户时是 `person.crop.circle`。新任务没有首页入口了（规范 3.2：引导、快捷指令用 `.newTask`）。
- `ConversationText` 里旧首页的三句文案删了；`Greeting`（问候语）还在 `Screens/Welcome/`，登录、欢迎页用户自己设计，没动。
