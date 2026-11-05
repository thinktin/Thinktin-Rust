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
- 第 1 轮 E 线·模型 key、IM 渠道（规范 7.3 E，参考里没有；2026-11-05）：key 列表、key 详情、IM 渠道列表和编辑页换 insetGrouped `List` /
  `Form`；`ModelsCredentialRow` 不再自己画按钮、边距和箭头（外面包 `NavigationLink`），标签换成 `CredentialSummary.tagsLine`（测试在
  `CredentialsModelTests`）；`modelsKeyboard(_:)` 改成模块内可用。key 的三个小 sheet 只换了工具栏按钮（字段还是 `ModelsField`）。
- 第 1 轮 E 线·模型路由、关于（2026-11-05）：`ModelRoutesScreen` 换 insetGrouped `List`（`RouteSection` / `FallbackRows`，key 用系统
  `Picker(.menu)`，推荐模型是 `Menu` 里的行内 `Picker`，保存只在右上），`AboutScreen` 换 `List`（`BrandLogo` 头部、版本、备案、条款、
  AI 说明）。
- 第 1 轮 E 线·和参考对不上、自己定的（等用户看）：设置根页的“订阅”“连接应用”“自动设置时区 / 时区”“Bot 电脑”“导入记忆”“帮助中心”
  “发送反馈”没有（要后端或不做），“连接应用”的位置放 IM 渠道，“权限”的位置放审批（进审批中心），多了“安全”一组（全部停止、下线其他设备）
  和“关于 / 开源许可 / 上手引导”一组；通知是开关但拨了去系统设置（App 自己关不掉推送）；账号页没有“切换 / 添加账户”，改昵称是压栈页不是
  弹窗（要显示字数）；用量页“今天”只列设了每日上限的 key（没有平台额度），下面保留 7 / 30 / 90 天的看板；保险箱的胶囊是“全部 / 条目 /
  等你填写 / 处理过的”，“+”直接进表单（只有一种条目），表单没有“网站”；设备名称行不能点（改名要后端），电脑详情是配对和授权而不是三档
  执行策略，“移除电脑”是“下线这台设备”，另有“解除配对”；外观的方块选中是橙色的突出按钮（参考是灰），没有第二排；触感照参考做成子页
  （规范 4.9.13 原来建议根页一行开关）。
- 第 1 轮 E 线·要在模拟器上看的（Linux 的桩看不出来）：设置根页没有标题时 iOS 26 左上的 × 和第一组的间距；账号行 44pt 头像和
  `NavigationLink` 箭头；通知 `Toggle` 拨了以后弹回原位（get 读的是系统权限）、回前台重读；版本区 `BrandLogo` 在透明行里深浅色；外观方块
  `glassButtonStyle` + `.roundedRectangle(radius: 16)` 在 iOS 26 / 17 上的样子和选中的对比；语言 `Picker(.inline)` 去掉 label 后的勾；用量页
  `Gauge(.linearCapacity)` 的 tint；保险箱 `FilterChipBar` 当第一行的对齐、左滑删除、`navigationDestination(isPresented:)` 在设置的 sheet 栈里
  压不压得进去、密码眼睛切换时 `Group` 里两个输入框换来换去丢不丢焦点；设备详情里电脑那组（只在真机能签名时出现）；下线其他设备 sheet
  的红色浮动按钮（`.tint(danger)` + `.prominent`）；模型路由里 `Picker(.menu)` 的行、`Menu` 里放行内 `Picker` 的推荐模型；`appFeedback` 关掉
  触感后真的不震。
- 第 1 轮 E 线这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1077 个全过；uicheck UIKit、AppKit 都编过（没有警告；
  中途 AppKit 报过保险箱 `@Bindable var model` 被 `Task` 闭包捕获的并发警告，局部变量改名 `bindable` 后没了）；`run.sh test` 145 个全过；
  App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的：Info.plist 两条（这次没有新键）、隐私清单、小组件扩展、缓存路径）；
  `swift format -i -r apps/apple` 后 `swift format lint --strict -r apps/apple` 零条。macOS CI 和截图还没跑。

- 第 1 轮 A 线·首页补完（规范 4.2.1–4.2.3、6.7 B、6.10 A，对过参考 01、32、33、110–116、119、120；2026-11-05）：
  - 版式照参考量（393pt 宽，1pt ≈ 1.525px，常量在 `HomeLayout`）：行高约 83pt、44pt 头像（`Metrics.Avatar.list` 48 → 44，
    `DesignTokenTests` 跟着改）离左边 22pt、文字从 82pt 起、时间离右边 24pt。行换成按钮（`Router.open(.conversation)`），
    不再是 `NavigationLink`（plain 列表里会画 chevron，参考没有）。
  - 预览照 6.7 B：闲着时是缓存里的最后一条（ThinktinKit `HomeLastMessage.latest(in:)`：最近一次的摘要带“AI 生成”标识，
    没摘要、是你发的写“你：…”，计划派的跳过），`HomeRowPreview.message`；`AppModel.lastMessages` 启动读缓存，刷新完、回到首页
    （`reloadLastMessages()`）重读。
  - 置顶、隐藏只存这台设备（新 `InstancePreferencesStore`，仿 `InstanceAppearanceStore`：一个 `UserDefaults` 键、按实例 id、不分账号；
    互斥，隐藏时取消置顶；删 Botin、事件流说没了时删记录）；`HomeList.content` 分成置顶 / 普通 / 隐藏三部分（`HomeListContent`），
    `AppModel.homeContent`；`homeRows` 现在是看得见的（置顶的在前）。`HomePlaceholder.allHidden`。
  - 界面（`Shell/Home/`）：`PinnedInstancesGrid`（80pt 头像 + `.footnote` 名字，一排 3 个、每排居中，104pt 一格）；长按
    `HomeInstanceMenuContent`（一列不分组 + “更多”原地展开，顺序在 ThinktinKit `HomeInstanceMenu`）+ 预览卡 `HomeInstancePreviewCard`；
    左滑 `HomeInstanceSwipeButtons`（隐藏、置顶）；改名 `HomeRenameAlert`（系统弹窗 + 输入框，调新的 `AppModel.renameInstance`）；
    删除弹资料页那张 `InstanceDeleteSheet`，删成了走 `InstanceDetailScreen.leaveDeletedInstance`（这个函数现在顺带删置顶、隐藏的记录）；
    复制 ID 有触感。都隐藏了是 `HomeAllHiddenView`（参考 113），部分隐藏时列表底下一行“已隐藏 N 个 Botin”；`HiddenInstancesScreen`
    （本地压栈，参考 114、116）和 `HidingHelpSheet`（参考 115，文案 `HomeText.hidingFacts`）。
  - 测试：ThinktinKit 新 `InstancePreferencesStoreTests`（6 条）、`HomeListTests` 加 6 条（三部分、最后一条、预览、菜单、改名、缓存重读）；
    `AppShellTests` 加 2 条（最后一条和预览卡；置顶、隐藏、空状态、已隐藏页、说明、菜单），首页进对话那条改成 `Router.open`。
    uicheck 桩加 `Color.gray`（新文件 `Stubs/SwiftUI/SwiftUI+Home.swift`）。
- 第 1 轮 A 线·和参考对不上、自己定的（等用户看）：长按菜单里参考的“标为未读”“新建分组”“替换主 Bot…”“分享为模板”换成 Botin 资料、
  新建计划、改名…（ThinkTin 没有前几个，6.10、6.21）；“更多”里多了删除；行的预览前面放的是“AI 生成”标识（参考是个小图标）；
  已隐藏页的标题原来用系统的 inline 标题（审查修正后照参考放进玻璃胶囊）；首页底下多一行“已隐藏 N 个 Botin”（参考只有全部隐藏时才有入口）；
  说明 sheet 的三行是 ThinkTin 自己的话（多了“只在这台设备上”）。
- 第 1 轮 A 线·要在模拟器上看的（Linux 的桩看不出来）：长按预览卡的宽度和圆角（系统给预览卡包了一层圆角）；左滑两个按钮在 iOS 26
  上是不是玻璃圆、“置顶”的灰；`swipeActions` 的“隐藏”带 `.destructive`，行会被系统先拿掉再由数据拿掉，看有没有闪；置顶一排 3 个在
  最窄的 375pt 屏上放不放得下；已隐藏页（审查修正后是路由 `.hiddenBotins`）上点一行进对话（压在它上面）以后返回是回到已隐藏页；从上下文菜单直接弹改名的 alert、删除的 sheet
  会不会被菜单收起的动画吞掉（B 线的“选择文本”也是这样直接弹的）；左上账号头像参考里约 36pt、几乎填满玻璃圆（我们是第 0 轮审查后
  定的 24pt），试 36pt 会不会把 iOS 26 的玻璃撑大，不会就改大。
- 第 1 轮 A 线这一份的 Linux 检查（2026-11-05）：ThinktinKit `swift test` 1089 个全过；uicheck UIKit、AppKit 都编过（没有警告）；
  `run.sh test` 147 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的）；`swift format lint --strict` 零条。
