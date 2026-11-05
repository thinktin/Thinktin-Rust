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
- 第 0 轮·截图脚本（规范 7.2 截图那一行、7.6 的清单）：
  - `AppConfiguration`：只有 Debug 认的启动环境变量 `THINKTIN_OPEN_SCREEN`（`openScreenEnvironmentKey`、`OpenScreen` 枚举、
    `openScreen(environment:)`，不分大小写，认不出的不认）：conversation / plans / artifacts / settings / search / adopt。
    `AppConfiguration.swift` 还是只依赖 Foundation（macOS App 也编它）；打开的办法在 iOS App 的新文件 `App/OpenScreen.swift`：
    `route(instanceID:)` 和 `open(in:)`：实例的页面先等实例列表拿到（最多 10 秒），取首页第一行（演示数据里是“写作助手”），
    然后和深链一样走 `Router.show`：对话是“首页 → 对话”，计划、产出物是“首页 → 对话 → 目标页”，设置、领养弹 sheet，搜索回首页
    留一个搜索请求（首页出现时补上激活）。`ThinktinApp` 的 `.task` 在 `THINKTIN_OPEN_URL` 之后调它。
  - `tools/apple/screenshots.sh`：清单换成规范 7.6 的 14 张（首页、对话、实例资料、实例的计划、产出物、设置、保险箱填写请求、领养、
    首页搜索、审批、收件箱、进行中、运行、计划），浅色、深色各一套，文件名 `01-home-light.png` / `01-home-dark.png`（产物还是平铺的
    `*.png`，两个工作流的 artifact 路径不用改）。清单是一段文本、从 3 号描述符读（bash 3.2 下不用数组，`simctl` 吃不掉）。新加
    `IOS_RUNTIME=18`（或 `17.5`）只在那个 iOS 版本的模拟器里挑，看 iOS 17 / 18 的回退（7.6 第 3 条）。
  - 测试（App 的 `AppSmokeTests`，挨着原来的启动参数测试）：六个值和别的值、每页的路由（实例的页面没有实例时为 nil）、演示数据里打开
    各页面后的返回栈和 sheet（实例列表没拿到时实例的页面不打开）。
- 第 0 轮·启动屏（规范 4.1.1、2.9，7.2 启动屏那一行）：`tools/apple/brand_assets.py` 多生成 `Assets.xcassets/LaunchLogo.imageset`
  （高 60pt 的单色矢量 PDF，浅色、深色两版，脚本自己写 PDF，只用标准库；路径和 `BrandLogo` 同一套贝塞尔，颜色同 `ink`，即
  `BrandLogo(style: .monochrome)`；保留矢量数据）和 `LaunchBackground.colorset`（和 `paper` 同值）；两个颜色从 `Theme.swift` 读。
  project.yml 的 `UILaunchScreen` 填上 `UIColorName` / `UIImageName`。`--swift-only` 换成 `--no-icons`（只写 Swift 代码和启动屏）；
  `--check` 先查 Swift 代码和启动屏是不是最新的（逐字节），再照旧和原稿比像素（0 差）。PDF 用 pdftoppm 栅格化后和原稿（单色）比过：
  线条都在原稿 ±1 像素以内，差的只是两个渲染器的抗锯齿。图标重跑后逐字节没变。测试：`DesignTokenTests` 加“启动屏底色和 `paper`
  同值、Logo 两版、保留矢量”（从 `#filePath` 往上找仓库根，uicheck 的复制件也找得到），App 的 Info.plist 测试加两个键（macOS CI 查）。
