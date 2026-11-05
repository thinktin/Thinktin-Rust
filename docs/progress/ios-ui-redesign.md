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
  每次启动带 `-cn.thinktin.onboarding.checked YES`（`OnboardingCheck` 的键写进 UserDefaults 参数域）：当时新账号第一次启动会弹引导盖住
  空状态；审查修正之后新账号不弹了（见下面“审查修正”），参数留着当保险。
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
  - 首页不会一直转圈：离线启动、这台设备上没有缓存，网络回来时先成功的是别的调用（设置、收件箱、角标），以前没人补拉实例列表，
    `homePlaceholder` 一直是 `.loading`。现在 `AppModel` 收到 `.reachable` 时实例列表没拉到过就 `refresh()`；刷新到一半网络回来的
    （实例那一步离线失败、角标成功）在 `refresh()` 末尾补拉一次。测试 `HomeListTests` 的“离线启动、没有缓存”（去掉修改时两种都挂）。
  - 第一次登录看到的是空的首页（用户 2026-11-05 定的“首次登录首页是空的”）：以前新用户登录进 `.onboarding`（`SignInModel.destination`），
    换新机时没有 Botin 也弹（`OnboardingCheck`），引导的 sheet 盖住了“还没有 Botin”，截图 `00-home-empty` 靠启动参数才截得到。现在
    `destination(after:)` 新老用户都是 nil；`OnboardingCheck` 只在有 Botin、没有 key 时弹（还没有 Botin 的，空状态就是引导；新建之后对话页的
    “还差一步”接着引导配路由、加 key）；引导从设置里打开。测试 `SignInModelTests`（新用户登录后没有 sheet）、`OnboardingModelTests`
    （新账号不弹、有 Botin 有 key 不弹、有 Botin 没 key 弹）。docs/ios.md 截图那段、规范 4.2.1、截图脚本的说明跟着改。
  - 给审核员看的说明换成新叫法：docs/ios-appstore.md 的审核备注（录屏“新建 Botin（起名字、选一个引擎）→ 配 key → …”、“给 Botin 配模型
    路由”、“预置的 Botin”，英文版加一句 Botin 和引擎是什么、“preloaded with a Botin and a key”），docs/ios-release.md 的 TestFlight 测试说明
    和审核账号同样改了。docs/handoff-ios.md 的“Botin 改名”加一条：上架材料（审核备注、商店描述、截图说明，安卓的商店材料）也照对照表写。
  - 要在模拟器上看的（Linux 的桩看不出来）：行内 `Picker` 的行上自己给的读屏标签念不念、选中的那行还念不念“已选中”；
    填了名字后下滑 sheet 是不是真的拦住（iOS 26 的 sheet 拦住时会回弹）。
  - 这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1024 个全过（新加“引擎详情要的引擎”“离线启动、没有缓存”）；
    uicheck UIKit、AppKit 都编过；`run.sh test` 137 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的：Info.plist 两条、
    隐私清单、小组件扩展、缓存路径）；`swift format -i` 没改东西，`swift format lint --strict -r apps/apple` 零条；`bash -n tools/apple/screenshots.sh` 过。
    macOS CI 和截图还没跑。