- 第 1 轮收尾线·收件箱和审批（参考里没有，照第 2 节；2026-11-05）：收件箱换成 plain 列表、不画分隔线（照首页的消息列表：40pt 种类图标、
  未读圆点 + 加粗标题、右边时间、两行灰色正文、种类和 AI 标识），左滑删除 / 标已读未读、长按同样的菜单（每行的“…”按钮去掉），右上玻璃
  “全部已读”，“N 条未读”是列表顶上一行灰字，空状态 `ContentUnavailableView`；一条通知的页换成分组列表（居中 56pt 图标头部、标题和全文一组、
  “查看…”一行，右上 `ellipsis` 菜单）。审批中心换成分组列表：顶上一句灰色说明，电脑发来的一组（`ComputerApprovalsSection` 变成原生
  `Section`），每个审批一张分组卡片（24pt Botin 头像和名字、剩余时间用警告色、标题和 AI 标识、操作摘要，选项是全宽的玻璃胶囊，第一个批准类
  的突出，最后一行“查看详情”）；审批详情同一张卡片 + “查看这次运行”（`NavigationLink`）“去对话”一组。电脑配对、授权两张 sheet 换成
  `Form`（配对码用新的 `FormTextField`，“配对”是底部浮动的全宽胶囊，左上 `CloseButton`；授权的有效期换成 `Picker(.menu)`，右上
  `ConfirmButton("签名授权")`），Mac 菜单栏面板的胶囊按钮换成系统按钮。新的共用组件 `Components/FormFields.swift`：`FormTextField`
  （标签在上、系统输入框、提示 / 问题和字数，代替自画框的 `PlansTextField`）和 `numberInput()` / `codeInput()`。
- 第 1 轮收尾线·团队、流水线、新任务、引导、冻结 / 升级页（参考里没有，照第 2 节和参考 11、62 的版式；2026-11-05）：团队列表换成分组列表
  （顶上一句灰字，“我的团队”一行是负责人头像、名字、“负责人 · N 个成员”，`NavigationLink` 进详情；“团队模板”一行右边小玻璃胶囊“新建团队”，
  左滑 / 长按删除；没有时组里一行灰字，照参考 62 的“暂无规则”；右上玻璃“+”）。团队详情照 Botin 资料页：居中的成员头像叠在一起 + 名字
  `.title2.bold()` + 成员数，成员一组（头像、名字、角色，`NavigationLink` 进资料页，右边小胶囊“配模型”，配模型的说明挪到组脚注），
  “用这个团队建流水线”“存为模板”一组，红字“删除团队”一组，右上“编辑”。团队编辑照参考 11 的选择器（规范 4.4.5）：左上 `CloseButton`、
  右上 `ConfirmButton("保存")`，名字（`FormTextField`）、成员（头像 + 名字，选中的右边系统勾）、负责人（`Picker(.menu)`，只列选中的成员），
  `.searchable` 筛成员，没有 Botin 时 `ContentUnavailableView`。流水线编辑器换成 `Form`：每步一组，组标题“第 N 步”右边 `ellipsis` 菜单
  （上移、下移、删除），执行的 Botin 换成 `Picker(.menu)`，依赖一行一步、选中打勾，问题写在组脚注；“加一步”一组，脚注“共 N 步，最多 20 步”；
  保存 / 创建换成 `ConfirmButton`。新任务的 Botin 选择（`NewTaskSheet`）照参考 11：左上 ×、右上“确认”，一行一个 Botin（40pt 头像带状态角标、
  名字、状态），默认选当前的，`.searchable`，最后一组“新建 Botin”，没有 Botin / 没搜到用 `ContentUnavailableView`（以前点一行就走，现在先选再
  “确认”）。引导换成分组列表：居中标题和说明，四步一组（序号圆、标题、说明，当前这一步下面一个小玻璃胶囊），底部浮动的全宽胶囊“以后再说 /
  完成”。冻结页、升级页换成系统 `ContentUnavailableView` + 大尺寸玻璃按钮。共用的 `LabeledRow`（图标、标题、灰色说明的行内容，代替
  `ListRow`）放在 `Components/ListStyles.swift`。
- 第 1 轮收尾线·运行树、进行中、开源许可、注销、对话里的卡片（2026-11-05）：运行树换成分组列表（节点一行，按层缩进，`NavigationLink` 进运行
  详情，打开时指定的那个行底用 `userBubble` 高亮；没结束的右边红色停止键，也能左滑、长按停止；子步骤在等你的提示是第一组的一行；右上停止整棵树）。
  进行中换成分组列表（“等你处理”“进行中”两组，一行是 32pt Botin 头像带运行状态角标、两行任务、“状态 · Botin · 时间”、AI 标识，
  最后一组“加载更多”）。开源许可换成分组列表（三节各一组，组标题带个数、说明在脚注；Rust 组件按许可证一个系统 `DisclosureGroup`，搜的时候
  都展开；没搜到 `ContentUnavailableView.search`），组件详情照资料页（居中名字和版本，许可证、作者、原文、源码几组，源码是 `ExternalLinkRow`），
  原文打不开是 `ContentUnavailableView`；引擎的版本从描边小标签换成灰字。注销账号换成 `Form`（居中的警告头部、会删掉的内容一组、“我已了解”
  是系统 `Toggle`、验证码一组，“注销账号”是底部浮动的红色全宽胶囊）；账号、设备页离线的空状态换成 `ContentUnavailableView`。对话、运行详情里
  自画的卡片（审批、工具调用、发送前的拦截、运行详情的任务 / 信息 / 摘要 / 失败）从 `Card` 换成新的 `BubbleCard`（`Screens/Conversation/`，
  agent 气泡的灰、圆角 20、不画描边，规范 1.1 第 2 条“系统没有的才自己画”）。uicheck 桩加 `DisclosureGroup`（新文件
  `Stubs/SwiftUI/SwiftUI+Finishing.swift`）。
- 第 1 轮收尾线·计划的新建 / 确认 / 触发器、添加 key 和 key 的小 sheet（D、E 线剩下的自画页；2026-11-05）：计划的新建 / 编辑换成 `Form`
  （左上 `CloseButton`、右上 `ConfirmButton`；Botin、错过的怎么补是 `Picker(.inline)`，策略几项是 `Picker(.menu)`——`PlansMenuRow` 改成系统
  `Picker`，预授权工具页是一组系统 `Toggle`；触发规则一行一条，右边红色减号也能左滑删）。确认页照计划详情排成分组列表（居中标题和说明，
  改动 / 标题 / 目标 / 触发规则 / 策略 / 流水线各一组，改过的组标题后面标“改过”；“确认生效”是底部浮动的全宽胶囊，“修改后确认”、红字“删除”在
  最后一组；已确认 / 不用确认 / 已删除 / 找不到换成 `ContentUnavailableView`）。触发器编辑器换成 `Form`（写法是第一行的筛选胶囊，时间日期是系统
  `DatePicker` 行，周几、几号是一排玻璃圆按钮 `PlansDayToggle`，“工作日 / 周末 / 每天”是小玻璃胶囊，预览一组，接下来几次是
  `LabeledContent`）；时区页换成分组列表（本机、常用、全部，选中打勾，没搜到 `ContentUnavailableView.search`）。`PlanPolicyRows`、
  `PlanStepsView` 改成只出行，详情页和确认页共用（详情页原来自己写的两段删了）；`PlanTextBlock` 不再包卡片；新加 `PlansOptionLabel`
  （行内单选的一项）、`PlansNoticeRow`（带色调图标的一句提示）；`PlansTextField` 删掉（都换成 `FormTextField`）。添加 key 换成 `Form`
  （厂商一行一个、选中打勾，厂商说明一组，接口地址、key 各一组，数据去向的同意换成系统 `Toggle`，页尾的大按钮去掉、只留右上“保存”；加好了是
  分组列表），key 详情的改备注、每日上限、换 key 三个小 sheet 换成 `Form`，`ModelsField` 去掉自画的框（标签在上），`ModelsFootnote`、
  `ModelsOfflineNote` 删掉。
- 第 1 轮收尾线·删掉自画组件、截图、文档（2026-11-05）：删了 `Components/Card.swift`（对话、运行详情的卡片换成新的 `BubbleCard`，
  `Screens/Conversation/BubbleCard.swift`）、`EmptyStateView.swift`（登录页选国家没搜到那一处换成 `ContentUnavailableView`）、
  `PillButton.swift`（错误横幅、离线横幅的按钮换成 `smallCapsuleButton()`，Mac 菜单栏的“去打开”换成 `glassButtonStyle()`；登录页还在用的
  胶囊样式挪到 `Screens/Account/SignInButtonStyle.swift`，改成模块内部的、只给登录页用）；`ListComponents.swift` 只剩 `inlineNavigationTitle`、
  `InlineTitleText`、`visibleError`（`SectionHeader`、`GroupedSection`、`ListRow`、`TagChip`、`ChoiceRow`、`InlineNotice`、`PageHeader`、
  `LoadingStateView`、`pageLayout()` 和 `PageTitleVisibility` 删掉；`TagChipRow` / `PlansButtonRow` 合成 `AdaptiveRow`，`PlansNoticeRow`
  改名 `NoticeRow`，都在 `ListStyles.swift`）；`AccountComponents.swift` 删 `AccountSection`、`AccountAvatar`（`AccountRow`、
  `AccountRowDivider`、`AccountScrollPage`、`AccountPageHeader`、`CheckboxRow` 登录页还在用，注释写明了）。`ViewSmokeTests` 的组件那条换成
  新组件。截图：`THINKTIN_OPEN_SCREEN` 加 `teams`、`newtask`、`onboarding`（App 的 `AppConfiguration.OpenScreen`、`OpenScreen.swift`，
  `AppSmokeTests` 的三条跟着改），`screenshots.sh` 清单加 `15-approvals`（`thinktin://approvals`）、`16-teams`、`17-new-task`、
  `18-onboarding`，产物 38 张。docs/ios.md 第 4 节（页面的写法、共用的行和字段、删掉的组件、头像尺寸）、第 5 节（卡片画在哪）、第 7 节
  （截图清单）；规范 7.3 收尾那一条、4.4.5、7.6 的表记“已做”。