- 第 0 轮最后这一份（截图脚本、启动屏、docs/ios.md 收尾）的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test`
  1007 个全过；uicheck UIKit、AppKit 都编过；`run.sh test` 137 个全过（新加启动屏那条）；App 的 `ThinktinTests` 19 个过 14 个（新加的
  3 条 `OpenScreen` 都过；挂的还是那 5 个要 App 包的，Info.plist 那条多了启动屏两个键）；`brand_assets.py --check` 过（Swift 代码和
  启动屏是最新的，贝塞尔版和原稿 0 差）；`swift format lint --strict` 零条。docs/ios.md：开头和第 1 节第 4 条不再写“参考某某 App”，
  改指改版规范；第 2 节 App/ 的说明；第 4 节加共用组件（`InstanceAvatar`、`FilterChipBar`）、4.1 加启动屏；第 7 节截图换成新清单和两个
  启动变量。规范 7.2 末尾记“第 0 轮做完”，7.6 的旧系统截图改成 `IOS_RUNTIME`。
- 第 0 轮·审查修正（2026-11-05，评审对 `123c510` 之后第 0 轮提交的 12 条意见，逐条核对后 12 条都是真的，都改了；
  提交 `1396836`、`aba4465`、`e3e2548` 和这一条）：
  - 对话、运行详情里 agent 写的 `thinktin://` 链接改走新的 `Router.openLink(_:)`（按 `open` 的规则压在眼前这一层上），
    不再走 `handle(url:)`（那个是外面进来的，会关 sheet、把返回栈重建成“首页 → 目标页”，对话页和输入框里的草稿就没了）。
  - 新的 `Router.removeRoutes(where:)`：各层栈（主栈、sheet 的栈、第二层的栈）里拿掉符合的页面，根页面符合的 sheet 关掉；
    计划详情删掉后离开、确认页换成详情都用它（计划页现在可能在 sheet 的栈里：领养 → agent → 实例资料 → 计划）。
    计划详情从流水线编辑器回来的刷新改看 `visibleRoute`。
  - 新任务请求照搜索请求的办法补上：`handledNewTaskRequest`、`hasPendingNewTaskRequest`、`newTaskRequestHandled()`；
    对话页 `onAppear` 和 `onChange(of: newTaskRequest)` 都看，只认当前实例的（从首页进对话时页面在请求之后才建）。
    退出登录时丢掉没处理的。
  - 添加 key 做完点“给 X 配模型路由”：先 `dismissSheet()` 再 `open(.modelRoutes)`，路由页压在底下那层（主栈或设置的栈）上；
    以前压进添加 key 这层 sheet 的栈，路由页的“添加 key”再弹添加 key 是原地不动。
  - 首页：plain 列表的行（实例行、错误横幅、搜索结果、“还有 N 条”、只搜了缓存的提示）加新的 `themedPlainRow()`（行底透明）：
    `themedGroupedBackground()` 只藏列表的底，系统照样给 plain 列表的行铺 `systemBackground`（深色纯黑）；Theme.swift 的说明和
    docs/ios.md 第 4 节改了。搜索结果的行、“还有 N 条”也藏分隔线（规范 2.5）。
  - 首页左上的账号按钮不再藏工具栏的玻璃（去掉 `hidesSharedGlassBackground()`），24pt 头像（`Metrics.Avatar.title`）放在玻璃圆里，
    和右上的“+”一样（规范 4.2.1）。帮手留着（`NativeControlsTests` 用）。
  - 工作台按钮的读屏：标签只是“工作台”，数由角标当值念（旧系统 `ToolbarBadgeOverlay` 的值，iOS 26 系统的 `.badge`），
    `ShellBadges.workbenchAccessibilityLabel` 删掉（以前标签里带数，旧系统上念两遍）；角标的字和值挪到 `ToolbarBadgeText`。
  - 首页离线又没有缓存：空状态的说明换成“这台设备上还没有保存的实例，联网后会自动刷新。”，不再和顶部横幅的“显示的是缓存内容”打架。
  - 首页的搜索请求推迟一拍再激活（`Task` 里 `Task.yield()` 后设 `isSearchPresented`），绑定还是 true 时先放下再拉起：iOS 26 底部条里的
    搜索栏从代码激活可能要等底部条装好（Apple 论坛 798018 / FB20068224 说的是 `searchFocused`；`isPresented` 有没有这个问题、
    推迟一拍够不够，都要在 iOS 26 模拟器上看截图 09-search 和从压栈的页面 `open(.search)`）。
  - 设置 → 账号 → 昵称的说明不再说“显示在侧边栏”，改成“显示在首页左上角的头像和这台设备上”。
  - 截图的旧系统回退在 CI 上也能出了：`ios-screenshots.yml` 加 `workflow_dispatch` 的 `ios_runtime` 输入和 `ios-screenshots-ios*` 分支
    （分支名里带版本），产物名带版本；`codemagic.yaml` 加环境变量 `IOS_RUNTIME`（发起构建时改）；`screenshots.sh` 在没有那个版本的
    iPhone 模拟器时自己建一台，运行时没装时先 `xcodebuild -downloadPlatform` 下载，`IOS_RUNTIME` 不是版本号就停。规范 7.6、
    docs/ios.md 第 7 节写了怎么触发。脚本的挑选、建机逻辑用假的 `xcrun` 在 Linux 上跑过（18、18.6、没装的 17.5、非法值），真机没跑过。
  - 还要在 iOS 26 模拟器上看的（Linux 的桩看不出来）：搜索栏从代码激活（上面那条）；`onAppear` 里聚焦输入框；账号按钮的玻璃圆和
    24pt 头像的比例；工作台按钮 iOS 26 系统角标读屏念不念数（不念的话数就丢了，要在标签里补回来）；plain 列表行底透明后的深色。
  - 这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1011 个全过；uicheck UIKit、AppKit 都编过；`run.sh test`
    138 个全过；App 的 `ThinktinTests` 19 个过 14 个（还是那 5 个要 App 包的）；`swift format lint --strict` 零条。macOS CI 还没看。
  - 测试：`RouterTests` 加“App 里点的链接”“页面没了从哪层拿掉”“新任务请求补上一次”“添加 key 之后去配路由”；
    `AppShellTests` 加“工作台按钮的读屏只念一次数”；`AppModelTests` 的工作台标签那几行换成名字。