- 新建 Botin 照参考重排版式和头像外观（2026-11-05，用户对过参考图说分组 `Form` + 右上按钮不像；提交 `5d64c87`、`a743df2`、`a2d72d4`、
  `e8ce6eb` 和这一条）：
  - 视图模型（ThinktinKit）：名字**默认空的**（不再填引擎名），输入框下面的小字只在有用时出现（`AdoptionModel.nameNote`：只有空格、太长、快到
    上限）；`canCreate(isOffline:)`；头像 `shape`（默认圆形）、`color`（nil 按名字取）、`appearance`、`resolvedColor`，挑过形状或颜色也算
    `hasUserInput`；建好之后把外观记进 `appearances`（默认的不记、失败的不记）。新的 `ViewModels/Shell/InstanceAppearanceStore.swift`：
    `AvatarShape`（15 种）、`AvatarColor`（12 种；`nameHashed` 是第 0 轮按名字取色的 8 种，顺序不能改；FNV-1a 挪到这里）、
    `InstanceAppearance`（Codable，宽松地读：认不出的形状当圆形、颜色当没选）、`InstanceAppearanceStore`（`UserDefaults` 一个键
    `cn.thinktin.shell.instanceAppearance`，JSON `{实例 id: {shape, color}}`；`defaults` 为 nil 只在内存里），`AppModel.appearances`。
    许可：`NewBotinText.licenseCaption`（一行：专有许可“新建即表示同意 X 的许可条款”，同意的说法只给专有许可）、`licenseDetails`（全文）、
    `viewLicense`、`licenseTitle`、`noUsableEngine`；`engineFooter` 删了。
  - 界面：`AdoptAgentSheet` 换成 `ScrollView`：左上 ×、标题、右边不放按钮；120pt 头像预览（名字空时是中性的 `ellipsis`）；大号胶囊输入框
    （`.textFieldStyle(.plain)`、`.title2` 半粗、居中，占位“给 Botin 取个名字”）；头像卡片里形状网格 3 × 5 + 色板 2 × 6（选中带框 / 环，
    读屏念形状、颜色名和“已选中”，选择触感）；引擎卡片（“引擎”+ 系统 `Menu`，接入方式多于一个时再一行 `Picker(.menu)`）+“了解引擎 ›”；
    底部 `floatingBar` 里错误横幅、离线说明、许可小字 +“查看”（小 sheet）、整宽胶囊“新建”（`glassButtonStyle(.prominent)`，新建中转圈）。
    新的 `Components/AvatarShapes.swift`：15 种自己设计的形状（圆形、圆角方形、拱形、六边形、八边形、菱形、圆角三角形、盾牌、叶子、鹅卵石、
    四角星、五角星、花朵、花边圆、云朵；单位正方形里的几何，圆角多边形、超椭圆、极坐标曲线、三个圆拼的云），只放首字、不画脸；首字的字号和
    位置按形状调（`AvatarMonogramLayout`）。`InstanceAvatar` 加 `appearance:`（nil 是圆形、按名字取色），画法拆出 `AvatarGlyph`（按给的
    边长画，不跟动态字体缩放；形状网格的格子按列宽画，窄屏、大字号不挤出格子）；12 种颜色的色值在 `InstanceAvatar.colors(of:)`（前 8 种
    色值没变，新加藏青、兰紫、灰褐、石墨灰，白字对比度都在 4:1 以上）。首页的行、首页和搜索页的搜索结果（Botin 那种结果画头像）、对话页导航栏
    中间（24pt 头像 + 名字，`.principal`）、Botin 资料头部按 `app.appearances.resolved(for:)` 画。
  - 测试：ThinktinKit `InstanceAppearanceStoreTests`（网格大小、按名字取色没变、默认、记下读回和重开、宽松地读、`AppModel` 带一份）、
    `AdoptionModelTests`（空的默认名字、小字、“新建”能不能点、头像默认和跟着名字变、新建后记下外观、许可的一行和全文、都不能用的引擎）；
    `InstanceAvatarTests`（12 种颜色的对比度、15 种形状不出界、各形状和颜色深浅色都画得出来、名字空的占位）；`AgentsScreensTests` 的
    “新建之后”（空名字时按钮灰着、挑了花朵 + 青绿、建好后首页的行按它画）；`AppShellTests`、`SearchScreensTests` 画挑过外观的行。
  - 截图脚本没改：`08-adopt` 打开的就是空的新表单（不自动弹键盘，整张表都看得到）。
  - 要在模拟器上看的（Linux 的桩看不出来）：引擎 `Menu` 里选中项 `Label { Text; Text } icon:` 的副标题和勾显示得对不对、灰掉的项点不点得动；
    iOS 26 上底部条用 `safeAreaBar` 加了不透明的 `paper` 底（旧系统 `safeAreaInset` 要它挡住滚动内容），要不要只在旧系统加；键盘弹出时底部条
    跟着上来、许可小字太长时换行的样子；形状网格在最小的 iPhone 和最大的动态字体下格子的大小；15 种形状和首字的位置（重心偏下的三角形、
    星形、云朵的字往下挪了一点）深浅色下好不好看；大头像预览在 `.accessibility3` 下会很大（跟着动态字体缩放）。
  - 这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1034 个全过；uicheck UIKit、AppKit 都编过（AppKit 那边
    `MockClient.swift:1379` 有一条以前就有的未使用变量警告）；`run.sh test` 138 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要
    App 包的：Info.plist 两条、隐私清单、小组件扩展、缓存路径）；`swift format -i -r apps/apple` 后 `swift format lint --strict -r apps/apple`
    零条。macOS CI 和截图还没跑。