- 第 1 轮收尾线·和参考对不上、自己定的（等用户看）：这些页参考里都没有，照最像的参考页排：收件箱照首页（01）的消息列表，团队、审批、计划确认、
  组件详情照 Botin 资料（09）的分组和居中头部，组标题旁的小胶囊和“暂无……”的灰字照 62，新任务和团队编辑照 11 的选择器（单选用按钮行 + 系统勾，
  没用 `List(selection:)`），引导、注销、计划确认的主按钮照 34 的底部全宽胶囊。收件箱每行的“…”按钮去掉了（左滑和长按里有一样的操作）；
  “N 条未读”从页头挪到列表顶上一行灰字；新任务从“点一行就走”改成“选了再点确认”（照 11）；审批选项一个一行、全宽（服务端给的名字可能很长）。
- 第 1 轮收尾线·要在模拟器上看的（Linux 的桩看不出来）：收件箱 plain 列表的行高、未读点和 40pt 图标的对齐；审批卡片里几个全宽玻璃胶囊在
  分组行里各自能点（行里的按钮是有边框的样式，不会整行一起触发）；运行树行底的高亮（`listRowBackground(userBubble)`）和按层缩进；
  团队详情头部叠在一起的头像；流水线编辑器组标题里的 `ellipsis` 菜单点不点得到；`DisclosureGroup` 在 insetGrouped 里的展开箭头；
  触发器编辑器里周几、几号那一排 30pt 的玻璃圆（31 个号一排 7 个在 375pt 宽的屏上挤不挤）；`Picker(.inline)` 的选项是两行（名字 + 说明）
  时系统勾的位置；新任务 sheet 半屏时底部搜索栏；注销页、计划确认页底部浮动的胶囊压不压最后一组。
- 第 1 轮收尾线这一份的 Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1089 个全过
  （这条线没动视图模型）；uicheck UIKit、AppKit 都编过（没有错误和警告）；`run.sh test` 的 ThinktinUITests 147 个全过；App 的
  `ThinktinTests` 21 个过 16 个（新改的三条 `OpenScreen` 都过；挂的还是那 5 个要 App 包的：Info.plist、URL scheme、隐私清单和多语言资源、
  小组件 appex、`~/Library` 路径）；`swift format lint --strict -r apps/apple` 零条。macOS CI 还没跑这一份。
- 第 1 轮审查修正（2026-11-05，评审对 `ff12ebf` 之后提交的 21 条意见，逐条对过代码和参考截图）：
  - 第一批（这次提交）：左滑只弹确认的按钮不用 `.destructive`（系统会先把行收走），改红色 `tint`：计划、产出物、保险箱、登录设备、
    团队模板、运行树的停止；产出物导出的文件名没扩展名时按 MIME 补（`ArtifactFiles.preferredExtension`，存相册、预览、分享认类型）；
    工作区版本菜单在现在的版本下架时补一项“（已下架）”占位（`needsDelistedVersionPlaceholder`）；已隐藏页改成路由 `.hiddenBotins`
    （以前 `Router` 看不见它，推送、深链、`popToRoot()` 后它还在栈里），标题照参考 114 放进玻璃胶囊（`capsuleNavigationTitle`）；
    引用回复在运行树、进行中、首页预览、搜索、运行详情、读屏里只显示 / 先念正文（`MessageQuote.body`、`spoken`）；首页行和置顶格子
    读屏念暂停、归档（`HomeRowPreview.spokenState`）；资料页右上去掉“打开对话”只留“…”（规范 4.4.1）；编辑页“头像”行去掉行尾
    小头像（参考 12）；头像选择去掉形状和色板之间的分隔线、选中改成贴着形状的中性灰环（参考 18）。测试：`ArtifactModelsTests`
    （补扩展名）、`InstanceProfileTests`（下架占位）、`AppRouteTests` / `RouterTests`（新路由、推送换掉它）、`ConversationLayoutTests`
    （正文、读屏、运行树标题）、`HomeListTests`（预览取正文）、`AppShellTests`（读屏状态）。
  - 第二批：设置根页照参考 53、70、75 调顺序（账号、用量、模型 key、保险箱；隐私政策在用户协议前面），通知那组只在没开着时有脚注；
    通知开关在还没问过权限时直接请求（`NotificationToggleAction`，`\.notificationAuthorizer`），问过了才去系统设置；实时活动的两个开关
    挪进“Botin”组审批后面（`LiveActivitySettingsRows`，说明进那组的脚注）；账号头像换成中性灰的首字圆（`AccountAvatar`：设置、账号页、
    首页左上）；“全部停止”出错的横幅是单独一行（以前点横幅会弹确认）；登录设备没有电脑时有一组“电脑”说怎么让它出现
    （`ComputerLinkStatusSection(hasComputer:)`）；产出物的行都是按钮（没有 chevron，参考 22），类型胶囊不带个数。测试：
    `SettingsModelTests`（顺序、脚注、开关的动作）、`ComputerLinkScreensTests`（没有电脑时的一组）、`SettingsScreensTests`（改名后的开关行）。
  - 没在本分支改的 3 条（`r2/conversation` 已经做了，合并进来就有，重复做会两边冲突）：对话“…”菜单加“在对话中查找”（`cd773e3`）、
    消息长按换成底部面板（`b6393fd`）、资料页“…”菜单复制 ID 放最后（`ff8b335`）。规范 4.3.2、4.3.4、4.4.2 记了。
  - 合并 `r2/*` 时要留意的冲突：`AppRoute`（本分支加了 `.hiddenBotins`，`RouteSamples` 的 `caseCount` 和下标）；`SettingsModel` 第一组
    （本分支把用量挪到模型 key 前面，`r2/settings` 在用量后面加了订阅）和链接组；`InstanceProfile.swift`（本分支删了
    `openConversation`、加了 `delistedVersion` / `needsDelistedVersionPlaceholder`）；`InstanceEditScreen` 的头像行；`DevicesView`、
    `VaultScreens` 的左滑。
  - 这一份的 Linux 检查（2026-11-05，第二批提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1092 个全过；uicheck UIKit、AppKit
    都编过（没有错误和警告）；`run.sh test` 的 ThinktinUITests 147 个全过；App 的 `ThinktinTests` 21 个过 16 个（挂的还是那 5 个要 App 包的）；
    `swift format lint --strict -r apps/apple` 零条。要在模拟器上看的：已隐藏页标题的玻璃胶囊在 iOS 26 上是不是只有一层（工具栏的共用玻璃
    底用 `sharedBackgroundVisibility(.hidden)` 去掉了）、iOS 17 / 18 上的材质胶囊；红色 `tint` 的左滑按钮；通知开关请求权限后回弹不回弹。