- Botin 改名·第 1 步（ThinktinKit 的文案，2026-11-05）：`AppRoute` 标题（`.adopt` “新建 Botin”、`.instance` “Botin 资料”、
  `.agentCatalog` “引擎”、`.agent` “引擎详情”）、对话页头（“Botin 正在创建…”“正在唤醒 Botin…”）、引导（“新建 Botin”，说明改成
  “起个名字、选一个引擎”）、搜索（分组“Botin”、占位“搜 Botin、任务、…”）、实例数上限（“Botin 数已达上限，删掉不用的再新建。”）、
  “已删除的 Botin”、保险箱、用量“按 Botin”、模型路由、key 详情、流水线步骤、团队说明（模板“一键新建一整套”）、紧急停止、注销说明、
  实时活动的说明、关于页一句话；agent 目录卡片的“已领养 N 个”换成“N 个 Botin 在用”，接入方式说明里的 agent 换成“引擎”。
  英文用 Botin / Botins，“adopt”换成 create。断言这些文案的测试跟着改（ThinktinKit `swift test` 1011 个全过）。
- Botin 改名·第 2 步（界面和 App，2026-11-05）：首页空状态换成用户定的文案（新的 `HomeText`：“还没有 Botin”+“Botin 是替你干活的助手……”+
  按钮用 `.adopt` 的标题“新建 Botin”；离线没缓存那句也在里面），测试在 `HomeListTests`；Botin 资料（“删除这个 Botin”“创建于”“引擎版本”、
  头部“引擎：Claude Agent · v…”）、删除确认页、新建表单（标题“新建 Botin”，按钮“新建”，名字“Botin 的名字”，多一行只读的“引擎”，
  许可脚注“新建即表示你同意按上面的条款使用这个引擎”，“建好了”）、引擎目录（“选一个引擎”，说明同一个引擎能给好几个 Botin 用）和引擎详情
  （“用它新建 Botin”“在用它的 Botin”“这个引擎已经下架了”）、新任务选择（“交给哪个 Botin？”）、计划、流水线、团队（模板的按钮“新建团队”，
  读屏“用模板“X”新建团队”）、保险箱、模型路由、key、用量里的“实例”。快捷指令：类型和参数名“Botin”，标题“给 Botin 下任务”，
  Siri 短语“给${applicationName}的 Botin 下任务”/“Give a ${applicationName} Botin a task”，两个 xcstrings 跟着换键（键按码点排序，格式和 Xcode 存的一样）。
  顺带把同一句里、同一个文件里明显指“干活的那个”的 agent 换成 Botin（引导、保险箱、待审批快捷指令的说明）。