- 新建 Botin 重排版式的审查修正（2026-11-05，评审对 `a743df2` 之后提交的 12 条意见，逐条对过代码：10 条不重复，都是真的，都改了；
  “对话页导航栏两个 `.principal`”“名字胶囊点边上不聚焦”各报了两次；提交 `4ad444f`、`1f0c7f9` 和这一条）：
  - 对话页导航栏中间只有一项：`inlineNavigationTitle(title)` 本来就放了一个 `.principal` 的 `Text(title)`（没有 `PageHeader` 时一直显示），
    `a743df2` 又加了一个放头像 + 名字的，真机上两个都显示、读屏念两遍。`inlineNavigationTitle` 加重载 `(_:principal:)`（iOS 上用给的内容
    代替那行字；macOS 照旧只有导航标题），对话页用它放 `ConversationTitle`；默认那行字拆成 `InlineTitleText`。
  - 实例列表里还没有这个 Botin（冷启动的深链、推送，删掉了）：导航栏中间只写页面标题“对话”，不再画一个“对”字的头像。
  - 头像外观的存储不丢以后版本的值：以前认不出的形状当圆形、颜色当没选，读进来就丢了，下一次存（随便哪个 Botin 新建）把它们抹掉
    （TestFlight 装回旧版本就会碰到）。现在存原始的字符串（`StoredAppearance`），认不出的记录原样写回，只有那个 Botin 自己改外观、删掉时换掉。
  - 删了 Botin 删它的外观记录：`InstanceDetailModel(appearances:)`，`delete()` 成功（或者别处已经删了）后 `forget`；注销账号成功后
    `forget` 这个账号的 Botin（`DeleteAccountView`，注销前记下 id；只删这个账号的，同一台设备上别的账号的不动）。
  - 状态角标落在形状上：以前固定在方框右下角，四角星、叶子、菱形的右下角是空的，48pt 的行上角标离形状 4pt 左右、浮在外面。现在圆心放在
    从中心朝右下 45° 的射线和轮廓的交点上（`AvatarShapeGeometry.badgeAnchors`，`AvatarPathBuilder(recordsOutline:)` 把轮廓折成线段算的，
    启动后算一次）；放到角上会出方框的（圆形、圆角方形、八边形……）不挪，和以前一样。
  - 首字不小于 9pt（`AvatarMonogramLayout.fontSize(for:)`，也不超过圆形的比例）：24pt 的导航栏头像上四角星只有 6.2pt，汉字糊成一团。
  - 新建表单的大头像预览固定 120pt（`AvatarGlyph`，不跟动态字体缩放）：`InstanceAvatar` 跟着缩放，AX5 下约 374pt，比屏幕还宽。
  - 名字胶囊点哪儿都聚焦：`TextField` 只占中间那一行字，`.contentShape(Capsule())` 没有手势可用；手势放在胶囊底上
    （`.background { Capsule().onTapGesture }`），点到字那一行的还是输入框自己接，不和光标、选字抢；新建中不聚焦。
  - 引擎菜单里换成行内的系统 `Picker`（`.tag(AgentID?)`，系统打勾、读屏念“已选中”）：以前自己画勾、每项又换了读屏标签，读屏分不出选的是
    哪个，也不合 docs/ios.md 第 1 节第 5 条。每项是一个视图 `EngineOptionLabel`（两个 `Text`，副标题；用 `Group` 包会把 `.tag` 分给两个
    `Text`、变成两项）。
  - 许可小字：一行放不下时（英文、大字号）不再让“查看”挂在折行的字旁边：`ViewThatFits` 先试一行（小字 `lineLimit(1)` +“查看”），
    放不下换成小字居中折行、“查看”在下一行。英文的同意那句缩短成“By creating, you agree to the X terms”（375pt 的屏幕默认字号下一行放得下）。
    uicheck 桩补了 `ViewThatFits`。
  - 要在模拟器上看的（Linux 的桩看不出来）：导航栏中间的头像 + 名字只出现一次、读屏只念一遍；`Picker(.inline)` 放在 `Menu` 里时每项的
    副标题（`EngineOptionLabel` 的第二个 `Text`）显示不显示、`.disabled` 的项灰不灰、每项自己的读屏标签念不念（不念的话退回系统念名字和
    副标题，“已选中”照样有）；胶囊底上的点按会不会挡住输入框自己的点按（按说不会，输入框在上面）；四角星、叶子、菱形上角标的位置好不好看。
  - 这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1037 个全过（新加“以后的版本加的形状、颜色”“删掉一批
    Botin 的记录”“删掉了顺带删头像外观”）；uicheck UIKit、AppKit 都编过；`run.sh test` 140 个全过（新加角标位置、首字字号两条）；App 的
    `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的：Info.plist 两条、隐私清单、小组件扩展、缓存路径）；`swift format -i -r apps/apple`
    后 `swift format lint --strict -r apps/apple` 零条。macOS CI 和截图还没跑。
- 第 1 轮 B 线·对话页（规范 4.3，参考 02、03、06、07、118；用户 2026-11-05 要求“其他页面也照稿子 1:1 改”；提交 `b307428`、
  `372771c`、`11e22a9` 和这一条）：
  - 视图模型（ThinktinKit `ViewModels/Conversation/`）：`ConversationTimeSeparator`（运行之间的时间：第一组总有，隔 15 分钟以上或
    跨天才加；今天“今天 22:09”、昨天、一周内“星期二 02:22”、更早“10月29日 09:00”，往年带年份；`ConversationModel.timeSeparators`）；
    `MessageQuote`（引用回复的 Markdown 拼法、拆回、单行预览，引用最多 1000 个字符）；`ConversationModel.quotedText` / `setQuote` /
    `clearQuote` / `outgoingText`（字数、超限、发送都按带引用的整段算；发完清掉，失败留着；密码拦截存好后整段放回输入框）；
    `ConversationMenu` / `ConversationMenuItem`（“…”菜单的分组）、`MessageMenuLayout` / `MessageMenuAction`（长按菜单的分组）；
    `ConversationStarter` + `ConversationModel.starter` / `useSuggestion`（第一次进来的卡片：没配 main 是去配置，配好了是示例任务，
    默认模型还没拉到时先不出）；`ConversationText` 加了相应文案（示例任务四条，中英文）。
  - 界面：导航栏中间能点的标题（头像 + 名字 → Botin 资料），右上 `ellipsis` 菜单（`.topBarTrailing`）；agent 输出是左边的
    `agentBubble` 气泡、用户消息右边的 `userBubble` 气泡（开头的引用块画成一小块 `QuotedBlock`）；时间分隔、居中的来源行；
    `ComposerBar` 重写成浮动的玻璃胶囊（高 48、左右各留 32，主按钮 36pt 的 `glassProminent` 圆），有引用时长成圆角 28 的卡片、
    顶上一条引用和 ×；模型、排队、超限、字数是输入框上方的小玻璃胶囊；新文件 `MessageMenus.swift`（`messageMenu` 修饰符：系统长按
    菜单 + 读屏操作 + 选择文本的 sheet + 复制运行 ID 的触感）、`ConversationWelcome.swift`（参考 118 的首次状态）；卡片去掉描边、
    底色和气泡一样，按钮换成系统玻璃按钮（`smallCapsuleButton()`）；举报 sheet 换成 `Form`，密码拦截 sheet、运行详情、运行树、
    进行中的 `PillButton` / `EmptyStateView` 换成系统的；`Metrics.Radius.input` 删了（`DesignTokenTests` 跟着改）。
    `AgentsScreensTests` 里画 `ConversationSetupNote` 的两行换成 `ConversationWelcome`（那个视图删了）。
  - uicheck 桩：`SwiftUI+iOS.swift` 加 `UIViewRepresentable`，新文件 `UIKit/UIKit+Conversation.swift`（`UITextView`、`UIScrollView`、
    `UIFont.preferredFont(forTextStyle:)`、`UIEdgeInsets`、`UIColor.clear`）。桩里没有 `Group`、两个参数的 `onChange` 闭包、`AnyShape`、
    `truncationMode`，这次绕开了没补。
  - 测试：ThinktinKit 新 `ConversationLayoutTests`（时间分隔的写法和位置、引用的拼法和拆回、两个菜单的分组、带引用发送 / 超限 /
    失败 / 密码拦截、第一次进来的卡片、菜单跟着状态变）；`ConversationScreensTests` 加“改版的对话页”（首次状态两种卡片、时间分隔、
    带引用的消息和输入框、选择文本 sheet、长按菜单的内容）。
  - 参考里有、这次没做的：输入框的“+”（附件，6.13 要后端）、麦克风和语音按钮（6.23 不做）、长按的表情面板和“标为未读”（6.11）、
    “…”里的“在聊天中查找”（4.3.3，第 2 轮）、“分享为模板”（6.21）。示例任务点了是放进输入框（规范 6.18 写的是“点了就发出去”，
    放进输入框让用户改一改再发，不想要的话 `ConversationWelcome` 的 `onSuggestion` 里直接 `send()`）。
  - 要在模拟器上看的（Linux 的桩看不出来）：iOS 26 工具栏给 `.principal` 里的标题按钮套不套玻璃胶囊（不套的话自己加
    `glassBackground`）；输入框左右 32pt 在 375pt 宽的机器上挤不挤；`safeAreaBar` 下键盘弹起时输入框的位置；36pt 主按钮在
    `glassProminent` + `.circle` 下的实际大小；选择文本 sheet 里 `UITextView` 的边距和深色；长按气泡的预览外形；旧系统上小玻璃胶囊
    （`.regularMaterial`）压在滚动内容上的可读性。
  - 这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1048 个全过；uicheck UIKit、AppKit 都编过；
    `run.sh test` 141 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的）；`swift format -i -r apps/apple` 后
    `swift format lint --strict -r apps/apple` 零条。macOS CI 和截图还没跑。
- 第 1 轮 C 线·Botin 资料和引擎（规范 4.4.1–4.4.4、4.6.1、4.7.1 末尾、4.8.3、4.8.4；对过参考 09、10、12、18、65、27、28、101、104、
  105、106、107、52；提交 `4ef102d`、`71bf2a9`、`2828a6d` 和这一条）：
  - 视图模型（ThinktinKit `ViewModels/Agents/`）：新文件 `InstanceProfile.swift`：`InstanceDetailModel.activePlanCount`（没暂停、
    不在等确认的）、`plansAwaitingConfirmation`、`upgradeOption`（最新的比现在新，或现在的下架了）、`switchableVersions`（只有一个版本时为空）；
    `InstanceRouteStatus.defaultModelValue`（main 的上游模型 /“未配置”/ 没拉到 nil）；`InstanceProfileText`、`InstanceWorkspaceText`；
    “…”菜单 `InstanceProfileMenu` / `InstanceProfileMenuItem`（复制 ID；模型路由、新建计划；删除，`needsConnection`）；工作区说明
    `WorkspaceHelp`（状态四种 + 版本三条，状态名由界面传进来，和状态点旁边的字一致）。新文件 `InstanceAppearanceEditor.swift`（改头像：
    从记下的开始、`hasChanges`、`reset()`、`save()` 默认的删掉记录）。`AgentCatalogCard` 加 `isAvailable`、`rowSubtitle`、`actionTitle`、
    `actionAccessibilityLabel`。测试 `InstanceProfileTests`（9 条）。
  - 界面（`Screens/Agents/`）：`InstanceDetailScreen` 重写成 insetGrouped `List`（头部 80pt 头像 + 状态角标、名字、玻璃胶囊“编辑”；计划 /
    产出物 / 工作区；默认模型；所在团队；信息；右上“打开对话”圆 + `GlassToolbarSpacer(.fixed)` +“…”）；新 `InstanceEditScreen.swift`
    （编辑页：铅笔头像、“名称”、“外观 › 头像”，右上“完成”；`InstanceAvatarScreen` 改头像页）；新 `AvatarPicker.swift`（从新建表单挪出来
    共用，带可选的 footer）；新 `InstanceWorkspaceScreen.swift`（升级行、状态、引擎组和“换到别的版本”、右上“?”的 `WorkspaceHelpSheet`）；
    `InstanceDeleteSheet` 换成 `List` + 浮动的红色整宽胶囊 + `CloseButton`；`AgentCatalogScreen` 换成 plain 列表的 `EngineRow`
    （`EngineIcon` 40pt 圆角方块）+“选这个”胶囊，点行弹 `AgentDetailScreen` 的 sheet；`AgentDetailScreen` 换成插件详情的版式
    （`AgentDetailAction`，sheet 时交给目录在 `onDismiss` 里走路由）。这个目录共用的小帮手放在 `InstanceDetailScreen.swift` 末尾：
    `AgentsToolbar.trailing`、`insetGroupedList()`（macOS 是 `.inset`）、`clearListRow()`、`InstanceWorkspacePreview`。
    删掉：`InstanceRenameSheet`、`AgentsNameField`、`InstanceHeader`、`InstanceVersionRow`、`InstancePlanRow`、`AgentCatalogCardView`。
  - uicheck 桩：`SwiftUI+Agents.swift` 加 `dynamicTypeSize(_:)` 的范围版本。`InsetGroupedListStyle` 早就有（`SwiftUI+Lists.swift`），别再加。
  - 测试：`AgentsScreensTests` 的“改名表单”换成“编辑页、头像页、工作区和它的说明”，加“引擎详情当 sheet”，卡片换成 `EngineRow`。
  - 和参考对不上、自己定的（等用户看）：资料页右上第一个圆参考是分享，这里放“打开对话”；参考的“通知”开关（6.14）、头像页的“生成 / 上传”
    分段、编辑页的“语音通话”组没做；资料页、编辑页、头像页的头像按参考量出来是 80pt（规范 2.4 写的 120 / 100 没改令牌，页面里用
    `ProfileAvatarMetrics.size`）；资料页多了“默认模型”“所在团队”“信息”三组（ThinkTin 有、参考没有）；工作区页参考是“重置电脑”“磁盘空间”
    （要后端），这里是升级 / 状态 / 版本；引擎行上不再写“N 个 Botin 在用”（详情里列出来）。
  - 要在模拟器上看的（Linux 的桩看不出来）：资料页导航栏中间空着时 iOS 26 会不会把右上两个圆挤到别处；`navigationDestination(isPresented:)`
    挂在 `List` 上、在 sheet 的栈里（领养 → 目录 → 详情 → Botin 资料 → 编辑）压不压得进去；编辑页 `Form` 里按钮做的“头像”行和系统
    `NavigationLink` 的箭头像不像；`InstanceAvatar` 加 `.dynamicTypeSize(...xxxLarge)` 之后角标还在不在轮廓上；引擎详情 sheet 在
    medium 档时底部胶囊浮在内容上的样子；目录行里玻璃小胶囊和整行按钮是不是各点各的；删除确认页红色 `.prominent` 胶囊在 iOS 26 玻璃上
    的颜色。
  - 这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1056 个全过；uicheck UIKit、AppKit 都编过；`run.sh test`
    142 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的：Info.plist 两条、隐私清单、小组件扩展、缓存路径）；
    `swift format -i -r apps/apple` 后 `swift format lint --strict -r apps/apple` 零条。macOS CI 和截图还没跑。

- 第 1 轮 D 线·计划列表（规范 4.5.1，对过参考 21；2026-11-05）：`PlanListScreen` 换成 insetGrouped
  `List`（右上玻璃“+”，Botin 资料进来的只看这个 Botin、不显示筛选，工作台进来的第一行是 `FilterChipBar`），一行 `PlanRow`
  （状态图标、单行标题、灰色副标题、状态行），左滑 / 长按暂停、恢复、删除；空着时正中一段说明 +“新建计划”（`ContentUnavailableView`）。
  视图模型：`PlanListModel.scopeInstanceID`、`showsInstanceFilter`、`placeholder`（`PlanListPlaceholder`），`PlansText.listEmptyMessage`、
  `awaitingFooter`、`rowSubtitle`；测试 `PlanListModelTests` 加两条，`PlansScreensTests` 加一个 Botin 的计划和 `PlanRow`。
  `PlansFilterChip`、`PlanListRow`、`PlanAwaitingCard` 删掉；触发器编辑器“规则的写法”换成 `FilterChipBar`。C 线放在
  `InstanceDetailScreen.swift` 末尾的 `insetGroupedList()`、`clearListRow()` 挪到 `Components/ListStyles.swift`，`AgentsToolbar.trailing`
  改名 `ToolbarSlot.trailing`（同一个文件）。
  计划详情（参考里没有）也换成 insetGrouped `List`（居中头部、提示行、目标、规则、策略 `LabeledContent`、步骤、运行历史、最后一组
  暂停 / 删除，右上 `ellipsis`）；`PlanStepsView.stageTitle` 改成静态的（带语言参数）；`PlanTriggerRow` 的两个按钮换成系统小胶囊。
- 第 1 轮 D 线·产出物（规范 4.5.2、4.5.3，对过参考 22–26、81–84；2026-11-05）：库换成 insetGrouped `List`（“全部 / 媒体 / 文件”胶囊、
  按日期分组、28pt 缩略图、行尾 AI 标识、超过 20 个“展开”，全部 Botin 的按 Botin 筛选挪到右上菜单）；新的图片全屏查看
  `ArtifactImageViewer`（纯黑底、× 和“…”：分享、保存到相册、详情）；详情换成 `List` + 底部“预览 / 分享” + “…”里删除。
  视图模型：新文件 `ArtifactLibraryLayout.swift`（`ArtifactCategory`、`ArtifactDateGroup`、`ArtifactSection`、库的 `kind` / `filtered` /
  `count(of:)` / `sections()` / `hasMore` / `expand()` / `placeholder`、`ArtifactThumbnailLoader`）、`ArtifactViewerModel.swift`、
  `ArtifactsText` 加类型名、副标题和查看页的文案；测试 `ArtifactLibraryLayoutTests`（7 条），`ArtifactsScreensTests` 加改版的库和查看页。
  Info.plist（project.yml）加 `NSPhotoLibraryAddUsageDescription`，App 的 Info.plist 测试和 docs/ios-appstore.md 3.3 跟着改。
  uicheck 桩：新模块 `Stubs/ImageIO`（`CGImageSource`、缩略图的几个键，`CFData` 当 `Data`）和 `Stubs/Photos`（`PHPhotoLibrary`、
  `PHAssetCreationRequest`），`Package.swift` 里 ThinktinUI 依赖它们。
- 第 1 轮 D 线·搜索（规范 4.2.4，对过参考 78、79、80；2026-11-05）：新的 `SearchResultsView`（顶上筛选胶囊，没输入时列 Botin 或
  “搜索消息”，有字时“全部”分组、一类不分组，一行 40pt 头像 + 粗体“你发给 X / X 发给你” + 右边时间 + 灰色摘录），首页搜索栏一激活
  就换成它（`HomeSearchResults` 删掉，A 线的 `HomeScreen.swift` 只动了这一块和关搜索时重置筛选），iOS 26 搜索时藏导航栏
  （Glass.swift 的 `hidesNavigationBarWhileSearching`）；压栈的 `SearchScreen` 也用它。视图模型：`SearchModel.filter` / `filters` /
  `suggestions` / `filteredLimit`，`SearchResult.instanceID` / `direction`（`SearchMessageDirection`），运行拆成任务、摘要两条；
  `SearchText.filterTitle` / `searchKind` / `messageTitle` / `date` / `kindLabel`，运行那组改叫“消息”。测试 `SearchModelTests` 加两条、
  改一条，`SearchScreensTests` 加改版的几种状态，`AppShellTests` 的首页搜索换成 `SearchResultsView`。
- 第 1 轮 D 线·和参考对不上、自己定的（等用户看）：计划空状态多一个“新建计划”按钮、右上多一个“+”（参考只能在对话里让 Bot 建）；
  产出物的“链接”换成“文件”（没有链接的数据，6.19 C）；全部 Botin 的产出物按 Botin 筛选放在右上菜单（参考没有这个维度）；图片查看的
  “转发”换成“详情”（转发要后端）；搜索的“群聊”换成“收件箱”、“文件”是产出物、“定时任务”是计划（6.24 A）；消息只搜任务和摘要，
  没搜回复正文；搜索时 iOS 17 / 18 不藏导航栏（搜索栏挂在导航栏下面）。计划详情、产出物详情参考里没有，按 Botin 资料的路子排的。
- 第 1 轮 D 线·要在模拟器上看的（Linux 的桩看不出来）：iOS 26 首页搜索时 `toolbarVisibility(.hidden, for: .navigationBar)` 会不会连底部条的
  搜索栏一起藏、筛选胶囊在 `safeAreaBar(edge: .top)` 里是不是贴着状态栏下面；`FilterChipBar` 当 `List` 第一行（透明行、`horizontalInset: 0`）
  左边和分组卡片对不对齐；产出物行尾 `AIGeneratedLabel` 挤不挤名字；缩略图 ImageIO 解码的清晰度和 `aspectRatio(.fill)` 裁切；图片全屏查看
  `fullScreenCover` + iOS 18 缩放转场从行里的缩略图放大是否顺；`Color.black` 上 `.preferredColorScheme(.dark)` 的玻璃按钮；存相册第一次弹权限、
  拒绝后的 alert；产出物详情底部两个胶囊在 `safeAreaBar` 里压不压内容；计划列表左滑两个按钮的颜色；计划详情头部 Botin 小胶囊。
- 第 1 轮 D 线这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1067 个全过；uicheck UIKit、AppKit 都编过；
  `run.sh test` 144 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的：Info.plist 两条（这次多了
  `NSPhotoLibraryAddUsageDescription`）、隐私清单、小组件扩展、缓存路径）；`swift format -i -r apps/apple` 后
  `swift format lint --strict -r apps/apple` 零条。macOS CI 和截图还没跑。
- 第 1 轮 E 线·设置根页、外观、语言、触感（规范 4.9.1、4.9.11–4.9.13，对过参考 53、70、75、72、73、74；2026-11-05）：
  视图模型：`SettingsModel.sections(_:pendingApprovals:)` 按参考重排成 8 组（账号 / 连接 / Botin / 偏好 / 安全 / 链接 / 关于 / 退出登录，
  `SettingsSection.title` 可空）、`todayUsage` + `refreshUsage()`、`accountTitle`、`approvalsSubtitle`、`versionFooter`；`SettingsRow` 加
  `isProfile`，`Action` 加 `.haptics`、`.link(URL)`，去掉 `.deleteAccount`（注销挪进账号页）；新文件 `ViewModels/Models/UsageToday.swift`
  （东八区今天的零点、按 key 的每日上限进度 `UsageGauge`、根页那一行的值）；`SettingsPreferences.hapticsEnabled`、`HapticsText`；
  `LegalLinks`（`AccountLinks` 指过去）。界面：`SettingsScreen` 换 insetGrouped `List`（账号行 `SettingsProfileRow`、`SettingsRowLabel`、
  `ExternalLinkRow`、版本区 `SettingsVersionFooter`、通知是跳系统设置的 `Toggle`）；`AppearanceTile` 三个方块；语言 `Picker(.inline)`；
  新 `HapticsSettingsView`；实时活动那组变成 `List` 里的 `Section`；新 `Design/Haptics.swift`（`\.hapticsEnabled`、`appFeedback`，5 处
  `.sensoryFeedback` 换掉）。测试：`SettingsModelTests` 重写分组 / 入口 / 账号行，加审批、用量、版本区；`SettingsPreferencesTests` 加触感；
  新 `UsageTodayTests`（4 条）；`SettingsScreensTests` 加根页、方块、触感页。纯黑外观没做（第 2 轮）。
- 第 1 轮 E 线·账号、用量（规范 4.9.2、4.9.3，对过参考 54、55；2026-11-05）：账号页换 insetGrouped `List`（头像行、个人资料、红字退出登录、
  垃圾桶注销 + 脚注），改昵称页换 `Form` + `ConfirmButton`；`StopAllRow` 换成系统的 destructive 按钮行（账号页不再放安全那组，设置根页有）。
  用量页换 insetGrouped `List`，顶上“今天”一组按 key 的每日上限画系统 `Gauge`（`UsageModel.todayGauges` / `loadToday()`，测试
  `UsageModelTests` 的“今天”），明细行用 `NavigationLink(value:)`；`ModelsUnavailableView` 换成 `ContentUnavailableView`。
- 第 1 轮 E 线·保险箱（规范 4.9.5、4.9.6，对过参考 57、58、59；2026-11-05）：列表换 insetGrouped `List` + 筛选胶囊（`VaultFilter`、
  `VaultModel.filter` / `count(of:)` / `shows(_:)` / `isEmptyForFilter`，`VaultText.empty` / `footer` / `purposeFooter` / `deleteMessage`，
  测试 `VaultModelsTests` 的“筛选胶囊”），条目左滑删除；新建 / 修改表单改成压栈的 `Form`（`VaultLabeledField` 标签在上、密码眼睛、
  多行提示）；条目详情、填写请求换 `List` / `Form`。uicheck 桩补了 `Group`、`fontDesign(_:)`、`fontWeight(_:)`（`SwiftUI+Settings.swift`）。
- 第 1 轮 E 线·登录设备（规范 4.9.9，对过参考 66、67、69；2026-11-05）：列表换 insetGrouped `List`（`DeviceRow` 状态点 + 图标 + 名字 +
  `DeviceInfo.listSubtitle`，左滑下线，“下线其他设备”单独一组），新的 `DeviceDetailScreen`（本地压栈；名称、状态、类别、登录时间；电脑多
  `ComputerDeviceSections` 配对和授权；红字下线），电脑的整体状态挪成 `ComputerLinkStatusSection`；`SignOutOthersSheet` 换 `Form`。
  视图模型：`DeviceInfo.kindName` / `listSubtitle` / `isActive`（测试在 `AccountTextTests`）。

决定（2026-11-04）：用户问“发的那套 UI 怎么没照着改”，按规范第 6 节的建议开工，用户随时可以改：
6.1 A + A1（实例列表为根、去掉抽屉，抽屉的入口放首页左下“工作台”）；6.2 C（中性灰底和卡片、强调色留橙色、agent 回复加气泡、
字体全用系统的）；6.3 A（保持 iOS 17，iOS 26 的接口在 Design/Glass.swift 里回退）；6.4 A（“+”直接弹领养表单）；6.5 A（设置用 sheet）；
6.6 A（沿用“实例”，2026-11-05 被下面的决定推翻）。其余 18 项按建议。

决定（2026-11-05，用户）：代码里的“实例”（`Instance`）在界面上叫 **Botin**（中英文同一个词，英文复数 Botins）。用户“新建 Botin”，不再“领养 agent”；
新建时选它用哪个 agent 当引擎，同一个 agent 可以给好几个 Botin 当引擎（服务端只限每个账号的实例数）。agent 在界面上只以 Botin 的“引擎”/“Engine”出现。
首次登录首页是空的，空状态“还没有 Botin”+ 说明 + “新建 Botin”按钮。代码里的标识符（`Instance`、`AppRoute.adopt`、`adopt(...)`）不改。

进行中：第 1 轮 E 线（设置一带：设置根页、账号、用量、保险箱、登录设备、外观、语言、触感、模型 key、IM 渠道；规范 4.9、7.3 E），
  session_01GuCp3KRgqaK6Kzynw6udRn，2026-11-05 开始。B、C、D 线 2026-11-05 做完，见“已完成”。
验证和发版（2026-11-05，session_01GuCp3KRgqaK6Kzynw6udRn）：GitHub 的 Mac 一直排不上，改用 Codemagic（`.github/workflows/codemagic.yml`：
把提交推到 `codemagic/apple-check` / `codemagic/ios-screenshots`）。第 0 轮（bbdb07c）、Botin 版（06894fd）、新建页重做（c78064e）
的 apple-check 都过了（真 Xcode：模拟器 build + test、ThinktinMac、Kit 的 macOS 测试）。截图对照参考 34、35 后又调了两次版式：
引擎卡片挪到名字下面并压成一行（`6afee36`、`e23b47f`），形状格子最大 56pt（`4d5ded8`），现在一屏放得下。
TestFlight：28（Botin 改名、空状态，旧表单）、30（新建页重做，第二排色点要滑一下才看得到）都是演示版，从本分支用 `builder=codemagic`
打的；29 取消了（旧版式）。`4d5ded8` 还没打包，下次一起。
新建 Botin 表单（照参考重排过版式、带头像外观，审查修正也做了）和首页空状态（2026-11-05）、Botin 改名（2026-11-05）做完了，见“已完成”。
**第 0 轮（规范 7.2）的每一行和审查修正都做完了**（2026-11-05），只差下面第 1、2 条的验证；第 1 轮还没人认领。

下一步：
0. Botin 改名的收尾：(a) 登录页 `SignInFlow` 的两句“你的常驻 agent”“agent 在云端常驻”要不要改成 Botin，问用户（登录页是他设计的）；
   (b) 安卓和服务端推送照 docs/handoff-ios.md 的“Botin 改名”对照表改（别的会话的线，这里没动）；(c) 新建表单已经是“+”直接弹、表单里选引擎
   （见“已完成”），要在模拟器上看一眼（下面第 1、2 条，`08-adopt`、`00-home-empty` 两张）；安卓的新建流程要不要跟着改另议；
   (d) 演示数据里 agent 的介绍（“通用 agent”）是仿服务端目录的，等服务端的清单改了再跟；(e) 第一次登录已经按用户的决定改成只看首页空状态、
   不弹引导（见“已完成”审查修正那条）；用户要是还想要第一次登录弹引导，改回 `SignInModel.destination(after:)` 和 `OnboardingCheck` 就行。
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
3. 第 1 轮五条线并行（规范 7.3，开工前先在这里认领）；第 2 轮纯客户端新功能；第 3 轮等后端。B、C 线做完了；C 线没做的只剩要后端的
   （资料页“通知”开关 6.14、工作区重置和磁盘 6.17、观看与接管 4.6.2、头像的生成和上传、多端同步 6.9 B）。A 线（首页）接着做：长按菜单（4.2.2）、
   “等你处理”提示行、预览换成最近一次运行的摘要（6.7）、`NewTaskSheet` 换选择器版式（4.4.5）；`SearchResultsView` 嵌进首页和空查询列 Botin
   D 线已经做了（`HomeScreen.swift` 只动了搜索那一块）。B 线（对话页）做完了，接着可以做第 2 轮的对话内查找（4.3.3，“…”菜单第一组
   Botin 资料后面加一项）。D 线做完了，剩下的：计划的新建 / 编辑表单（`PlanEditorScreen`）、确认页（`PlanConfirmScreen`）、触发器编辑器
   （`TriggerEditorView`）、时区和预授权工具的选择页还是自画版式（`PageHeader`、`GroupedSection`、`Card`、`PillButton`、`PlansTextField`），
   按第 2 节换成 `Form`；搜索回复正文（本机缓存的事件，4.2.4，第 2 轮）。E 线（设置一带）还没人认领。

坑和决定：
- 改版页面共用的列表帮手在 `Components/ListStyles.swift`：`insetGroupedList()`、`clearListRow()`、`ToolbarSlot.trailing`（C 线时叫
  `AgentsToolbar.trailing`，D 线挪出来改了名）。筛选胶囊放 `List` 第一行时 `FilterChipBar(..., horizontalInset: 0)` + `.clearListRow()`。
- 产出物：大类、日期分组、折叠都在 ThinktinKit 的 `ArtifactLibraryLayout.swift`；缩略图要下整份文件，`ArtifactThumbnailLoader` 限 4 MB、
  一次打开 30 张，下过的（包括失败的）记在库的视图模型里。图片解码只用 ImageIO（`ArtifactImageDecoder`），不用 `UIImage` / `NSImage`，
  iOS 和 macOS 一套；uicheck 有 `Stubs/ImageIO`（`CFData` 当 `Data`）和 `Stubs/Photos`，ThinktinUI 依赖它们。
- 存相册只在 iOS（`#if os(iOS)`，`PhotoLibrarySaver`，`nonisolated` 的静态函数，免得 Photos 的对象跨 actor）；ThinktinKit 的
  `ArtifactViewerModel.save(using:)` 只管状态，保存的办法由界面传进来，测试里传闭包。