- 第 2 轮四条并行线合进本分支（2026-11-05，按 connections → conversation → botin → settings 的顺序，一条一个 `--no-ff` 合并提交，
  每条合完跑全部 Linux 检查再合下一条；各线自己的记录在 `docs/progress/r2-<名字>.md`，末尾记了合并提交）：
  - `r2/connections`（合并提交 `c6a2aaf`）：连接目录、已连接、完整列表、应用详情（规范 4.8）。冲突都是两边都留：`RouteSamples` 里
    `.hiddenBotins` 还是 45，连接的四个是 46–49，`caseCount` 50；设置根页第一组保留审查修正的顺序（账号、用量、模型 key、保险箱），
    第二组的“IM 渠道”换成“连接”；`THINKTIN_OPEN_SCREEN` 在 teams / newtask / onboarding 后面加 connections，截图改名
    `19-connections`（15–18 已被收尾线占了），规范 7.6 的表加一行；docs/ios.md 第 7 节两边的说明合成一段。
    Linux 检查：ThinktinKit `swift test` 1106 个全过；uicheck UIKit、AppKit 都编过；`run.sh test` 151 个全过；App 的 `ThinktinTests`
    21 个过 16 个（挂的还是那 5 个要 App 包的）；`swift format lint --strict` 零条。
  - `r2/conversation`（合并提交 `7de7dd0`）：对话内查找、输入框“+”附件菜单、表情回应（长按面板和表情选择器）、选择主 Botin
    （规范 4.3.3、4.3.4、4.3.6、4.4.5）。第 1 轮审查修正留给这条线的“在对话中查找”和长按面板就是它。冲突：`RouteSamples` 里
    `.primaryBotin` 是 50，`caseCount` 51；`ConversationLayoutTests` 留审查修正加的“引用只显示正文”那条，菜单那条的名字带上查找；
    规范两边都留，4.3.2、4.3.4、4.4.2 的审查意见改成“已经合进本分支”。资料页“…”第一组是“替换主 Botin…、复制 ID”（两边一致）。
    Linux 检查：ThinktinKit `swift test` 1124 个全过；uicheck UIKit、AppKit 都编过；`run.sh test` 158 个全过；App 的 `ThinktinTests`
    21 个过 16 个（还是那 5 个）；`swift format lint --strict` 零条。
  - `r2/botin`（合并提交 `a897e14`）：编辑页的语音通话三行、头像页的形状 / 生成 / 上传分段、观看与接管（`.instanceScreen`，
    规范 4.4.3、4.4.4、4.6.2、4.6.3）。冲突：`RouteSamples` 里 `.instanceScreen` 是 51，`caseCount` 52；`InstanceDetailModel.delete()`
    删掉后清头像外观、语音选择、表情回应、主 Botin 四样；规范 4.4.3、4.4.4 留审查修正和这条线的“已做”。合并时顺手补了这条线留的一行：
    首页长按删 Botin 也传 `voices: .shared`（`HomeScreen.swift`）。审查修正（编辑页“头像”行不带小头像、形状和色板之间没有分隔线、
    中性灰选中环）在合并后的代码里都还在。
    Linux 检查：ThinktinKit `swift test` 1138 个全过；uicheck UIKit、AppKit 都编过；`run.sh test` 161 个全过；App 的 `ThinktinTests`
    21 个过 16 个（还是那 5 个）；`swift format lint --strict` 零条。
  - `r2/settings`（合并提交 `19e299a`）：权限与规则、订阅、导入记忆、发送反馈、设备改名弹窗、保险箱“+”菜单和卡片 / 联系信息表单、
    登录信息的网站行（规范 4.9.1、4.9.4–4.9.10、4.9.14）。冲突：`RouteSamples` 里权限、订阅、导入记忆、反馈是 52–55，`caseCount` 56；
    离线策略 `.local` 那行留着 `.primaryBotin`，这四个另起一行 `.local`；设置根页第一组是 账号、用量、订阅、模型 key、保险箱（用量照审查修正
    紧跟账号，订阅照参考 53 紧跟用量），第二组“连接”（r2/connections 换掉的 IM 渠道），“Botin”组 权限、审批、登录设备、导入记忆（实时活动的
    两行开关照旧接在审批后面），链接组隐私政策在前，反馈单独一组；规范 4.9.1、4.9.9 两边的审查修正和“已做”都留，表里 94–100 用这条线的、
    101–107 用 r2/connections 的。`DevicesView`、`VaultScreens` 两边都改过，自动合上了（审查修正的左滑和这条线的改名弹窗、“+”菜单都在）；
    桩没有重复声明（`UITextContentType` 这条线只是 extension 加信用卡几种）。
    Linux 检查（合并提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1163 个全过；uicheck UIKit、AppKit 都编过（没有错误和警告）；
    `run.sh test` 的 ThinktinUITests 165 个全过；App 的 `ThinktinTests` 21 个过 16 个（还是那 5 个要 App 包的）；`swift format -i -r apps/apple`
    没改东西，`swift format lint --strict -r apps/apple` 零条。
  - 四条线都合完了。各线留的跨线小事（以前不在各自的范围里，现在都在本分支上了）记在“下一步”第 4 条。
- 跨线小事（2026-11-05，四条 r2 线合进来以后，只动客户端；原话在 `docs/progress/r2-<名字>.md` 和第 1 轮各线的“下一步”）：
  - 本机记录一起删（下一步 4 (a)）：新的 ThinktinKit `ViewModels/Shell/BotinLocalData.swift`，把只存在这台设备上的按 Botin 记的五样
    （头像外观、首页置顶和隐藏、语音通话、表情回应、主 Botin）放在一起，`AppModel.local`（`appearances`、`instancePreferences` 改成
    从它取）。`forget(_:)` 五样一起删：`InstanceDetailModel.delete()`（参数 `appearances:` / `voices:` 换成 `local:`，资料页和首页长按
    都传 `app.local`）、`InstanceDetailScreen.leaveDeletedInstance`、事件流说 Botin 没了（`AppModel.instanceDisappeared`，以前只删置顶隐藏）。
    注销账号成功后 `forgetAccount(_:)`（以前只删头像外观；主 Botin 也清掉）。`UserDefaults.standard` 时语音、表情回应、主 Botin 用
    App 共用的 `.shared`；对话页、选择主 Botin 页改从 `app.local` 取（测试、预览不再写 standard）。测试：新 `BotinLocalDataTests`，
    `InstanceDeletionTests` 的删除那条改成五样都查，`BotinVoiceTests`、`BotinExtrasScreensTests` 跟着改参数。规范 4.9.2 加“本机记录”。
  - 主 Botin 接到用的地方（下一步 4 (b)(c)）：`PrimaryBotinStore` 加 `isPrimary`、`primaryFirst`、`defaultSelection(in:current:)`，
    `ConversationText.primaryBotin`（“主 Botin”/“Main Botin”）。新任务的选择默认选主 Botin（没有才选当前的），排第一、说明写
    “主 Botin · 状态”；快捷指令“给 Botin 下任务”的 Botin 参数 `defaultResult()` 是主 Botin、建议列表里排最前（uicheck 的 AppIntents 桩
    给 `EntityQuery` 补了 `defaultResult()`，带默认实现）。`InstanceAvatar.Badge.primary`（强调色圆里白星，最小 14pt）：资料页头像上
    换掉状态角标（参考 10），首页的行和置顶大头像在没有状态角标时画（参考 01，有状态时先画状态，`HomeRowPreview.avatarBadge(isPrimary:)`），
    读屏都念“主 Botin”。小组件只有几个数、不选 Botin，没接。测试：`PrimaryBotinTests` 加默认选谁、排序，`InstanceAvatarTests` 加星标的
    直径、挪的距离、读屏、出图，`AppShellTests` 加“主 Botin”（首页、置顶、资料页、新任务都出图，行的角标优先级）。规范 4.4.5 记了。
  - 工作台菜单加“连接”（下一步 4 (e)，参考 01 首页左下的“应用”按钮进连接目录）：`WorkbenchEntry.connections`（最后一项，
    `puzzlepiece.extension`，和设置那一行同一个图标；不带数、不算总角标），`openTopLevel(.connections(category: nil))`；
    `AppRoute.isTopLevel` 加 `.connections(category: nil)`（预选了分类的不算）。测试：`AppRouteTests` 顶级页面 6 → 7、
    `ShellStateTests` 的顺序、标题、角标数、图标。规范 4.8.1 记了。
  - `messageMenu(_:previewShape:)` 去掉没用的 `previewShape` 参数（下一步 4 (f)）：对话的消息、工具调用卡片、历史记录、运行详情的
    摘要和测试一起改成 `messageMenu(_:)`。
  - 截图入口（下一步 4 (g)）：`THINKTIN_OPEN_SCREEN` 加 `instancescreen`（观看与接管，“首页 → 对话 → 观看与接管”）和设置里的
    `permissions` / `subscription` / `importmemory` / `feedback`（`OpenScreen.isInSettings`：先弹设置再 `open` 压进设置 sheet 的栈）；
    `screenshots.sh` 加 `20-instance-screen`、`21-permissions`、`22-subscription`、`23-import-memory`、`24-feedback`（现在 25 张 × 深浅两套）；
    规范 7.6 的表、docs/ios.md 第 7 节跟着改。App 的 `AppSmokeTests` 三条 `OpenScreen` 测试加了这五个（Linux 上过了，在模拟器上没出过图）。
  - 首页“等你处理”提示行（第 1 轮 A 线留的，规范 4.2.1、6.1 A1）：ThinktinKit `HomeAttentionHint`（`AppModel.homeAttentionHint`，
    待审批或未读不为 0 才有；文字“2 个审批在等你 · 3 条未读”；有审批去 `.approvals`，只有未读去 `.inbox`），界面 `HomeAttentionRow`
    （列表最上面的玻璃胶囊，警告色图标，`openTopLevel`）。测试：`HomeListTests` 加文字和去处，`AppShellTests` 加出图和点了去哪。
  - 没做的（要后端、模拟器或用户拍板，记在“下一步”第 4 条）：对话里“等你接管”的状态行（`ClientProtocol` 和 `RunState` 里没有
    docs/browser.md 说的 `waiting_owner` 这类状态，状态行没有东西可接；路由 `.instanceScreen` 已经有了）；`AppFeature.connections`
    的 WBS 包号；头像上传存本机；保险箱、IM 表单返回时不问就丢改动；示例任务直接发还是填进输入框；搜回复正文、预览卡取缓存事件、
    纯黑外观（客户端的新功能，不是两页之间缺的线）；连接目录预选分类时胶囊滚到看得见。
  - 这一份的 Linux 检查（2026-11-05，在 `daf5a35` 上，之后只改了进度文件）：ThinktinKit `swift build --build-tests` +
    `swift test` 1169 个全过；uicheck UIKit、AppKit 都编过（没有错误和警告）；`run.sh test` 的 ThinktinUITests 168 个全过；App 的
    `ThinktinTests` 21 个过 16 个（挂的还是那 5 个要 App 包的：Info.plist、URL scheme、隐私清单和多语言资源、小组件 appex、`~/Library`
    路径）；`swift format -i -r apps/apple` 没改东西，`swift format lint --strict -r apps/apple` 零条。macOS CI、截图都没跑。