- Botin 改名·第 3 步（其余界面上的“agent”，2026-11-05）：按“agent 在界面上只以引擎出现”，指干活的那个的 agent 都换成 Botin
  （对话里的审批、填账号密码、计划确认，计划、审批、收件箱、产出物、模型 key 和路由、用量、保险箱、设置、账号、登录设备、紧急停止、
  冻结页、语言、AI 生成内容说明、关于页、电脑配对和 Mac 菜单栏）；指引擎程序本身的换成“引擎”（“引擎出错了”“引擎意外退出，正在重启”、
  开源许可页的“引擎”一节）；“负责人 agent”改成“负责人”。产品名（Claude Agent、Hermes Agent、Agent Client Protocol、Claude Agent SDK）、
  事件种类、演示数据里服务端给的 agent 介绍没动。**登录页（`SignInFlow`）的两句“你的常驻 agent”“agent 在云端常驻”没改**：登录页是用户
  自己设计的，等用户定。
- Botin 改名·文档（2026-11-05）：规范 docs/ios-ui-redesign.md 开头的叫法说明、6.6（记下用户的决定，推翻原来的建议）、6.4（已定：“+”弹
  “新建 Botin”，起名字、选引擎）、4.7.1（标题、引擎行、按钮“新建”，同一个引擎能建好几个）、4.2.1（空状态的文案）、表格和 7.3 C 线；
  docs/ios.md 第 1 节第 6 条（界面用词规则）和几处引到的文案；docs/handoff-ios.md 加“Botin 改名”一节：给安卓、服务端推送的对照表，
  点名 `crates/orchestrator/src/texts.rs` 里给用户看的推送和 IM 文案、`crates/catalog` 的介绍（安卓、服务端的代码没动）。
- Botin 改名这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1012 个全过（新加首页空状态文案那条）；uicheck
  UIKit、AppKit 都编过；`run.sh test` 138 个全过；App 的 `ThinktinTests` 19 个过 14 个（还是那 5 个要 App 包的）；
  `swift format lint --strict -r apps/apple` 零条。macOS CI 还没看。