- 搜索：一次运行是两条结果（任务 `key` 是运行 id，摘要是 `运行 id/reply`），`SearchResult.title` 对消息来说是 Botin 名，界面用
  `SearchText.messageTitle` 拼。首页搜索栏一激活（`isSearchPresented`）就换成 `SearchResultsView`，关掉时 `search.filter = nil`。
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
- 新建表单：`AdoptionModel` 的初始化是 `init(client:agents:instances:preselectedAgentID:appearances:)`，没有 `agent` / `existingNames` 了；
  建好之后不再查能用的 key（`usableCredentials`、`nextStep` 删了），路由页自己会说缺什么 key。引擎选择现在是系统 `Menu`，里面放行内的
  `Picker(.inline)`（系统打勾、读屏念“已选中”，别再自己画勾），目录多了菜单自己能滚；每项的 `.disabled` 在真 SDK 上灰不灰没验过，视图模型的
  `selectEngine` 会拦不能用的。每项要是一个视图（`EngineOptionLabel`），别用 `Group` 包两个 `Text` 再 `.tag`（会变成两项）。
- 头像外观：`AvatarShape` / `AvatarColor` 的原始值存进了 `UserDefaults`，**不能改名**；`AvatarColor.nameHashed` 的顺序也不能改（按名字取色
  按下标取，换了已有的 Botin 会变色）。加形状、颜色往 `allCases` 后面加，网格是 3 × 5、2 × 6，多了要改网格。服务端加头像字段时取值用这些
  原始值（6.9 B），本机的存储当缓存或删掉。形状是自己画的几何（`AvatarShapes.swift`），别换成参考 App 的形象，也别画脸。
  存储读写的是原始字符串（`StoredAppearance`）：认不出的形状、颜色原样写回，别改成读进来就换成默认的（装回旧版本会抹掉新版本挑的）。
  加了形状要看一眼 `badgeAnchors`（角标落在右下方的轮廓上，自动算的）和 `AvatarMonogramLayout`（字号比例，24pt 上不小于 9pt）。