- 每一组改版页面都能在真 Mac 上查（2026-11-05，session_01GuCp3KRgqaK6Kzynw6udRn；提交 `fbbd655`、`ff41d39`、`4701a85` 和这一条）：
  - `.github/workflows/ios.yml` 的 push 加 `ci/**` 分支（main、PR 和路径过滤照旧）：没开 PR 的分支 `git push origin HEAD:ci/<名字>`
    就用 GitHub 免费的 macOS 机器跑真 SDK 的编译和测试。路径过滤照旧，推上去的改动没碰 `apps/apple/**` 这些路径时可能不跑，那就在
    Actions 里手动 Run workflow 选那个分支。
  - 页面里本地打开、没有路由的子页能直接打开了（不加 `AppRoute`）：ThinktinKit 新的 `Navigation/Subpage.swift`（对话查找栏、编辑 Botin、
    头像、工作区、引擎详情 sheet、产出物“媒体”、保险箱三种新建表单、新建规则、这台设备 / 第一台电脑的详情、外观、语言、触感、应用详情 sheet），
    `Router.requestSubpages(_:)` 记下要依次打开的子页，`takeSubpage` 只取排在最前面的（`show`、`reset` 清掉）；ThinktinUI 新的
    `Shell/SubpageRequest.swift`：`onSubpageRequest(_:when:perform:)`，父页面出现、数据拿到（`when`）后等 `Subpage.settleDelay`
    （600 毫秒，转场里改导航状态系统可能不理）再取走、打开。挂在对话、资料（编辑、工作区；工作区多了一个 `navigationDestination(isPresented:)`，
    行照旧是 `NavigationLink`）、编辑（头像）、引擎目录、产出物、保险箱、权限、登录设备（多了 `navigationDestination(item:)`）、设置根页
    （外观、语言、触感三页改成 `displayPageView(_:)` 共用，多了 `navigationDestination(item:)`）、`ConnectionsHost` 上。没有请求时什么也不做。
  - `THINKTIN_OPEN_SCREEN` 从 15 个值加到 42 个（`AppConfiguration.OpenScreen` 按页面组排）：首页的三种摆法（`homepinned` 第一个置顶、
    `hiddenbotins` 最后一个隐藏并打开已隐藏页、`homeallhidden` 全部隐藏；`OpenScreen.homeArrangement`，先清掉再摆）、`conversationfind`、
    `botinedit`、`botinavatar`（资料 → 编辑 → 头像两层）、`workspace`、`primarybotin`、`engines`、`enginedetail`、`artifactsmedia`、
    `connected`、`connectiondetail`（已连接 → “电脑”详情）、设置里的 `account`、`usage`、`modelkeys`、`vault`、`vaultlogin` / `vaultcard` /
    `vaultcontact`、`permissionrule`、`devices`、`devicedetail`、`computerdetail`，设置根页的 `appearance`、`language`、`haptics`。
    `OpenScreen.swift` 的 `route(instanceID:)`、`subpages`、`open(in:)`（Botin 的页面等实例列表、取首页第一行）。没加深链（都能用
    `Router.show` + 子页打开）。
  - `tools/apple/screenshots.sh`：清单加一列外观（`ld` 深浅两张、`l` 只截浅色），00–24 的名字不变，新加 25–51（一共 52 个页面、69 张：
    17 个主要页面深浅两张，其余浅色）；每次启动加 `-cn.thinktin.shell.instancePreferences none`（参数域把首页的置顶、隐藏盖成“没有”，
    `homepinned` 这几张存进模拟器的不会带到下一张）、等 7 秒（子页一层层开）；启动 App 之前 `simctl spawn defaults write` 关掉键盘的滑动输入
    （`com.apple.keyboard.preferences.plist KeyboardContinuousPathEnabled`）、记成看过介绍（`com.apple.Preferences` 的
    `DidShowContinuousPathIntroduction`、`DidShowGestureKeyboardIntroduction`），失败不管。超时：GitHub 的截图作业 80 → 90 分钟，
    Codemagic 的 `ios-screenshots` 80 → 90，`.github/workflows/codemagic.yml` 等 Codemagic 80 → 95 分钟、作业 90 → 105。
    清单用假的 `simctl` 在 Linux 上跑过一遍（69 张、深色 17 张、每个 `THINKTIN_OPEN_SCREEN` 值都用到、都认得），`bash -n` 过；真机没跑过。
  - 新的 `docs/ios-ui-redesign-shots.md`：每张截图对哪几张参考、规范哪一节，最后列了截不到的参考（系统菜单、左滑、长按、要输入的、
    别的分页）。规范 7.6 的表换成指向它；docs/ios.md 第 7 节（CI 的 `ci/**`、截图）、第 9.1 节第 4 条（要截子页时加 `Subpage`）跟着改。
  - 测试：`RouterTests` 加“子页”（顺序、带参数的、换掉、`show` 和 `reset` 清掉）；App 的 `AppSmokeTests` 三条 `OpenScreen` 重写（42 个值、
    每个的路由和子页、首页的摆法、演示数据里打开后的返回栈和排好的子页，测完把置顶、隐藏清掉；测试 target 只依赖 App，ThinktinKit 的类型
    不写名字、靠推断）。
  - 截不到的：图片全屏（演示数据没有图片产出物，加一张要动十几处测试）、系统 `Menu`（语音、语言的选项）、长按、左滑。
  - 这一份的 Linux 检查（2026-11-05，最后一次代码提交 `4701a85` 上）：ThinktinKit `swift build --build-tests` + `swift test` 1170 个全过；
    uicheck UIKit、AppKit 都编过（没有错误和警告）；`run.sh test` 的 ThinktinUITests 168 个全过；App 的 `ThinktinTests` 21 个过 16 个
    （挂的还是那 5 个要 App 包的：Info.plist、URL scheme、隐私清单和多语言资源、小组件 appex、`~/Library` 路径）；
    `swift format -i -r apps/apple` 没改东西，`swift format lint --strict -r apps/apple` 零条；`bash -n tools/apple/screenshots.sh` 过。
    macOS CI、截图都还没跑。
- 首页这一组的还原度评审修正（2026-11-05，session_01GuCp3KRgqaK6Kzynw6udRn；截图 00、01、09、25、26、27 对参考 01、78、80、113、114、
  119、120，评审意见逐条对过两边的截图；规范 4.2.1、4.2.3、4.2.4 各加了一条“还原度评审修正”）：
  - 左上账号按钮是 44pt 的玻璃圆、36pt 头像几乎填满（`Metrics.Avatar.account`）：这一项 `hidesSharedGlassBackground()`，按钮自己
    `glassBackground(in: Circle(), interactive: true)`，`.dynamicTypeSize(.large)` 不跟动态字体变大。以前 iOS 26 给头像这种非符号标签套
    约 56×44pt 的胶囊。macOS 不变。
  - 工作台角标在 iOS 26 上画出来：Glass.swift 新的 `ToolbarContent.toolbarItemBadge(_:)`（iOS 26 / macOS 26 是 `ToolbarContent.badge(_:)`，
    uicheck 桩照文档补了），加在 `HomeToolbar` 的 `ToolbarItem` 上，数由 `HomeContent.body` 读好传进去；View 的 `toolbarBadge` 在 26 上
    原样返回，只在旧系统叠数。
  - 搜索占位字“搜索”/“Search”（`SearchText.prompt`，加了测试）。
  - 都隐藏了：`eye.slash` 用 `.body`，按钮字 medium `.subheadline`；**品牌**：文案换成自己的“Botin 都藏起来了”“查看藏起来的 Botin”
    （原来是参考的句子换名词）。已隐藏页：“取消隐藏”常规大小的玻璃胶囊 + medium `.footnote`；胶囊标题 medium `.body`（`InlineTitleText`
    多了 `font` 参数，只有胶囊标题传）。
  - 搜索：`FilterChipBar` 的字 medium `.footnote`、没选中的字 `Theme.ink`（所有用它的页面都跟着变：计划、产出物、保险箱、连接目录、
    规则写法）；搜索里胶囊左右 20pt；结果一行照首页排（`SearchLayout`：44pt 头像、左右 22pt、上下 18pt，右边小字 `.footnote`）。
    `Metrics.Avatar.search`（40）留给选主 Botin、收件箱，注释改了。
  - 截图脚本：键盘的偏好写完重启一次模拟器（09-search 浅色那张被滑动输入的介绍盖住了）。
  - 没照做的：“显示已隐藏”按钮没加 2pt 的上下内边距凑 36pt（系统按钮的默认高度，差 1–2pt）；连接目录的胶囊左右留白没跟着改成 20pt
    （评审只说了搜索；参考 36 也是约 20pt，那一页的行的左边距要一起看）。
  - 这一份的 Linux 检查（2026-11-05，这次提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1170 个全过；uicheck UIKit、
    AppKit 都编过；`run.sh test` 的 ThinktinUITests 168 个全过；App 的 `ThinktinTests` 21 个过 16 个（挂的还是那 5 个要 App 包的）；
    `swift format lint --strict -r apps/apple` 零条；`bash -n tools/apple/screenshots.sh` 过。macOS CI、截图没跑：要它们验的是
    `ToolbarContent.badge(_:)`（真 SDK 上的签名）、账号按钮的玻璃圆、胶囊的字号和 09-search 浅色那张没有介绍（见“下一步”第 1、2 条）。
