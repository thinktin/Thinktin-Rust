# r2/connections

目标：iOS 改版第 2 轮的“连接”一组（规范 docs/ios-ui-redesign.md 4.8、6.12；参考 36–52、101–107）：连接目录（分类胶囊，
一个按数据生成的分类页）、已连接列表、推荐 / 精选完整列表、应用详情 sheet。版式照参考 1:1 排，ThinkTin 还没有的应用用本地演示数据、
操作弹“即将推出”；已经有的接入（电脑、IM 渠道、模型 key、保险箱）用真数据，打开各自的现有页面。不改 `ClientProtocol` / Mock / CoreClient。

已完成：
- 路由（`Navigation/`）：新功能 `AppFeature.connections`（目录 `Connections`，工作包先占 `12.26`，WBS 还没有这个包）；
  `.connections(category: ConnectionCategory?)`（目录，预选分类）、`.connectedApps`（已连接）、`.connectionList(ConnectionList)`
  （为你推荐 / 精选的完整列表）、`.connection(ConnectionID)`（应用详情）。都压栈、离线 `unavailable`、不是顶级页面、不经过对话；
  标题“连接”“已连接”“为你推荐 / 精选”“应用详情”。`AppRouteTests` 的样本 45 → 49 个，逐个查了功能、出现方式、离线策略、标题。
- 视图模型（`ViewModels/Connections/`，Linux 上测，`ConnectionsModelTests` 14 条）：
  - `ConnectionCatalog.swift`：`ConnectionID`（`EntityID<IDTag.Connection>`，本地 id）、`ConnectionText`（中英文）、
    `ConnectionCategory`（14 类：iPhone、电脑、模型、密码管理器、效率、通信、设计、代码、数据、销售、营销、财务、研究、支持；
    “iPhone”只在手机上显示）、`ConnectionList`（推荐露 4 个、精选露 6 个）、`ConnectionBuiltIn`（电脑、飞书、企业微信、钉钉、
    模型 key、保险箱：管理页、没设置时去的页面）、`ConnectionApp`、`ConnectionCatalog`。
  - `ConnectionsDemoData.swift`：目录（自带的 6 项 + “此 iPhone”6 项 + 演示的第三方应用 29 项，通用叫法，不写别家的产品名、不用 Logo）。
  - `ConnectionsModel.swift`：一起拉 `devices()`（只留电脑）、`imChannels()`、`credentials()`、`vaultItems()`，四样都失败才报错，
    失败一样那一项不放按钮、留着上次的；状态（连接 / 允许 / 添加 / 已连接 / 不知道）、行（按钮、读屏一句话、推荐理由只在连了相关项时写）、
    分组（全部 / 分类 / 搜索）、完整列表、已连接列表、详情（账户、添加账户、技能、主按钮、管理、断开说明、即将推出脚注）。
  - `ConnectionsText.swift`：文案（不带 AI 生成标识）。
- 设置（`SettingsModel`）：第二组的“IM 渠道”换成“连接”（规范 4.9.1：IM 渠道挪进连接），`SettingsModelTests` 跟着改。
- 界面（`Screens/Connections/`，`AppDestination` 加一行）：`ConnectionsCatalogScreen`（参考 36、40–51）、`ConnectedAppsScreen`（37）、
  `ConnectionListScreen`（101–104）、`ConnectionDetailView` / `ConnectionDetailScreen`（38、39、52、105–107）、共用的
  `ConnectionsComponents.swift`（图标、行、按钮、组标题、`ConnectionsHost`：点行弹 medium / large 的本地 sheet、关 sheet 后再走路由、
  “即将推出”的 alert）。每页的做法写在规范 4.8.1–4.8.4 的“已做”。界面测试 `ConnectionsScreensTests`（接入点、14 个分类、没有群和 key
  的账号、8 种详情、组件）。
- uicheck：新桩 `Stubs/SwiftUI/SwiftUI+Connections.swift`（`Color.red / yellow / green / teal / blue / indigo / purple / pink`，
  `orange` 原来就有）。
- 截图：`THINKTIN_OPEN_SCREEN=connections`（`AppConfiguration.OpenScreen.connections`，“首页 → 连接目录”），清单加 `15-connections`（合进 ios-ui-redesign 时改名 `19-connections`，15–18 已被收尾线占了）；
  App 的 `AppSmokeTests` 跟着改；docs/ios.md 第 7 节的截图说明。
- 文档：规范 3.2、3.3 的路由行，4.8.1–4.8.4 的“已做”，第 5 节对照表 36–52、101–107 的轮次，6.12 记用户的新要求。

进行中：
- （无）

下一步：
- 首页左下进目录（参考 36 的入口）：首页的工作台菜单归 Shell（`Shell/Home/*`、`ViewModels/Shell/WorkbenchEntry`），这一轮不归这条线，
  合并时看要不要在工作台菜单加一项“连接”（`router.openTopLevel` 现在只认 6 个顶级页面，`AppRouteTests.topLevel` 也查这个数）。
- macOS CI 用真 SDK 编一遍；出一次截图（`19-connections`，深浅色）和参考 36、40–52、101–107 并排对。
- 用户按真实功能删改演示目录（`ConnectionsDemoData`）；“此 iPhone”、第三方连接器、网页授权要后端（规范 6.12 的 B），做的时候
  `ConnectionAction.comingSoon` 换成真操作。

坑和决定：
- 参考的目录是首页弹的 sheet（左上 ×）；规范 3.2 定的是设置里压栈，照规范：左上是系统返回，右上“已连接 N 个”。详情和引擎详情一样是本地
  sheet（`.connection(id)` 路由另外是压栈的同一个页面，给深链、别的功能跳过来用），sheet 里要去别的页面时先关 sheet 再 `router.open`。
- 分类页不是单独的页面：参考 40–51 是同一个目录换了选中的胶囊，所以做成 `ConnectionsModel.sections` 按选中的分类生成一组；
  `.connections(category:)` 能预选分类。
- 组标题（“为你推荐 >”）放在行的位置，不用 `Section` 的 header：plain 列表的 header 会吸顶、带底色，参考没有。
- 推荐理由不编：只有连了相关的那一项（飞书、企业微信）才写“因为你连了 …”，没连就写说明。
- ThinkTin 自带的接入“断开连接”不在这一页一次删光（删 key 会让 Botin 调不了模型），alert 说清楚去哪删、带去管理页的按钮。
- 工作包号 `12.26` 是占位（`AppFeature.workPackage` 要求不重复），WBS 里加了包再改。
- 只在 worktree 里改、没碰 `Shell/Home/*`、`ViewModels/Shell/*` 和别的线的页面。

Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1091 个全过（新加
`ConnectionsModelTests` 14 条）；uicheck UIKit、AppKit 都编过（连接的几个文件没有警告）；`run.sh test` 的 ThinktinUITests 149 个全过
（新加“连接的界面”4 条）；App 的 `AppSmokeTests` 里截图那几条（含新的 `connections`）都过，挂的还是那 5 个要 App 包的
（Info.plist、URL scheme、隐私清单和多语言资源、小组件 appex、`~/Library` 路径）；`swift format lint --strict -r apps/apple` 零条。
macOS CI 还没看。