- 对话页的菜单项改 ThinktinKit 的 `ConversationMenu`（“…”）和 `MessageMenuLayout`（长按），界面照着画；加了项要补 `systemImage`
  （`ConversationMenuItem` 认不出的路由是兜底的 `chevron.right`，测试会抓）。长按菜单统一用 `messageMenu(_:previewShape:)`，
  别再直接 `.contextMenu`（读屏操作、选择文本的 sheet、触感都在那个修饰符里）。
- Botin 资料这一组：编辑页、头像页、工作区页都是本地压进去的（`navigationDestination(isPresented:)` / `NavigationLink(destination:)`），
  没有路由，深链进不来；要从别处直达再加 `AppRoute`。资料页的“…”菜单项改 ThinktinKit 的 `InstanceProfileMenu`，加了项要补 `systemImage`
  和 `needsConnection`。改头像只存这台设备（`InstanceAppearanceEditor.save()`），服务端加字段后改这里。
- 引擎详情从目录弹的是本地 sheet，按钮的操作要等 sheet 关掉（`onDismiss`）再走路由：sheet 还开着时 `router.open(.adopt…)` 弹第二张会被系统
  丢掉。`.agent(id)` 路由现在没有界面入口，留给以后的深链。
- 引用回复是纯客户端的：发出去的就是带 `> ` 的 Markdown，服务端不知道回的是哪条（6.11 B 要后端）。要改拼法改 `MessageQuote`，
  `split` 要能拆回 `compose` 拼的样子（测试里有）。