- 对话这一组的还原度评审修正（2026-11-05，session_01GuCp3KRgqaK6Kzynw6udRn；截图 02 浅深、28、10 对参考 02、04、118 和规范第 2 节，
  评审意见逐条对过两边的截图，参考 04 用像素量了一遍；规范 4.3.1、4.3.3 和 7.3 收尾那条各加了一条“还原度评审修正”）：
  - 标题胶囊：iOS 26 不给 `.principal` 项套玻璃底（截图里头像和名字是光秃秃的，原来的注释说系统会套，不对）。`ConversationTitle` 自己画
    44pt 高的玻璃胶囊（头像同心、左 10 右 12、名字 medium `.body`）；`inlineNavigationTitle(_:ownsGlass:principal:)` 的 `ownsGlass`
    把这一项的共用玻璃底关掉（`hidesSharedGlassBackground(_:)` 多了个 `Bool`，默认 true，原来的调用不变）。
  - 对话里的审批卡片：“在审批中心查看”留 44pt 点按区域、用负内边距不占版面，卡片不再头轻脚重。
  - 状态行：同一组里有待处理的审批卡片时不放“去审批”（`ConversationTurn.pendingApprovalItemID`、`RunStatusPresentation(approvalCardShown:)`，
    `ConversationTextTests` 加了断言）；`ConversationModel.pendingApprovalItemID(in:)` 改成用它。运行详情的状态行照旧。
  - 查找栏：上 / 下是自己画的 44pt 玻璃圆，“完成”是 44pt 玻璃胶囊（原来系统按钮 `.controlSize(.large)` 约 53 / 49pt，把查找框挤到只剩
    “在对…”），间距 8，两个圆的 `GlassGroup(spacing: 8)`。
  - 审批详情：选项的字换成 `ApprovalOptionLabel`（`HStack` 自己排；`List` 行里的 `Label` 图标被挪进行首一栏、涂成强调色，“允许一次”上橙底橙勾），
    对话卡片共用；“还剩 N 小时”改成次要灰（两处一致，`warning` 只给状态）；“打开对话”墨色字 + 行尾灰箭头（还是 `router.open`）。
  - **品牌**：参考 App 的 Bot 名“小克”从 `InstanceAvatar` 的预览、`InstanceAvatarTests`、`SettingsExtrasTests` 里换掉（写作助手、周报助手）。
  - 没照做的：评审建议给标题胶囊左边 6pt，用了同心的 10pt（参考 118 量出来约 10）；查找箭头能跳时用强调色而不是评审说的墨色（全局强调色，
    和“…”、“+”一样，规范 2.2）；查找栏间距用了评审说的 8（参考量出来约 10.7，换成 12 查找框会窄到约 148pt）。截图脚本这次不用改（三张都
    打开了对的页面）。
  - 这一份的 Linux 检查（2026-11-05，这次提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1170 个全过（第一次跑有 1 个
    issue、输出没留下来，接着连跑 4 次都全过，像是并行跑时偶发的计时问题，和这次改动无关）；uicheck UIKit、AppKit 都编过；`run.sh test`
    的 ThinktinUITests 168 个全过；App 的 `ThinktinTests` 21 个过 16 个（挂的还是那 5 个要 App 包的）；`swift format lint --strict -r apps/apple`
    零条。macOS CI、截图没跑：要它们验的是标题胶囊在 iOS 26 上只有一层玻璃、`sharedBackgroundVisibility(.automatic)` 的签名、
    查找栏四个控件一样高、审批详情里“允许一次”的白勾（见“下一步”第 1、2 条）。
- Botin 这一组的还原度评审修正（2026-11-05，session_01GuCp3KRgqaK6Kzynw6udRn；截图 03、29、30、32、17、31、20、08、33、34 对参考 09、12、18、
  11、65、27、29、34、101、104、38、52，评审意见逐条对过两边的截图；规范 2.2、2.5、2.6、4.4.1、4.4.3、4.4.4、4.4.5、4.6.1、4.6.2、4.7.1、
  6.14、6.17 各加了一条“截图审查”）：
  - **跨页的**：`hiddenInlineNavigationTitle(_:)`（`.principal` 里的 `EmptyView` 系统当没放、照样画标题，Botin 资料、引擎详情、
    连接详情、设置根页四处都换了）；`groupHeader()`（13pt 浅灰的分组标题，Botin 这一组的页面都换了，别的组还没换）；`RowLabel`（行首
    细的中性灰图标）；`compactGroupedList(top:)`（iOS 分组间距 `.compact` + 顶上的内容边距）；`LabeledRow` 加 `detailTypography`。
  - **品牌（强调色）**：`CloseButton` 和 `glassButtonStyle(.regular)` 自己就是中性色（`neutralTint()`），工具栏的图标按钮加
    `neutralTint()`，表单的菜单选择器加 `menuPickerTint()`（`Design/Glass.swift`）。这会让全 App 的次按钮（“编辑”、错误横幅的“重试”、
    空状态的按钮、对话里的小胶囊……）都从橙字变成中性色；运行详情的“停止”、计划的“删除”两个破坏性的次按钮在样式前面加了
    `.tint(StatusTone.failure.color)` 保持红色。文案：新建表单的占位“起个名字”、选主 Botin 的空状态“没有别的 Botin 可选”（以前是参考的
    原句换了个词）。
  - 资料页：“通知”一组（开关显示系统通知权限、不能拨，按 Botin 开关等 6.14 A）；工作区的图标换成空心的 `display`；头部下面留 16pt
    （“编辑”的阴影不再被切）。分享照旧不放（6.21 C，规范 4.4.1 写了原因）。
  - 编辑页：名字平时没有脚注（`AdoptionModel.nameNote(for:hidesUntouchedEmpty:language:)`，新建表单同一条规则）；菜单的值是灰的；
    铅笔的阴影留出空间。头像页：分段和预览之间 40pt；“重置为默认”上面的线画到卡片右边。
  - 工作区：照参考 65 加“重置工作区”（点了即将推出）和“磁盘空间”（值“即将推出”，不编“正常”）；“观看与接管”的说明一行 `.footnote`。
  - 观看与接管：浅色外观下状态栏看不见（黑字黑底）：这一页的导航栏画黑色的底（`toolbarBackground`，uicheck 桩补了它和 `contentMargins`）；
    工具栏的字和图标是白的。
  - 新建表单：形状和色板不画卡片（`AvatarPicker(showsCard:)`）、头像预览回到 120pt、名字框圆角 16（`Metrics.Radius.nameField`）、
    底部“新建”多缩进 20pt、不能点时灰色填充、引擎菜单的值是灰的。引擎目录：`.footnote` 灰字、普通大小的中性玻璃胶囊“选这个”。
    引擎详情：头部贴着导航栏、介绍 `.subheadline`。
  - 两个照参考 11 的选择器共用 `Components/BotinPickerRow.swift`；新任务的选择只有 large 一档、没有分组标题（改成脚注）。
  - 截图：加了 `52-primary-botin-empty`（新账号，看选主 Botin 的空状态），一共 70 张（脚本、对照表、两个工作流的注释跟着改）。
  - 没照做的：资料页右上的分享（上面说了）；引擎详情 medium 档时内容照旧从底部按钮下面滚过去（2.1 的滚动边缘效果，头部上移后挡得少了）。
    上下收紧是照评审给的 `listSectionSpacing(.compact)` + `contentMargins(.top, …)` 写的，iOS 26 上 insetGrouped 列表顶上那段空白到底归
    哪个管，Linux 上验不了，要看下一次截图。
  - 这一份的 Linux 检查（2026-11-05，这次提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1172 个全过；uicheck UIKit、
    AppKit 都编过；`run.sh test` 的 ThinktinUITests 168 个全过；App 的 `ThinktinTests` 21 个过 16 个（挂的还是那 5 个要 App 包的）；
    `swift format lint --strict -r apps/apple` 零条；`bash -n tools/apple/screenshots.sh` 过。macOS CI、截图没跑（要它们验的见“下一步”第 5 条）。
- 资料这一组的截图审查（2026-11-05，session_01GuCp3KRgqaK6Kzynw6udRn；评审拿 04、05、11–16、18、35 和参考 21、22、23 比，逐条看过
  截图，都是真的，都改了；提交 `8d278d5`、`579288d`、`fdc81db`、`bdddd04` 和这一条。规范 2.5、2.8、4.5.1、4.5.2、7.3 收尾线记了“截图审查”）：
  - 计划：一行两行（标题 + 一行灰字“规则 · Botin · 下次：…”，`PlansText.rowSubtitle` 多了 `now`、`calendar`），状态交给分组标题，
    只有规则失效、不会再运行时多一行（`PlanRowNotice`，`PlanMetaLine` 删了）；计划详情不写导航标题、`compactGroupedList()`、
    触发规则图标一列文字一列、策略全是 `LabeledRow`、“…”中性色；分组标题 `groupHeader()`。演示数据的“下一次”按 cron 算
    （`ScheduleForecast`）。空计划的说明换了自己的句式（品牌：和参考 21 那句太像）。
  - 截图：新 `THINKTIN_OPEN_SCREEN=allplans`（全部 Botin 的计划，不要 Botin）+ 新截图 `53-plans-empty`（配 `THINKTIN_MOCK_EMPTY=1`），
    一共 71 张；脚本、对照表、docs/ios.md 第 7 节、App 的 `AppSmokeTests` 跟着改。
  - 产出物：`FilterChipBar` 去掉 `GlassGroup`（整排后面那块灰影），列表 `compactGroupedList(top: 4)`，日期组标题 `.footnote` 的
    `inkTertiary`，空状态只有一段灰字；演示数据加了一张自己画的 96 × 64 PNG（`DemoData.digestImageArtifactID`，通知汇总那次运行的，
    base64 写在 `DemoData.digestImagePNG`），写作助手的产出物变成两个，数产出物的测试（`MockClientAppAPITests`、`ArtifactModelsTests`、
    `InstanceDeletionTests`）跟着改。胶囊的字号和没选中的字色截图之后已经改过（`37c19b1`），没动。
  - 收件箱、审批中心、进行中、运行详情、团队、引导：见规范 7.3 收尾线的“截图审查”那段。运行详情整页从 `ScrollView` + 自画卡片
    换成 `List`（新的 `RunDetailHeader`），`ApprovalRequestCard` 去掉了 `onOpen`（“详情”成了审批中心里单独一行），
    `ApprovalOptionLabel` 多了 `prominent`，`OnboardingText` 多了 `finish`，`SheetStack.addsCloseButton` 多了 `.onboarding`。
  - 这一份的 Linux 检查（2026-11-05，这次提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1173 个全过；uicheck UIKit、
    AppKit 都编过；`run.sh test` 的 ThinktinUITests 168 个全过；App 的 `ThinktinTests` 21 个过 16 个（挂的还是那 5 个要 App 包的：
    Info.plist、URL scheme、隐私清单和多语言资源、小组件 appex、`~/Library` 路径）；`swift format lint --strict -r apps/apple` 零条；
    `bash -n tools/apple/screenshots.sh` 过。macOS CI、截图没跑（要验的见“下一步”第 6 条）。