- 新建 Botin 表单（规范 4.7.1 改过的版式，2026-11-05）：首页“+”、空状态的“新建 Botin”、引擎详情的“用它新建 Botin”都打开
  `.adopt(agentID:)` 这张 sheet（`AdoptAgentSheet`，`AgentsDestination` 不再把它换成目录 / 详情）。原生 `Form` + `.formStyle(.grouped)`：
  头像预览（`InstanceAvatar`，按名字取色）；名字 `TextField`（占位“给它取个名字”，问题或提示在分组脚注里，规则还是 `InstanceNameRule`，
  默认填引擎名、重名加序号，用户没改过时换引擎名字跟着换）；引擎是行内 `Picker`（每行名字 + 一句话介绍，不能用的灰掉、选不了），接入方式
  多于一个时再一行 `Picker(.menu)`，“了解引擎”`NavigationLink` 压进引擎目录；许可证和在哪运行的说明是引擎分组的脚注
  （`NewBotinText.engineFooter`）。左上 `CloseButton`（自己填了名字时先确认“不建这个 Botin 了？”），右上 `ConfirmButton("新建")`
  （新建中转圈，读屏“正在新建”；`ConfirmButton` 加了 `workingLabel`）。错误（包括 Botin 数上限）在表单里的 `ErrorBanner`；离线时一组说明和
  “重新检查网络”。建好了调 `AppModel.openCreatedInstance`：先把新 Botin 放进列表，`selectInstance` 关掉 sheet、从首页压栈进它的对话，再刷新。
  - 视图模型 `AdoptionModel` 改成带引擎选择的：`init(client:agents:instances:preselectedAgentID:)`、`load()` 拉目录、`selectEngine(_:)`、
    `engineOptions(_:)`（`EngineOption`）、`defaultEngine`（预选的 → 最近活跃的 Botin 用的引擎 → 目录里第一个能用的）、`hasUserInput`。
    “能不能用”是 `AgentInfo.canPowerNewBotin`：服务端目录还没有下架 / 地区这类字段，现在只有没给接入方式的算不能用，以后在这里接。
  - 以前“建好了”页（`AdoptionDoneView`、`AdoptionExit`、领养后查能用的 key）删了；配模型路由的提示挪到对话页：还没有任务、没配 main 时
    空状态下面一句“还差一步……”和“配置模型路由”按钮（`ConversationModel.needsSetupNote`、`ConversationText.setupNote`、
    `ConversationSetupNote`）；没有能用的 key 时路由页自己引导加 key。
  - 引擎详情是从表单的“了解引擎”压进去的时候，“用它新建 Botin”不再叠第二张表单：`Router.present` 看到最前面那层是 `.adopt`，就拿掉那层栈上的
    页面、记下 `engineRequest`，表单 `onChange` 时换引擎（`engineRequestHandled()`）。别处（主栈、设置里）的引擎详情照常弹表单。
  - `SheetStack.addsCloseButton` 不再给 `.adopt` 补 ×（表单自己有）。`AgentsNameField` 挪到 `InstanceDetailScreen.swift`（只剩改名用）。
- 首页空状态（2026-11-05）：显示什么挪到 ThinktinKit 的 `HomeList.placeholder` / `AppModel.homePlaceholder`（`.loading`、
  `.offlineWithoutCache`、`.noBotins`；有行、刷新失败时为 nil）。联网拉到了、没有 Botin 才是“还没有 Botin”（`ContentUnavailableView`，
  按钮 `.glassButtonStyle(.prominent)` + `.controlSize(.large)`，打开同一张表单）；离线不管拿没拿到过都是第 0 轮那句“这台设备上还没有保存的
  Botin”。演示数据加了 `DemoData.newAccountState()`（刚注册的账号：没有 Botin 和它们的运行、计划、团队、产出物、收件箱，也没有 key），
  `ShellPreviewClients.empty()` 用它。
- 首页空状态的演示数据和截图（2026-11-05）：`AppConfiguration.mockEmptyEnvironmentKey`（`THINKTIN_MOCK_EMPTY`，`1` / `true` / `yes`），
  只有 Debug 构建、用 Mock 时认（`startsWithEmptyAccount`），`AppEnvironment.live` 这时用 `DemoData.newAccountState()`；scheme 的 Run 里
  加了一项（默认不勾）。`tools/apple/screenshots.sh` 清单加第四列 THINKTIN_MOCK_EMPTY，新加 `00-home-empty`（浅色、深色），产物 30 张；
  每次启动带 `-cn.thinktin.onboarding.checked YES`（`OnboardingCheck` 的键写进 UserDefaults 参数域）：新账号第一次启动会弹引导盖住空状态。
  `08-adopt` 现在截到的是新表单。测试在 App 的 `AppSmokeTests`（开关的取值、只认 Debug + Mock、新账号首页是 `.noBotins`、表单照样打开）。
  docs/ios.md 截图那段、apps/apple/README.md、规范 7.6 的截图表跟着改。
- 别的“新建 Botin”入口也弹表单（2026-11-05）：引导里的“新建 Botin”一步、没有 Botin 时的“新任务”（`AppModel.startNewTask`）、
  新任务选择里的“新建 Botin”（叠成第二层）、对话页“找不到这个 Botin”的按钮（改成“新建 Botin”）；以前都进引擎目录。引擎目录现在只从
  表单的“了解引擎”和下架引擎的“看看别的引擎”进。规范 3.3 的表、4.2.1、4.7.1（改写成现在的样子）、7.3 C 线（表单已做）跟着改。