- 输入框（`ComposerBar`）的结构是固定的（引用条、输入行、卡片的按钮行都是可有可无的一项），切换引用时输入框不重建、不丢焦点；
  改布局时别把 `TextField` 挪进 `if` / `else` 的两个分支。
- 导航栏中间要放自己的内容（头像 + 名字、以后的标题胶囊）用 `inlineNavigationTitle(_:principal:)`，别在 `inlineNavigationTitle(title)`
  外面再加 `.principal`：它自己已经放了一个，两个都会显示。
- 新建表单：引擎详情是从表单压进去的时候，`Router.present(.adopt(agentID: id))` 不叠第二张，退回表单、记 `engineRequest`；
  只认最前面那层是 `.adopt` 的情况，别的照常弹。表单在栈底下也活着，`onChange(of: router.engineRequest)` 照样收到。
- `AppModel.openCreatedInstance` 先把新 Botin 塞进列表再 `selectInstance`、再刷新。刷新正在进行时 `refresh()` 直接返回：要是那次刷新的
  请求是在新建之前发的，回来的旧列表里没有新 Botin，`reconcileSelection` 会把它的对话拿掉。要很慢的网络才碰得到，没处理，碰到了再说。
- 启动屏：`brand_assets.py` 自己写 PDF（只用标准库），`LaunchLogo` 高 60pt、宽约 43.8pt，矩阵保留 6 位小数（3 位会让 Logo 变成 60.2pt、
  偏一点）。颜色从 `Theme.swift` 的 `public var light` / `dark` 两个 switch 里按正则读：改那两个 switch 的写法要跟着改脚本。