决定（2026-11-04）：用户问“发的那套 UI 怎么没照着改”，按规范第 6 节的建议开工，用户随时可以改：
6.1 A + A1（实例列表为根、去掉抽屉，抽屉的入口放首页左下“工作台”）；6.2 C（中性灰底和卡片、强调色留橙色、agent 回复加气泡、
字体全用系统的）；6.3 A（保持 iOS 17，iOS 26 的接口在 Design/Glass.swift 里回退）；6.4 A（“+”直接弹领养表单）；6.5 A（设置用 sheet）；
6.6 A（沿用“实例”，2026-11-05 被下面的决定推翻）。其余 18 项按建议。

决定（2026-11-05，用户）：代码里的“实例”（`Instance`）在界面上叫 **Botin**（中英文同一个词，英文复数 Botins）。用户“新建 Botin”，不再“领养 agent”；
新建时选它用哪个 agent 当引擎，同一个 agent 可以给好几个 Botin 当引擎（服务端只限每个账号的实例数）。agent 在界面上只以 Botin 的“引擎”/“Engine”出现。
首次登录首页是空的，空状态“还没有 Botin”+ 说明 + “新建 Botin”按钮。代码里的标识符（`Instance`、`AppRoute.adopt`、`adopt(...)`）不改。

进行中：无人。资料这一组的截图审查（计划、产出物、收件箱、审批中心、进行中、运行详情、团队、引导）2026-11-05 做完，见“已完成”
最后一条。每一组改版页面都能在真 Mac 上查了（`ci/**` 触发 macOS CI、71 张截图、对照表 docs/ios-ui-redesign-shots.md，
见“已完成”最后一条），下一步是推一次 `ci/` 和截图分支、照对照表做还原度评审。第 2 轮的四条线 2026-11-05 都合进本分支了（`c6a2aaf`、`7de7dd0`、`a897e14`、`19e299a`），合进来以后能在客户端做的
跨线小事也做完了（`3e4648a` 到 `daf5a35`，见“已完成”最后两条）；合完的四个 `r2/*` 远端分支还没删，等用户看过再删。
第 1 轮 A 线的首页补完、B、C、D、E 线和收尾线 2026-11-05 做完，见“已完成”。
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
1. macOS CI（`.github/workflows/ios.yml`）还一次都没在 GitHub 上跑过这个分支（Codemagic 的 apple-check 跑过几次，见上面）：
   `git push origin HEAD:ci/ios-ui-redesign` 就跑（2026-11-05 加的 `ci/**` 触发）。这次新加的要它验：`onSubpageRequest` 里
   `Task { @MainActor in }` 的捕获、设置根页和登录设备的 `navigationDestination(item:)` 跟 `NavigationStack(path:)` 一起用、
   `AppSmokeTests` 的 `OpenScreen` 三条在模拟器上（会写 `UserDefaults.standard`，测完清掉）。以前就列着的、只有它验得出来的：
   Glass.swift 的 `if #available` 分支；首页工具栏（`#if os(iOS)` 里的 `ToolbarContent`、菜单项的两行 `Text`、`toolbarItemBadge` 用的
   `ToolbarContent.badge(_:)`（桩是照文档补的，真 SDK 上要编得过、角标要画在工作台的玻璃圆上）、账号按钮去掉共用玻璃底后自己画的 44pt 圆、
   `BottomBarSearchItem`）；`SheetStack` 里第二层 `.sheet(item:)`；`AgentsDestination` 的 `.adopt(agentID: nil)` 模式；启动屏
   （`UILaunchScreen` 的两个键、`LaunchLogo` 的 PDF 和颜色集能不能被资源编译器收下，Info.plist 测试查键）；`DesignTokenTests` 在模拟器上
   顺着 `#filePath` 读仓库里的颜色集（模拟器进程读宿主机的文件，按说可以，没验过）；App 测试里 `OpenScreen` 那三条。
2. 出一次截图对照（规范 7.6 第 3 条）：`git push -f origin HEAD:ios-screenshots`（或 Actions 里手动跑 iOS screenshots），产物 70 张，
   照 docs/ios-ui-redesign-shots.md 逐张和参考比（还原度评审）；先看子页那几张（28–51）是不是真的打开了（600 毫秒的等待够不够、
   7 秒够不够；不够就调 `Subpage.settleDelay` 和脚本的 `sleep`），键盘的滑动输入介绍是不是没再出来，`25-home-pinned` 之后的首页没带着置顶；
   再出一套 iOS 18 的回退：`git push -f origin HEAD:ios-screenshots-ios18.6`（或 Run workflow 填 `ios_runtime`），产物
   `ios-screenshots-ios18.6`；镜像里没有那个运行时脚本会先下载（`xcodebuild -downloadPlatform iOS -buildVersion 18.6`，没在 CI 上跑过，
   失败的话看日志换版本号）。顺带看 09-search 里搜索栏有没有激活（iOS 26 底部条，见“已完成”审查修正那条）。和参考截图并排看
   （参考截图在仓库外，要请用户再发），差别记到这里。冷启动后的启动屏截不到，要在模拟器或真机上看一眼。
3. 第 1 轮五条线并行（规范 7.3，开工前先在这里认领）；第 2 轮纯客户端新功能；第 3 轮等后端。B、C 线做完了；C 线没做的只剩要后端的
   （资料页“通知”开关 6.14、工作区重置和磁盘 6.17、观看与接管 4.6.2、头像的生成和上传、多端同步 6.9 B）。A 线（首页）的长按菜单、置顶、隐藏、
   已隐藏页、预览换成最后一条（6.7 B）2026-11-05 做完了；接着做：~~“等你处理”提示行（4.2.1）~~ 做了、
   预览卡里的最后一条改从缓存的事件里取（现在是运行的摘要，4.2.2 原来的建议是 `cachedEventsBefore`）。B 线（对话页）做完了，接着可以做第 2 轮的对话内查找（4.3.3，“…”菜单第一组
   Botin 资料后面加一项）。D 线做完了，剩下的：搜索回复正文（本机缓存的事件，4.2.4，第 2 轮）。E 线做完了，剩下的：纯黑外观（4.9.11 第二排，Theme 的动态颜色要能按偏好换值，第 2 轮）；
   设置里“连接”汇总页（4.8.1、第 2 轮）做了以后 IM 渠道挪进去；设备改名、保险箱网站、发送反馈等后端（第 3 轮）。
   收尾线做完了（参考里没有的页和各线剩下的自画页都换成原生控件，自画组件删了）：剩下的只有登录页（用户自己设计，等他的稿子；它还用
   `AccountRow`、`AccountScrollPage`、`AccountPageHeader`、`CheckboxRow`、`SignInButtonStyle`，换完一起删）；出一次截图（下面第 2 条，
   多了 15–18 四张）和参考并排看，按用户的修正再调。