- 这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1022 个全过；uicheck UIKit、AppKit 都编过；`run.sh test`
  137 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的：Info.plist 两条、隐私清单、小组件扩展、缓存路径）；
  `swift format lint --strict -r apps/apple` 零条；`bash -n tools/apple/screenshots.sh` 过，清单循环在 Linux 上用桩函数跑过一遍（30 张）。
  macOS CI 和截图都还没跑。
- 新建 Botin 和首页的审查修正（2026-11-05，评审对 `bbdb07c` 之后提交的 7 条意见，逐条对过代码）：
  - 新建表单引擎选择器的一行读屏念 `EngineOption.accessibilityLabel`（名字、介绍、“N 个 Botin 在用”）：以前 `.combine` 只念看得见的
    名字和介绍，有介绍的引擎念不到几个 Botin 在用，那个帮手和它的测试没有调用处。
  - 中文按钮“创建”改成“新建”（和标题“新建 Botin”、转圈的读屏“正在新建”、许可脚注“新建即表示你同意……”一致），测试和规范 4.7.1 跟着改。
  - 自己填了名字的表单不能下滑关掉（`.interactiveDismissDisabled(isAdopting || hasUserInput)`），只能点 ×、先确认；以前下滑直接丢掉。
  - 从“了解引擎”进引擎详情点“用它新建 Botin”时表单自己的目录还没拉到（打开时那次拉失败了，或者压上目录时被取消了）：以前请求被丢掉、
    回来按默认的引擎选；现在 `AdoptionModel.requestEngine(_:)` 先记下，`load()` 拉到后先选它（能用的话），之后自己选了别的以自己选的为准。
    测试 `AdoptionModelTests` 的“引擎详情要的引擎”。

决定（2026-11-04）：用户问“发的那套 UI 怎么没照着改”，按规范第 6 节的建议开工，用户随时可以改：
6.1 A + A1（实例列表为根、去掉抽屉，抽屉的入口放首页左下“工作台”）；6.2 C（中性灰底和卡片、强调色留橙色、agent 回复加气泡、
字体全用系统的）；6.3 A（保持 iOS 17，iOS 26 的接口在 Design/Glass.swift 里回退）；6.4 A（“+”直接弹领养表单）；6.5 A（设置用 sheet）；
6.6 A（沿用“实例”，2026-11-05 被下面的决定推翻）。其余 18 项按建议。

决定（2026-11-05，用户）：代码里的“实例”（`Instance`）在界面上叫 **Botin**（中英文同一个词，英文复数 Botins）。用户“新建 Botin”，不再“领养 agent”；
新建时选它用哪个 agent 当引擎，同一个 agent 可以给好几个 Botin 当引擎（服务端只限每个账号的实例数）。agent 在界面上只以 Botin 的“引擎”/“Engine”出现。
首次登录首页是空的，空状态“还没有 Botin”+ 说明 + “新建 Botin”按钮。代码里的标识符（`Instance`、`AppRoute.adopt`、`adopt(...)`）不改。

进行中：没有人在做。新建 Botin 表单和首页空状态（2026-11-05）做完了，见“已完成”里“新建 Botin 表单”往下几条；
Botin 改名（2026-11-05）也做完了。
**第 0 轮（规范 7.2）的每一行和审查修正都做完了**（2026-11-05），只差下面第 1、2 条的验证；第 1 轮还没人认领。

下一步：
0. Botin 改名的收尾：(a) 登录页 `SignInFlow` 的两句“你的常驻 agent”“agent 在云端常驻”要不要改成 Botin，问用户（登录页是他设计的）；
   (b) 安卓和服务端推送照 docs/handoff-ios.md 的“Botin 改名”对照表改（别的会话的线，这里没动）；(c) 新建表单已经是“+”直接弹、表单里选引擎
   （见“已完成”），要在模拟器上看一眼（下面第 1、2 条，`08-adopt`、`00-home-empty` 两张）；安卓的新建流程要不要跟着改另议；
   (d) 演示数据里 agent 的介绍（“通用 agent”）是仿服务端目录的，等服务端的清单改了再跟；(e) 新账号第一次登录会先弹引导（12.17），
   首页空状态在它下面：两个都是引导新建 Botin，要不要第一次登录不弹引导、只看空状态，问用户。