4. 第 2 轮四条线留下的跨线小事（各线的原话在 `docs/progress/r2-<名字>.md` 的“下一步”）。2026-11-05 做了 (a)(b)(c)(e)(f)(g)
   和首页“等你处理”提示行，见“已完成”跨线小事那条。剩下的：
   (d) 对话里“等你接管”的状态行点了 `router.open(.instanceScreen(id))`：**要后端**。现在 `RunState` / 事件里没有“等主人接手”
       （docs/browser.md 的 `agent → waiting_owner → human`），对话页没有这一行可接；后端有了这个状态，对话的状态行加一种、点了
       `router.open(.instanceScreen(id))`（路由、页面都已经有了）。
   (h) `AppFeature.connections.workPackage` 的 “12.26” 是占位，WBS 有了连接的包再改（**要定 WBS**）。
   要用户看一眼、拍板的：首页行上主 Botin 的星标只在没有状态角标时画（有在等你处理、进行中、暂停时先画状态；要不要两个都画）；
   资料页头像上主 Botin 的星标换掉了状态角标（状态在“工作区”那行）；“等你处理”提示行参考里没有（规范 6.1 A1 的建议），有审批时点了只进
   审批中心；保险箱、IM 渠道的表单压栈后返回不问就丢改动（第 1 轮 E 线留的，要不要加“放弃修改？”）；示例任务填进输入框还是直接发（B 线留的）；
   头像“上传”要不要先用 `PhotosPicker` 存在本机（r2/botin 留的：要改 `InstanceAvatar` 和外观存储，多端同步要后端）。
   客户端能做、但不是两页之间缺的线（第 2 轮功能，没动）：搜索搜本机缓存的回复正文（4.2.4）、首页预览卡的最后一条改从缓存事件取、
   纯黑外观（4.9.11）、连接目录预选分类时把那个胶囊滚到看得见（`FilterChipBar` 现在不滚，要在模拟器上看）。
   要在 iOS 26 模拟器上看的（这次加的）：星标在 15 种形状上的位置和大小（44pt 行、80pt 置顶、120pt 资料页）；“等你处理”胶囊和置顶大头像、
   第一行的间距；工作台菜单 7 项（多了“连接”）；新任务选择页主 Botin 在第一行；截图 `20`–`24`（设置里的四页是不是在设置 sheet 里）。
   macOS CI 要编的：`EntityQuery.defaultResult()`（uicheck 桩是照文档补的，真 SDK 上快捷指令的 Botin 参数默认值要在 iOS 上点一次看）。

5. Botin 这一组的截图审查（2026-11-05，见“已完成”最后一条）留下的：(a) 别的组的分组标题还是 iOS 26 默认的 17pt 半粗字，各组对截图时把
   `header:` 里的字换成 `groupHeader()`（连接目录参考 52 的分类标题本来就大，别换）；(b) 别的组工具栏上自己加的图标按钮（“+”“…”“?”）
   逐个看要不要 `neutralTint()`、表单里的 `Picker(.menu)` 加 `menuPickerTint()`；(c) 下一次截图要看：`hiddenInlineNavigationTitle`
   的透明点在 iOS 26 上真的不画标题、也不套玻璃；`compactGroupedList` 顶上的空白（03、29、30、31 导航栏到第一块约 25–36pt，34 的头部贴着 ×）；
   20 浅色的状态栏是白字；08 不能点的“新建”是看得出的灰胶囊；`52-primary-botin-empty` 打开了空状态；全 App 的次按钮变成中性色后
   有没有该是强调色的（比如空状态里唯一的按钮）。

6. 资料这一组的截图审查（2026-11-05）留下的，下一次截图要看：`compactGroupedList` 在计划列表 / 详情、产出物（top 4）、审批中心、
   进行中、运行详情、团队上把第一组提到了哪（参考 22：胶囊中心离导航栏中心约 40pt，第一张卡片再往下约 43pt）；`FilterChipBar`
   去掉 `GlassGroup` 后那块灰影是不是没了（搜索 09 也用它）；`53-plans-empty` 是不是正中一段字；`35-artifacts-media` 的缩略图行；
   运行详情的新头部和 `LabeledContent` 行、任务一组的气泡灰底；收件箱的未读角标位置（图标右上，偏出 2pt）；引导左上的 ×。
   没改的：审批详情（10）和团队详情、编辑、流水线编辑器的分组标题还是 `.textCase(nil)`（不在这次的截图里）；`TeamRow` 的头像还是 32pt
   （评审说照旧，模板图标跟它同宽）；对话里的审批卡片选项照旧 `.large`。

坑和决定：
- 资料这一组（2026-11-05）：`FilterChipBar` 别再包 `GlassGroup`（合起来的玻璃在整排后面画一块灰影）；运行详情是 `List`，自画卡片只剩
  里面的审批卡片（`ApprovalCardView`，透明行）；页面导航栏下面别放说明段落，放第一组的脚注（审批、团队）；列表的空状态照参考 21
  只放一段灰字（`ContentUnavailableView { EmptyView() } description:`，读屏的标题用 `accessibilityLabel` 补）；演示数据里写作助手
  有两个产出物（周报要点、通知汇总的截图），数产出物的测试按这个数。
- 导航栏不显示标题用 `hiddenInlineNavigationTitle(_:)`，别写 `inlineNavigationTitle(title) { EmptyView() }`：`.principal` 里是
  `EmptyView` 时系统当没放这一项，照样画 `navigationTitle`（2026-11-05 截图，资料页名字出现两次）。
- 次按钮（`glassButtonStyle(.regular)`、`smallCapsuleButton()`）自己带中性色的 `tint`；要红色、强调色时 `.tint(_:)` 写在样式**前面**
  （离按钮近的生效），写在后面会被盖住。分组标题用 `groupHeader()`，行首图标用 `RowLabel`（`List` 行里的 `Label` 图标默认是强调色）。
- 自画组件删了（2026-11-05 收尾线）：页面一律 `List` / `Form` + `themedGroupedBackground()` + 行的 `themedRow()`，空状态
  `ContentUnavailableView`，加载中是 `.overlay` 里的 `ProgressView`；共用的行是 `LabeledRow` / `NoticeRow` / `AdaptiveRow`、输入框是
  `FormTextField`（`ModelsField` 是 key 那几页的同类，多了密码和网址键盘）；对话里系统没有的卡片用 `BubbleCard` / `cardSurface()`。
  别再加回带描边的卡片、自画的胶囊按钮（`SignInButtonStyle` 只给登录页）。行里放几个按钮时用有边框的样式（`smallCapsuleButton()`、
  `glassButtonStyle()`、`.borderless`），默认样式的按钮在 `List` 行里会整行一起触发。单选列表用“按钮行 + 右边系统勾”（新任务、团队编辑、
  添加 key 的厂商、时区），两行的选项放进 `Picker(.inline)` 时每项是一个视图（`PlansOptionLabel`）再 `.tag`。
- uicheck 桩这一轮只加了 `DisclosureGroup`（`Stubs/SwiftUI/SwiftUI+Finishing.swift`），别再加。
- 首页的置顶、隐藏在 `InstancePreferencesStore`（只存这台设备，按实例 id），界面别自己存；`AppModel.homeContent` 已经按它分好三部分，
  `homeRows` 是首页看得见的（置顶的在前），截图的“首页第一行”也是它。长按、左滑的项和顺序改 ThinktinKit 的 `HomeInstanceMenu`
  （有测试），加项要给 `systemImage`、`needsConnection`。删 Botin 的地方都走 `InstanceDetailScreen.leaveDeletedInstance`，它会删记录。
- 首页的行是按钮不是 `NavigationLink`（plain 列表里 `NavigationLink` 会画 chevron）；进对话用 `Router.open(.conversation(id))`。
- 触感：界面里要震的地方一律用 `appFeedback(_:trigger:)`（`Design/Haptics.swift`），别直接写 `.sensoryFeedback`，不然设置里的“触感反馈”
  关不掉它。开关在 `SettingsPreferences.hapticsEnabled`，由 `.settingsPreferences()` 放进环境 `\.hapticsEnabled`。
- 设置根页的分组、顺序、每行去哪都在 ThinktinKit 的 `SettingsModel.sections(_:pendingApprovals:)`（测试 `SettingsModelTests` 逐行查 id），
  界面照着画；加行要给 `SettingsSection.ID` 里已有的组或新加组（新组记得改测试的 `allCases`）。实时活动的开关不在模型里，界面在 `.botins`
  组里“审批”那一行后面接两行开关（`LiveActivitySettingsRows`），那组的脚注换成实时活动的说明。用户协议、隐私政策的地址在 ThinktinKit 的 `LegalLinks`。
- “今天”的用量按东八区切天（`UsageToday`，模型网关的每日上限就是这样算的），别改成手机本地的零点。
- 保险箱的新建 / 修改表单现在是压栈（`navigationDestination(isPresented:)`），不再是 sheet：系统返回就是放弃，没有“有改动先确认”。
- 设置一带共用的行：`SettingsRowLabel`（标题 + 灰色副标题 + 右边值）、`SettingsProfileRow`（44pt 头像行）、`ExternalLinkRow`（`arrow.up.right`）、
  `VaultLabeledField`（标签在上的输入框，IM 渠道、模型路由也用）、`DeviceStatusDot`。uicheck 桩这一轮补了 `Group`、`fontDesign(_:)`、
  `fontWeight(_:)`（`Stubs/SwiftUI/SwiftUI+Settings.swift`），别再加。
- `ModelsCredentialRow` 不再是按钮（外面包 `NavigationLink(value:)`），`StopAllRow` 是 `List` 里的一行（出错时多一行横幅，`body` 出两个视图），放进自画的 `GroupedSection` 会没边距。
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
  账号头像用 `AccountAvatar`（中性灰的首字圆；审查修正前是按昵称取色的 `InstanceAvatar`）：iOS 上是 36pt，放在按钮自己画的 44pt 玻璃圆里
  （工具栏这一项去掉了共用的玻璃底，不然 iOS 26 套成胶囊），还没拉到用户时是人像；macOS 上 24pt、没拉到用户时是 `person.crop.circle`。
  设置根页、账号页的账号行也用它（`SettingsProfileRow`）。工具栏项的角标要加在 `ToolbarItem` 上（`toolbarItemBadge`），
  View 的 `.badge` 在 iOS 26 的工具栏里不画。
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
  （`ConversationMenuItem` 认不出的路由是兜底的 `chevron.right`，测试会抓）。长按菜单统一用 `messageMenu(_:)`（`previewShape` 参数 2026-11-05 删了），
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