1. macOS CI（`.github/workflows/ios.yml`，只在推 main 和开 PR 时跑）还一次都没跑过这个分支：开 PR 或推一次让它用真 SDK 编。只有它验得出来的：
   Glass.swift 的 `if #available` 分支；首页工具栏（`#if os(iOS)` 里的 `ToolbarContent`、菜单项的两行 `Text`、`toolbarBadge` 在 iOS 26 上的
   `.badge`、`BottomBarSearchItem`）；`SheetStack` 里第二层 `.sheet(item:)`；`AgentsDestination` 的 `.adopt(agentID: nil)` 模式；启动屏
   （`UILaunchScreen` 的两个键、`LaunchLogo` 的 PDF 和颜色集能不能被资源编译器收下，Info.plist 测试查键）；`DesignTokenTests` 在模拟器上
   顺着 `#filePath` 读仓库里的颜色集（模拟器进程读宿主机的文件，按说可以，没验过）；App 测试里 `OpenScreen` 那三条。
2. 出一次截图对照（规范 7.6 第 3 条）：`git push -f origin HEAD:ios-screenshots`（或 Actions 里手动跑 iOS screenshots），产物 30 张；
   再出一套 iOS 18 的回退：`git push -f origin HEAD:ios-screenshots-ios18.6`（或 Run workflow 填 `ios_runtime`），产物
   `ios-screenshots-ios18.6`；镜像里没有那个运行时脚本会先下载（`xcodebuild -downloadPlatform iOS -buildVersion 18.6`，没在 CI 上跑过，
   失败的话看日志换版本号）。顺带看 09-search 里搜索栏有没有激活（iOS 26 底部条，见“已完成”审查修正那条）。和参考截图并排看
   （参考截图在仓库外，要请用户再发），差别记到这里。冷启动后的启动屏截不到，要在模拟器或真机上看一眼。
3. 第 1 轮五条线并行（规范 7.3，开工前先在这里认领）；第 2 轮纯客户端新功能；第 3 轮等后端。A 线（首页）接着做：长按菜单（4.2.2）、
   “等你处理”提示行、预览换成最近一次运行的摘要（6.7）、`SearchResultsView` 嵌进首页（D 线先交）、空查询时列实例、`NewTaskSheet`
   换选择器版式（4.4.5）。B 线做对话页时注意下面“坑”里 `newTaskRequest` 那条。

坑和决定：
- 参考截图是别家产品、里面有用户的账号信息，仓库公开，所以**不进仓库**；规范里只用自己的话写布局和交互，不写参考 App 的名字。以后的会话要看截图，请用户再发一次压缩包。
- 路由：sheet 里的页面要刷新别看 `router.sheet == nil` 或 `router.topRoute`（`topRoute` 只看主栈），看 `router.visibleRoute`；
  要知道自己是从哪个页面弹出来的看 `router.routeBelowSheet`。`NavigationLink(value: AppRoute)` 在 sheet 里压进 sheet 的栈（`SheetStack` 绑了
  `sheetPath`），设置根页面的行就是这样进子页的；sheet 页用 `NavigationLink(value:)` 打开会被压栈（引导在设置里就是这样），
  要弹出就用 `router.open`。sheet 被系统下滑关掉时 `Router.sheet` 的 `didSet` 清掉它的栈和第二层。
- 路由：对话改成压栈后 `.conversation(id)` 的新建页拿不到 `newTaskRequest` 的变化（页面在请求之后才建）：已经照搜索请求补上
  （`hasPendingNewTaskRequest`，对话页 `onAppear` 时看）。压栈动画中途在 `onAppear` 里设 `@FocusState` 在真机上灵不灵还没验过，
  不灵就推迟一拍再设（B 线做对话页时看）。
- 路由：App 里点的链接用 `openLink`，外面来的（`onOpenURL`、推送、小组件）才用 `handle(url:)` / `show`。删页面、换页面别直接改
  `router.path`（页面可能在 sheet 的栈里），用 `removeRoutes(where:)`。
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
- 首页：iOS 17 / 18 上底部条只有工作台菜单（`BottomBarSearchItem` 不放东西），搜索栏照旧在导航栏下面。iOS 26 上
  `BottomBarSearchItem` 的搜索栏从代码激活（`open(.search)`、深链、截图 09-search）还没在真 SDK 上验过，见“已完成”审查修正那条。
  账号头像用 `InstanceAvatar`（按昵称取色，24pt，放在工具栏的玻璃圆里），还没拉到用户时是 `person.crop.circle`。
- plain 列表的行要加 `themedPlainRow()`，分组列表的行加 `themedRow()`；只加 `themedGroupedBackground()` 行底还是系统的。新任务没有首页入口了（规范 3.2：引导、快捷指令用 `.newTask`）。
- `ConversationText` 里旧首页的三句文案删了；`Greeting`（问候语）还在 `Screens/Welcome/`，登录、欢迎页用户自己设计，没动。
- 截图参数：`THINKTIN_OPEN_SCREEN` 打开的是“首页第一行”，不是写死的 id：演示数据里写作助手 2 分钟前活跃、代码审查 10 分钟前，所以是
  写作助手（和截图脚本里 `thinktin://instance/$writer` 是同一个）。演示数据的时间改了，这一点要跟着看。实例的页面要等实例列表拿到才打开
  （最多 10 秒），设置、领养、搜索不等。`AppConfiguration.swift` 保持只依赖 Foundation（macOS App 也编它），用到路由的在 `OpenScreen.swift`。
- 截图脚本是 bash 3.2 写法：清单是一段文本、`while read … <&3` 从 3 号描述符读，不用数组；启动变量总是都传，不用的传空串（App 不认空的）。
  清单第四列（THINKTIN_MOCK_EMPTY）可以不写。每次启动带 `-cn.thinktin.onboarding.checked YES`：`OnboardingCheck` 的键名改了要跟着改。
- 新建表单：`AdoptionModel` 的初始化换成 `init(client:agents:instances:preselectedAgentID:)`，没有 `agent` / `existingNames` 了；建好之后
  不再查能用的 key（`usableCredentials`、`nextStep` 删了），路由页自己会说缺什么 key。引擎选择用的是行内 `Picker(.inline)`：目录现在 3 个，
  多到一屏放不下时换 `.navigationLink` 样式（收起时那一行会把选中项的两行字都显示出来，iOS 18 起可以给 `currentValueLabel`）。
  每行的 `.disabled` 在真 SDK 的行内选择里灰不灰没验过，视图模型的 `selectEngine` 会拦不能用的。
- 新建表单：引擎详情是从表单压进去的时候，`Router.present(.adopt(agentID: id))` 不叠第二张，退回表单、记 `engineRequest`；
  只认最前面那层是 `.adopt` 的情况，别的照常弹。表单在栈底下也活着，`onChange(of: router.engineRequest)` 照样收到。
- `AppModel.openCreatedInstance` 先把新 Botin 塞进列表再 `selectInstance`、再刷新。刷新正在进行时 `refresh()` 直接返回：要是那次刷新的
  请求是在新建之前发的，回来的旧列表里没有新 Botin，`reconcileSelection` 会把它的对话拿掉。要很慢的网络才碰得到，没处理，碰到了再说。
- 启动屏：`brand_assets.py` 自己写 PDF（只用标准库），`LaunchLogo` 高 60pt、宽约 43.8pt，矩阵保留 6 位小数（3 位会让 Logo 变成 60.2pt、
  偏一点）。颜色从 `Theme.swift` 的 `public var light` / `dark` 两个 switch 里按正则读：改那两个 switch 的写法要跟着改脚本。
