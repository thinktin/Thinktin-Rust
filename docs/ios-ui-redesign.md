# iOS 界面改版规范（参考 App 的布局 + 系统原生控件）

> 更新日期：2026-11-05（Botin 改名，6.6）　｜　分支 `ios-ui-redesign`　｜　工程说明见 [docs/ios.md](ios.md)，交接见 [docs/handoff-ios.md](handoff-ios.md)

用户给了一个参考 App 的 120 张 iPhone 截图（深色模式、iOS 26 原生风格），要求：**“我们 App 的 UI 就按这个 UI 页面的布局去做，
按钮相关的东西能用原生的全部用原生的”**。本文把截图逐张对到 ThinkTin 的功能和现有代码，定下改版的视觉、导航、逐页规范、
要用户拍板的事和实施顺序。

先说几条规矩：

- 只学布局和交互，不用参考 App 的名字、Logo、文案里的品牌词，文中一律叫“参考 App”。截图编号是用户那批截图的编号（1–120），
  截图本身不进仓库，截图里的个人信息（邮箱、设备名、仓库、网址）不写进文档。
- 登录页用户自己设计，参考里的登录方式页（108）不照做。
- “现有 / 缺什么”以代码为准（本分支，2026-11-04）：页面看 `ThinktinKit/Navigation/AppRoute.swift`（44 个 case），
  接口看 `ThinktinKit/Client/ClientProtocol.swift`。
- 参考 App 管它的 agent 叫 Bot，ThinkTin 的代码和接口里叫实例（`Instance`）。**2026-11-05 用户定了：界面上叫 Botin**（6.6）：
  用户“新建 Botin”，新建时选一个引擎（就是 agent）；agent 在界面上只以 Botin 的“引擎”出现。下文讲参考 App 时说 Bot，
  讲 ThinkTin 的代码、接口、页面结构时照旧说实例；**写进界面的文案一律用 Botin / 引擎**，下文引号里的旧文案（“实例”“领养”）以 6.6 为准换掉。
- 文中的路径省略了公共前缀：`Screens/`、`Shell/`、`Components/`、`Design/`、`Support/` 在 `apps/apple/ThinktinKit/Sources/ThinktinUI/` 下，
  `ViewModels/`、`Navigation/`、`Models/` 在 `apps/apple/ThinktinKit/Sources/ThinktinKit/` 下。
- 控件写法里的 `List(.insetGrouped)`、`List(.plain)`、`Picker(.menu)`、`Picker(.inline)`、`Picker(.segmented)`、`Button(.plain)`、
  `Button(.borderless)` 是简写，真实写法是 `List { … }.listStyle(.insetGrouped)`、`.pickerStyle(.menu)`、`.buttonStyle(.plain)` 这些修饰符。
  其余写出来的 API 都是 SwiftUI / UIKit 里真有的；只有 iOS 26 才有的（Liquid Glass 一类）在 2.10 列了清单和旧系统的退路。

## 1. 总述

### 1.1 改版目标

1. **页面布局照参考 App。** 首页是实例列表，点一行压栈进对话，再进实例资料、编辑、计划、产出物；设置从首页左上角用 sheet 弹出。
2. **控件一律用系统原生的**（docs/ios.md 第 1 节第 5 条）：导航栏按钮、菜单、sheet、搜索栏、列表、表单、开关、选择器、长按菜单、
   左滑操作。用 Xcode 26 / iOS 26 SDK 编出来，这些在 iOS 26 上自动是 Liquid Glass。现在自己画的卡片、胶囊按钮、空状态、
   筛选胶囊、抽屉、输入框外形，统统换成原生的。只有系统没有的才自己画：消息气泡、实例头像、Logo、工具调用卡片、审批卡片。
3. **功能不减。** ThinkTin 有、参考 App 没有的（1.3）都要在新版式里找到位置。
4. **业务逻辑尽量不动。** `ClientProtocol`、client-core 这次不改；视图模型只加首页列表、本机偏好、对话内查找这类纯客户端的东西。
   要后端的功能先只出规范（第 6、7 节）。

### 1.2 和现在的主要区别

| 方面 | 现在 | 改版后 |
|---|---|---|
| 根页面 | 当前实例的对话（`.conversation` 是 `.root`）；没有实例时是 `ConversationHomeScreen` 的问候页 | 实例列表（`.home`，永远是根）；`.conversation` 改成压栈 |
| 切换实例 | 左侧抽屉的实例列表 + 标题上的 `InstanceSwitcher` 菜单 | 返回首页点另一行；去掉抽屉和切换菜单 |
| 收件箱、审批、进行中、计划、团队、产出物 | 抽屉里 6 个入口（`DrawerEntry`），收件箱、审批、进行中、计划（待确认）带角标，团队、产出物没有 | 首页左下的“工作台”菜单（带角标）+ 列表顶上“等你处理”一行（6.1） |
| 搜索 | 抽屉里的假搜索框 → 压栈的搜索页 | 首页底部浮动的玻璃搜索栏，原地搜索，带类型筛选 |
| 新任务 | 抽屉里的“新任务”（选实例的 sheet） | 首页点实例进对话直接打字；`.newTask` 只留给引导和快捷指令 |
| 领养 | agent 目录 → agent 详情 → 领养 sheet | 首页右上“+” → 领养 sheet（表单里选 agent，6.4） |
| 设置 | 抽屉底部头像 → 压栈 | 首页左上头像 → sheet，左上玻璃 × 关闭 |
| 对话标题 | 实例切换菜单 | 玻璃胶囊（小头像 + 名字），点了进实例资料 |
| 输入框 | 自画的一行胶囊（`ComposerBar`），上方模型标签 | 浮动的玻璃胶囊（+ / 输入 / 发送或停止），有引用时长成卡片 |
| agent 回复 | 不带气泡 | 左侧灰色气泡（要拍板，6.2） |
| 时间线 | 没有日期分隔 | 运行之间加“星期二 02:22”这样的分隔 |
| 实例详情 | 一页长表（头部、模型、版本、计划和产出物、团队、信息），改名是 sheet | 资料页（大头像、名字、编辑、计划 / 产出物 / 工作区三行），压栈的编辑页；版本挪进工作区页，删除挪进“…”菜单 |
| 列表和表单 | `ScrollView` + 自画的 `GroupedSection`、`ListRow`、`AccountRow`、`PillButton`、`PlansTextField`（连定义一共 47 个文件；页面里还没有一处用 `List` / `Form`） | `List` / `Form`（insetGrouped 或 plain）+ `LabeledContent`、`Toggle`、`Picker`、系统按钮样式 |
| 空状态 | 自画的 `EmptyStateView`（代码里还没用过 `ContentUnavailableView`） | `ContentUnavailableView` |
| 颜色、字体 | 暖色纸张底、橙色强调色、标题衬线 | 中性灰底、强调色保留橙色、全用系统字体（要拍板，6.2） |
| 顶部滚动边缘 | `solidTopScrollEdge()` 设成 `.hard`（`Components/ListComponents.swift`） | 系统默认的软渐隐，内容从玻璃导航栏下面滚过去 |
| sheet 的关闭和确认 | “取消 / 完成”文字按钮 | 左上玻璃圆 ×（`Button(role: .close)`），确认放 `.confirmationAction` |

### 1.3 必须保留的 ThinkTin 功能（参考 App 没有）

- **对话**：审批卡片、运行状态行（等审批 / 等 key / 等电脑 / 失败重试）、子运行和流水线卡片、保险箱填写卡片、工具调用卡片、
  思考块、模型标签、排队提示、32000 字上限、发送前的密码拦截（`SecretInterceptionSheet`）、离线只读、“正在唤醒”提示。
- **合规**：agent 写的内容都带“AI 生成”标识（`AIGeneratedLabel`，16.3）；回复和产出物能举报（`ContentReportSheet`，5.5）；
  关于页的备案号和 AI 说明。
- **实例**：模型路由、版本升级 / 回滚、所在团队、删除（带影响说明）。
- **全局**：离线横幅、连接横幅、冻结页、升级页、角标、深链和推送跳转（docs/ios.md 第 6.1、6.2 节）。

参考 App 里收件箱、审批中心、进行中、计划、团队、运行详情、运行树这些页都没有，它们照第 2 节的视觉语言改，不改结构。

### 1.4 不在这次范围

- 登录页（`Screens/Account/SignInFlow.swift`、`PhoneEntryView.swift`、`CodeEntryView.swift`），等用户的设计。
- ThinkTin 没有、也不打算做的：语音通话（音色、语速、语言）、“主 Bot”。
- 要后端的功能这次只出规范，排在第 3 轮（7.5）。
- macOS App 的主窗口也用 `RootView`：改 Shell 时 Mac 先保持能用（uicheck 的 AppKit 版要过），Mac 自己的版式另议。

## 2. 视觉语言

### 2.1 总体

- **深色为主，浅色照样做。** 参考只有深色截图；ThinkTin 深浅色都是验收项（docs/ios.md 第 4 节）。用 Theme 令牌和系统语义色，
  浅色跟着出来。
- 页面底是中性深灰（约 `#1C1C1E`），卡片、气泡亮一档（约 `#2C2C2E`），**卡片没有描边**；全屏图片和电脑画面用纯黑。
- 没有大标题，全部 inline 小标题；首页、对话页、实例资料页、设置根页不显示标题。
- 内容从玻璃导航栏、底部浮动条下面滚过去，边缘软渐隐（系统默认的 scroll edge effect，不要加 `.toolbarBackground(.visible)`）。

### 2.2 颜色：和设计令牌怎么衔接

建议方案如下（要拍板，6.2）。令牌名不变，只改值，页面代码不用逐个改；`Design/Theme.swift` 和 `DesignTokenTests` 跟着改。

| 令牌 | 现在（浅 / 深） | 建议（浅 / 深） | 说明 |
|---|---|---|---|
| `accent` | `#C96442` / `#D97757` | 不变 | 全局 `.tint`：主按钮、发送、开关、链接、选中。参考用系统蓝和白色，ThinkTin 保留品牌橙 |
| `paper` | `#FAF9F5` / `#262624` | `#F2F2F7` / `#1C1C1E` | 页面底。纯黑外观（第 2 轮）时深色用 `#000000` |
| `paperElevated` | `#FFFFFF` / `#30302E` | `#FFFFFF` / `#2C2C2E` | 分组卡片、列表行、输入卡片 |
| `agentBubble`（新增） | — | 同 `paperElevated` | agent 回复气泡，单列一个令牌，以后好单独调 |
| `userBubble` | `#EFEDE4` / `#3A3936` | `#E5E5EA` / `#3A3A3C` | 用户消息（右侧） |
| `ink` / `inkSecondary` / `inkTertiary` | 暖灰三档 | 系统的 `.primary` / `.secondary` / `.tertiary` | 放在玻璃上时系统会自动调对比 |
| `hairline` | `#E5E3DA` / `#3F3E3A` | `#C6C6C8` / `#38383A` | 只给自画的分隔线；`List` 用系统分隔线 |
| `success` / `warning` / `danger` | 现值 | 不变 | 只用于状态（`Design/StatusTone.swift`） |

- `List` / `Form` 的底色和行底要和 `paper` / `paperElevated` 一致：在 `Design/` 里加 `themedGroupedBackground()`
  （`.scrollContentBackground(.hidden)` + `.background(Theme.paper)`，加在 `List` / `Form` 上）和 `themedRow()`
  （`.listRowBackground(Theme.paperElevated)`；这个修饰符只对行生效，要加在 `Section` 的内容或 `ForEach` 上，加在 `List` 本身上没用）。
  建议值的浅色一套正好是系统分组色（`#F2F2F7` / `#FFFFFF`）；深色一套比系统默认的分组色（`#000000` / `#1C1C1E`）亮一档，
  所以行底要覆盖。
- `ink` 三档改成系统色时要注意：系统的 `.secondary`、`.tertiary` 带透明度，`DesignTokenTests` 和 docs/ios.md 第 4 节的表现在按
  不透明的十六进制核对。要么令牌直接返回 `Color.primary` / `.secondary` / `.tertiary`（测试改成核对“是不是系统色”），要么取不透明近似值。
- 状态色规则（排队、运行中、等待、成功、失败）不变。
- **已做（2026-11-05，Botin 这一组截图审查）**：强调色只给主按钮、发送、开关、链接、选中，次要控件统一中性（参考里都是白字 /
  黑字）：`Design/Glass.swift` 的 `CloseButton`（×）、`glassButtonStyle(.regular)`（次按钮的字，`neutralTint()` = `Theme.ink`）
  自己就是中性色；工具栏里只有图标的按钮和菜单（“…”“?”）加 `neutralTint()`；表单里 `Picker(.menu)` 的值和上下箭头加
  `menuPickerTint()`（`Theme.inkSecondary`）。次按钮要别的颜色（删除、停止这种破坏性的）时把 `.tint(_:)` 写在
  `glassButtonStyle` / `smallCapsuleButton` **前面**（离按钮近的生效），现在有两处：运行详情的“停止”、计划的“删除”。
  别的页面工具栏上自己加的图标按钮（不是 Botin 这一组的）还没逐个加 `neutralTint()`，各组对截图时顺手改。

### 2.3 字体

- 全部用系统字体（SF）和 Dynamic Type 语义字号；导航标题由系统画。
- `Design/Typography.swift` 现在标题档（`largeTitle` 到 `title3`）用衬线（`.serif`），建议改成默认不用；想留一点品牌感的话，
  只留在首页空状态的大标题上（6.2）。欢迎页（`SignInFlow.swift` 的 `WelcomeView`）属于登录流程，跟着用户的设计走。
- 常用字号：列表名字 `.headline`；预览、副标题 `.subheadline` + `.secondary`；时间 `.caption` + `.tertiary`；正文 `.body`；
  资料页名字 `.title2.bold()`；分组标题、脚注用 Section 自带的。

### 2.4 圆角、尺寸

| 元素 | 参考 | 做法 |
|---|---|---|
| 分组卡片 | 约 20–26 | 系统 insetGrouped 自带，不自己设 |
| 消息气泡、自画卡片 | 约 20 | `RoundedRectangle(cornerRadius: 20, style: .continuous)`；`Metrics.Radius.card` 16 → 20 |
| 输入框 | 胶囊；带引用时卡片圆角约 28 | `.glassEffect(in: .capsule)` / `RoundedRectangle(cornerRadius: 28)`；`Metrics.Radius.input` 已删（2026-11-05） |
| 导航栏圆按钮 | 约 44 | 工具栏系统给，不自己设尺寸 |
| 实例头像 | 列表 48、置顶 80、资料页 120、编辑页 100、搜索结果 40、标题胶囊 24 | 新组件 `InstanceAvatar(_:appearance:size:badge:)`（形状 + 颜色见 4.4.4）。首页的行照参考 01、119 量出来是 44（`Metrics.Avatar.list` 2026-11-05 改成 44），资料页量出来是 80（C 线）。搜索结果照参考 78、80 量出来和首页的行一样是 44（2026-11-05 改用 `Metrics.Avatar.list`，`search` 40 留给选主 Botin、收件箱的图标）；首页左上的账号头像 36，放在 44pt 的玻璃圆里（`Metrics.Avatar.account`，参考 01、119） |
| 应用 / agent 图标方块 | 40，圆角约 10 | `Metrics.Radius.control`（10）保留 |
| 左右边距 | 16–20 | `List` 系统边距；自画内容用 `Metrics.Spacing.m` |

### 2.5 列表样式

- **plain、无分隔线**：首页、搜索结果、agent 目录、连接目录、已隐藏的实例。`List` + `.listStyle(.plain)` + `.listRowSeparator(.hidden)`。
- **insetGrouped**：实例资料、编辑、计划列表、产出物、设置和它的子页、保险箱、设备、所有表单。`List(.insetGrouped)` 或 `Form`。
- 行：左边图标或头像；主标题单行、尾部截断；下面一行灰色副标题；右边灰色值加 chevron（`NavigationLink` + `LabeledContent`
  系统自动画）。分隔线从文字起点开始（系统默认）。
- 分组标题、脚注用 Section 的 `header` / `footer`，加 `.textCase(nil)` 不转大写。
- **已做（2026-11-05，Botin 这一组截图审查）**：iOS 26 的分组标题不写字号时是约 17pt 的半粗字（参考 12、18、65 是约 13pt 的浅灰），
  所以 `header:` 里的字统一加 `groupHeader()`（`Components/ListStyles.swift`：`.footnote` + `Theme.inkSecondary` + `.textCase(nil)`）。
  Botin 这一组（资料、编辑、头像、工作区、两个说明 sheet、删除确认、引擎详情）都换了；资料这一组（计划列表和详情、进行中、运行详情、
  团队）2026-11-05 也换了（产出物的日期组标题照参考 22 是更浅的 `inkTertiary`）；别的页面还是 `.textCase(nil)`，各组对截图时
  逐页换（连接目录参考 52 的分类标题本来就大，不换）。同一个文件里还有：`compactGroupedList(top:)`（iOS 分组间距 `.compact`、
  滚动内容顶上的边距改小，导航栏下面到第一组约 25–36pt，参考 09、12、18、65）；`RowLabel`（行首的细的中性灰图标 + 标题，
  列表行里的 `Label` 图标默认是强调色、和正文一样大）。

### 2.6 导航栏和玻璃按钮

- **返回**：系统返回按钮（iOS 26 是玻璃圆），不自定义返回项。
- **关闭 sheet**：`ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }`，iOS 26 画成玻璃圆 ×。
- **主操作**（完成、保存、确认）：`.confirmationAction`，iOS 26 自动画成突出的玻璃胶囊；不合法时 `.disabled`，保存中换 `ProgressView`。
- **更多**：`Menu { … } label: { Image(systemName: "ellipsis") }`，不再用 `ellipsis.circle`（玻璃圆由系统画）。
- 并排的两个圆按钮（分享和更多、“?”和更多）中间放 `ToolbarSpacer(.fixed)`，否则 iOS 26 会把它们并成一个胶囊。
- **标题胶囊**：`ToolbarItem(placement: .principal) { Button { … } label: { HStack { 头像; Text(名字) } } }`。
- **按钮样式**：主按钮 `.glassProminent`，次按钮 `.glass`；小胶囊加 `.buttonBorderShape(.capsule)` + `.controlSize(.small)`；
  iOS 26 以下回退成 `.borderedProminent` / `.bordered`（写在 `Design/Glass.swift` 里，见 2.10）。
- **角标**：iOS 26 的工具栏项用 `.badge(_:)`。
- **不显示标题的页面**（Botin 资料、设置根页、引擎详情、连接详情）用 `hiddenInlineNavigationTitle(_:)`（`Components/ListComponents.swift`）。
  2026-11-05 截图发现以前写的 `inlineNavigationTitle(title) { EmptyView() }` 不管用：`.principal` 里是 `EmptyView` 时系统当没放，
  退回去画 `navigationTitle`，名字在导航栏和头部各出现一次。现在中间放一个 1pt 的透明点（读屏不念），`navigationTitle` 照旧
  （返回按钮的长按菜单、macOS 的窗口标题）。

### 2.7 底部浮动条

| 页面 | 内容 | 写法 |
|---|---|---|
| 首页 | 左边圆按钮（工作台）+ 右边胶囊搜索栏 | `.searchable` + `DefaultToolbarItem(kind: .search, placement: .bottomBar)` + `ToolbarItem(placement: .bottomBar)` + `ToolbarSpacer(.fixed, placement: .bottomBar)` |
| 对话 | 胶囊输入框 | `.safeAreaBar(edge: .bottom)` 里 `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in: .capsule)` |
| 对话内查找 | 搜索框 + 上 / 下两个圆 + “完成” | 同上，或 `ToolbarItemGroup(placement: .bottomBar)` |
| 只做一件事的页（领养 sheet、压栈的发送反馈、新建规则） | 全宽胶囊主按钮 | `.safeAreaBar(edge: .bottom)` + `.buttonStyle(.glassProminent)` + `.controlSize(.large)` + `.frame(maxWidth: .infinity)` |
| sheet 里的选择器 | 搜索 | `.searchable`（iOS 26 的 iPhone 上落在底部） |

主按钮放哪统一一条（参考 App 自己不统一）：**编辑表单**（编辑实例、登录信息，压栈或 sheet 都一样）右上放 `.confirmationAction`，
sheet 的左上再放关闭（`.cancellationAction`）；**“只做一件事”的页**（领养、新建规则、发送反馈）用底部全宽按钮。iOS 26 以下 `.safeAreaBar` 回退成 `.safeAreaInset`。

### 2.8 菜单、长按、弹窗、选择

- **菜单**：系统 `Menu`，图标加文字，用 `Section` 分两三组，破坏性的放最后、`role: .destructive`（系统标红）。分享类直接放 `ShareLink`。
- **长按**：`.contextMenu(menuItems:preview:)`，预览自己画（实例：头像 + 名字 + 最近一条）；子菜单用嵌套的 `Menu`，系统原地展开。
- **左滑**：`.swipeActions(edge: .trailing, allowsFullSwipe: false)`，只在 `List` 里有效。
- **确认**：删除类用 `.alert`（标题写对象，说明写后果）或 `.confirmationDialog`；改名用 `.alert` + `TextField`（iOS 26 自动是玻璃对话框）。
- **单选**：表单行里 `Picker(.menu)`（长列表系统菜单自己能滚）；整页单选 `Picker(.inline)`；三项以内的页内切换 `Picker(.segmented)`。
- **筛选胶囊**：新组件 `Components/FilterChipBar.swift`（横向 `ScrollView` 里的系统按钮，选中 `.glassProminent`、没选中 `.glass`），
  替换 `Screens/Plans/PlansComponents.swift` 的 `PlansFilterChip`（计划、产出物在用）。2026-11-05 资料这一组截图审查：外面原来包的
  `GlassEffectContainer`（`GlassGroup`）去掉了——合起来的玻璃在整排胶囊后面画出一块长方形的灰影（05 浅色一直拖到最后一个胶囊右边），
  参考 22、23 的胶囊各是各的。
- **触感**：用 `.sensoryFeedback`，不直接调 `UIFeedbackGenerator`。

### 2.9 Logo（`BrandLogo`）放哪

`BrandLogo`（原生矢量，`Design/BrandLogo.swift`）现在只用在两处：欢迎页（登录流程 `SignInFlow.swift` 的 `WelcomeView`，高 112）
和抽屉顶上（高 28）。关于页现在没有 Logo（`AboutScreen` 只有版本、备案、条款、AI 生成说明几组）。抽屉去掉以后：

- **设置页最底下的版本区**（75）：Logo 高 40 + “ThinkTin” + 版本（构建号），代替现在只有一行字的 `SettingsFootnote`。
- **首页“还没有实例”的空状态**：`ContentUnavailableView` 的图标位置放 `BrandLogo`，下面是“去领养”。
- **关于页**顶上可以新加一个（和设置页底部的版本区二选一，免得重复）。
- **欢迎页**属于登录流程，留不留跟着用户的设计走。
- **启动屏**（109）：`UILaunchScreen` 只能用图片资源，要 `tools/apple/brand_assets.py` 多导出一张单色矢量 PDF（`LaunchLogo`，
  深浅色两版）和颜色集 `LaunchBackground`（和 `paper` 同值）。
- 登录页用不用 Logo，跟着用户的设计走。
- 导航栏里不放 Logo（参考的首页没有标题）。

### 2.10 iOS 版本和兼容

- 部署目标是 iOS 17（`apps/apple/project.yml` 的 `deploymentTarget`、`ThinktinKit/Package.swift` 的 `platforms`）。工具栏、菜单、
  sheet、搜索栏、alert 用 26 SDK 编译后在 iOS 26 上自动是玻璃，旧系统是旧外观。
- 要显式调用的 iOS 26 API（Liquid Glass 和新工具栏）**集中写在新文件 `Design/Glass.swift`**，每个都带旧系统的退路，
  页面里不散写 `if #available`：

  | API | 最低系统 | iOS 17 / 18 的退路 |
  |---|---|---|
  | `.glassEffect(_:in:)`（含 `.regular.interactive()`）、`GlassEffectContainer` | iOS 26 | `.background(.regularMaterial, in: 形状)`；容器直接去掉 |
  | `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` | iOS 26 | `.bordered` / `.borderedProminent` |
  | `Button(role: .close)` / `Button(role: .confirm)` | iOS 26 | `Button { dismiss() } label: { Image(systemName: "xmark") }` 加读屏标签“关闭”/ 文字按钮“完成” |
  | `ToolbarSpacer(.fixed)` / `ToolbarSpacer(.flexible)` | iOS 26 | 不放（旧系统的工具栏项本来就分开）/ `ToolbarItemGroup` 里放 `Spacer()` |
  | `DefaultToolbarItem(kind: .search, placement: .bottomBar)` | iOS 26 | 不放，`.searchable` 落在导航栏下面 |
  | `.safeAreaBar(edge:)` | iOS 26 | `.safeAreaInset(edge:)` |
  | `.scrollEdgeEffectStyle(_:for:)` | iOS 26 | 不调 |
  | 工具栏项的 `.badge(_:)` | iOS 26 | 在按钮的 label 上叠一个小数字（`overlay`） |
  | `.sharedBackgroundVisibility(_:)` | iOS 26 | 不调 |
  | `.navigationTransition(.zoom(sourceID:in:))` + `.matchedTransitionSource(id:in:)` | iOS 18 | 普通压栈 |
  | `.toolbarVisibility(_:for:)` | iOS 18 | `.toolbar(.hidden, for: .navigationBar)`（iOS 16 就有） |

  其余用到的（`ContentUnavailableView`、`.searchable(text:isPresented:)`、`.sensoryFeedback`、`Section(isExpanded:)`、
  `.defaultScrollAnchor`、`SubscriptionStoreView`、`AccessibilityNotification`、`MagnifyGesture`、`.buttonBorderShape(.circle)`、
  `.toolbarTitleDisplayMode`、`.topBarLeading` / `.topBarTrailing`）iOS 17 就有，不用包。
- uicheck 的 SwiftUI 桩（`tools/apple/uicheck/Stubs/SwiftUI/`，签名照 iOS 17 SDK）现在只有 `scrollEdgeEffectStyle` 这一个 iOS 26 API，
  而且**连 `List`、`Form`、`Section`、`LabeledContent`、`ContentUnavailableView`、`.listStyle`、`.listRowSeparator`、`.listRowBackground`、
  `.scrollContentBackground`、`.swipeActions`、`.sensoryFeedback`、`Gauge`、`LazyVGrid`、`PhotosPicker`、`PasteButton`、`.fullScreenCover`、
  `.toolbarTitleDisplayMode`、`.topBarTrailing`、`.bottomBar` 都没有**（现在的页面一处 `List` / `Form` 都没用过）。第 0 轮要把上表的 iOS 26 API
  和这些一起补上（只有 iOS 有的放进 `#if canImport(UIKit)`），否则第 1 轮各线一换 `List` 就过不了 uicheck；补之前先 grep 整个 `Stubs/`，免得重复声明。
- 验收：外观以 iOS 26 为准；iOS 17/18 只要求能用、不乱。最低版本要不要提，见 6.3。

## 3. 信息架构和导航

### 3.1 导航图

```
首页：实例列表（.home，根）
├─ 左上 账号头像 ─────→ 设置（.settings，sheet，左上 ×）
│                        ├─ 账号 .account → 注销
│                        ├─ 模型 key .credentials、用量 .usage、保险箱 .vault
│                        ├─ 连接 .connections（新增，第 2 轮）
│                        ├─ 审批 .approvals、登录设备 .devices → 设备详情（本地）
│                        ├─ 外观 / 语言（本地页）、通知、触感、实时活动
│                        └─ 关于 .about、开源许可 .licenses、上手引导 .onboarding、发送反馈（本地，第 3 轮）
├─ 右上 + ─────────────→ 领养新实例（.adopt，新增，sheet）→ 成功后压栈进新实例的对话
├─ 左下 工作台（Menu）──→ 收件箱 .inbox / 审批 .approvals / 进行中 .activeRuns /
│                          计划 .plans(nil) / 团队 .teams / 产出物 .artifacts(nil)（都压栈）
├─ 底部 搜索栏 ────────→ 首页原地搜索（.search 改成“回首页并激活搜索”）
├─ 长按一行 / 左滑 ────→ 系统菜单（置顶、隐藏、实例资料、改名、新建计划、更多 › 复制 ID、删除）
├─ 列表底部“已隐藏 N 个”→ 已隐藏的实例（本地压栈）→ “?” 说明（sheet）
└─ 点一行 ────────────→ 对话（.conversation，改成压栈）
                         ├─ 标题胶囊 ──→ 实例资料（.instance，压栈）
                         │               ├─ 编辑（本地压栈）→ 头像（本地，第 2 轮）
                         │               ├─ 计划（.plans(instanceID:)，改）→ 计划详情 .plan / 新建 .newPlan（sheet）
                         │               ├─ 产出物（.artifacts(instanceID:)）→ 产出物 .artifact / 图片全屏查看（本地）
                         │               ├─ 工作区（本地压栈）→ 观看与接管（.instanceScreen，新增，第 3 轮）
                         │               ├─ 默认模型 → 模型路由 .modelRoutes
                         │               └─ “…”菜单：复制 ID、模型路由、删除实例（sheet）
                         ├─ “…”菜单 ──→ 实例资料、在对话中查找（本页）、模型路由、新建计划、产出物
                         ├─ 卡片和状态行 → 运行 .run / 运行树 .runTree / 审批 .approval / 模型路由 / 产出物 / 保险箱请求
                         └─ 长按消息 ──→ 系统菜单（复制、选择文本、分享、复制运行 ID、举报 → sheet）
```

### 3.2 页面清单

| 页面 | 参考截图 | 进入路径 | 出现方式 | 路由 |
|---|---|---|---|---|
| 首页（实例列表） | 1、110、111、113、119、120 | 启动后；所有返回的终点 | 根 | `.home`（改：永远是根，归 Shell） |
| 首页搜索 | 78–80 | 首页底部搜索栏 | 首页原地展开 | `.search`（改：回首页并激活搜索） |
| 实例长按菜单 | 32、33、112 | 长按首页一行或置顶头像 | 系统菜单 | — |
| 改名 | 68 的版式 | 长按菜单 → 改名 | 弹窗（`.alert` + 输入框） | 不加 |
| 删除实例 | — | 长按菜单 → 更多 → 删除；资料页“…” → 删除 | sheet（现有 `InstanceDeleteSheet`，带影响说明） | 不加 |
| 已隐藏的实例 | 114、116 | 列表底部“已隐藏 N 个”；全部隐藏时的空状态 | 压栈 | `.hiddenBotins`（审查修正时加的：推送、深链换掉主栈时它要跟着走） |
| 隐藏说明 | 115 | 已隐藏页右上“?” | sheet | 不加 |
| 工作台菜单 | 参考左下的“应用”按钮 | 首页左下 | 系统菜单 | 菜单项打开现有路由 |
| 领养新实例 | 34、35、117 | 首页右上“+” | sheet | 新增 `.adopt(agentID: AgentID?)` |
| 对话 | 2、118 | 首页点一行；搜索结果；推送 | 压栈 | `.conversation(id)`（改：`.root` → `.push`） |
| 对话“…”菜单 | 3 | 对话右上 | 系统菜单 | — |
| 对话内查找 | 4、5 | “…” → 在对话中查找 | 输入框换成查找栏 | 不加 |
| 消息长按 | 6 | 长按消息 | 系统菜单 | — |
| 引用回复 | 7 | 长按 → 回复 | 输入框长成卡片 | 不加（第 2 轮） |
| 实例资料 | 9 | 对话标题胶囊；“…”菜单；深链 `thinktin://instance/{id}` | 压栈 | `.instance(id)` |
| 资料页“…”菜单 | 10 | 资料页右上 | 系统菜单 | — |
| 编辑实例 | 12 | 资料页“编辑” | 压栈 | 不加（Agents 本地） |
| 头像 | 18–20 | 编辑页“头像”行 | 压栈 | 不加（第 2 轮） |
| 实例的计划 | 21 | 资料页“计划” | 压栈 | 改成 `.plans(instanceID:)` |
| 产出物 | 22、23、26、81–84 | 资料页“产出物”；对话“…”；工作台 | 压栈 | `.artifacts(instanceID:)` |
| 图片全屏查看 | 24、25 | 产出物里点图片 | 全屏 | 不加（Artifacts 本地 `.fullScreenCover`） |
| 工作区 | 资料页“电脑”行的位置（27、65） | 资料页第三行 | 压栈 | 不加（Agents 本地） |
| 观看与接管 | 27、29、30、31、89 | 工作区；对话里“等你接管”的状态行 | 压栈 | 新增 `.instanceScreen(InstanceID)`（第 3 轮） |
| 使用说明 | 28 | 观看页右上“?” | sheet | 不加（第 3 轮） |
| 设置 | 53、70、75 | 首页左上头像 | sheet | `.settings`（改：`.push` → `.sheet`） |
| 账号 | 54 | 设置第一行 | 设置里压栈 | `.account` |
| 用量 | 55 | 设置 | 设置里压栈 | `.usage` |
| 订阅 | 56 | 设置第一组 | 设置里压栈 | `.subscription`（2026-11-05 r2/settings，演示方案） |
| 保险箱 | 57、58 | 设置；推送和深链进填写请求 | 设置里压栈 / 主栈压栈 | `.vault`、`.vaultItem`、`.vaultRequest` |
| 新建 / 修改条目 | 59、99；卡片 60、94–96，联系信息 61、97、98（表单已做，保存即将推出） | 保险箱右上“+”菜单；条目详情“编辑” | 压栈（参考是压栈；现在是本地 sheet，见 4.9.6） | 不加（Vault 本地） |
| 权限与规则 | 62–64、100 | 设置“Botin”组第一行 | 设置里压栈；新建 / 编辑规则本地压栈 | `.permissions`（2026-11-05 r2/settings，演示规则） |
| 登录设备、设备详情 | 66–69 | 设置 | 设置里压栈 | `.devices`；详情不加 |
| 连接 | 36、37、40–52、101–107 | 设置“连接” | 设置里压栈；详情是 sheet | 新增 `.connections(category:)`、`.connectedApps`、`.connectionList`、`.connection`（第 2 轮，已做） |
| 外观、语言、触感 | 72–74 | 设置 | 设置里压栈 / 行内开关 | 不加（现有本地页） |
| 导入记忆 | 71 | 设置“Botin”组 | 设置里压栈 | `.importMemory`（2026-11-05 r2/settings） |
| 发送反馈 | 76、77 | 设置 | 设置里压栈 | `.feedback`（2026-11-05 r2/settings，用邮件发） |
| 收件箱、审批中心、进行中、团队、计划（全部） | 无 | 工作台；推送；深链 | 压栈 | 现有路由 |
| 新任务（选实例） | 11 的版式 | 引导、快捷指令 | sheet | `.newTask`（保留） |

### 3.3 路由要改的地方（`Navigation/`，第 0 轮统一改）

| 路由 | 现在 | 改成 | 跟着改 |
|---|---|---|---|
| `.home` | 没有实例时的根，属 `.conversation` | 永远是根：实例列表，属 `.shell`；离线策略 `cached` 不变 | `Router.rootRoute`、`AppShell`；`ConversationHomeScreen`（`RunTreeScreen.swift`）删掉，内容挪成首页空状态 |
| `.conversation(id)` | `.root`，打开等于切换实例并回到根 | `.push`；仍然记下当前实例（新任务、小组件、快捷指令默认用它） | `Router.open`、`selectInstance`、`AppRouteTests` |
| `.settings` | `.push`，`isTopLevel` | `.sheet` | `presentation`、`isTopLevel` |
| `.search` | `.push`，`isTopLevel` | 回到首页并激活搜索（`Router` 加 `searchRequest`，像现在的 `newTaskRequest`） | `presentation` 用 `.root` |
| `.plans` | 没有参数 | `.plans(instanceID: InstanceID?)`，nil 是全部实例 | `PlansDestination`、`instanceID`、深链（`thinktin://plan/{id}` 不受影响） |
| `.agentCatalog` | `isTopLevel`（抽屉直达） | 普通压栈；入口只剩新建表单的“了解引擎”（引导 12.17 的“新建 Botin”、没有实例时的“新任务” `AppModel.startNewTask`、对话页“实例已删”的空状态 2026-11-05 起都弹新建表单）；新建表单里选引擎用表单里的引擎菜单（4.7.1），设置根页不放入口 | `isTopLevel`、`startNewTask` |
| sheet 里的跳转 | `Router` 只有一层 `sheet`；`open` 遇到压栈页会关掉 sheet 再压到主栈，遇到 sheet 页会把当前 sheet 换掉 | 加 `sheetPath: [AppRoute]`，sheet 显示时 `open(.push)` 压进 sheet 自己的栈、不关 sheet；sheet 里再开 sheet 页（`.addCredential`、`.onboarding`、`.newPlan`）叠一层（`Router` 加 `nestedSheet`）；`.conversation` 例外，永远先关 sheet 再压进主栈（领养成功进对话、`NewTaskSheet` 选实例都靠它）；`show`（深链、推送）照旧先关 sheet 再建返回栈 | `Router`、`AppShell` 的 sheet 改 `NavigationStack(path:)`、`Tests/ThinktinKitTests/Navigation/`。不改的话设置变成 sheet 以后，保险箱点条目（`router.open(.vaultItem)`）、模型 key 点“添加”（`router.open(.addCredential)`）、用量跳转都会把设置关掉 |
| `isTopLevel` / `openFromDrawer` | 抽屉用 | 改名 `openTopLevel`，给工作台菜单用（先回根再压） | `ShellDrawer` 删掉 |
| `isDrawerOpen`、`openDrawer` 等 | 抽屉状态 | 删掉 | 截图脚本的 `THINKTIN_OPEN_DRAWER` 一起去掉 |
| 新增 `.adopt(agentID: AgentID?)` | — | sheet，属 `.agents`，离线 `unavailable` | `feature`、`presentation`、`offlinePolicy`、`title` |
| 新增 `.connections(category:)` 等四个 | — | 第 2 轮（已做，r2/connections）；新功能 `.connections`，都压栈、离线 `unavailable` | 同上 |
| 新增 `.instanceScreen(InstanceID)` | — | 第 3 轮；压栈 | 同上 |

### 3.4 深链和推送的返回栈

docs/ios.md 第 6.1 节现在是“根（当前实例的对话）→ 目标页”。改成：

- 和实例有关的目标（实例资料、模型路由、实例的产出物、运行详情）：**首页 → 该实例的对话 → 目标页**，返回先回到对话
  （和 `AppRoute.instanceID` 注释里“返回时回到这个实例的对话”的意思一致）。
- 其余（收件箱、审批、计划、保险箱请求）：**首页 → 目标页**。
- 推送只有实例 id 时：首页 → 该实例的对话。
- 安卓现在还是抽屉结构，两端的返回栈会不一样；安卓要不要跟着改另议（6.1）。

## 4. 逐页规范

按参考 App 的分组排。每页写：截图编号、布局、原生控件、交互、状态、对应的 ThinkTin 功能和现有代码、要改什么（带轮次，见第 7 节）。
同一页的几种状态（菜单展开、滚到底、空状态）合在一节里。

### 4.1 启动

#### 4.1.1 启动屏（109）

- **布局**：整屏纯色底，正中偏下一个约 60pt 的单色 Logo；没有文字、进度条、按钮。
- **原生**：Info.plist 的 `UILaunchScreen`：`UIColorName` = `LaunchBackground`（浅色、深色两套），`UIImageName` = `LaunchLogo`
  （单色矢量 PDF，勾选保留矢量，深浅色两版）。不做 SwiftUI 画的假启动页，也不做启动动画。
- **交互 / 状态**：没有。冷启动时系统显示，第一帧出来自动消失。
- **ThinkTin 现在**：`apps/apple/project.yml` 里是 `UILaunchScreen: {}`（空，系统默认纯色底、没有 Logo）；Assets 只有
  `AppIcon`、`AccentColor`；`BrandLogo` 是 SwiftUI 视图，启动屏用不了。
- **要改**：`tools/apple/brand_assets.py` 多导出 `LaunchLogo` 和 `LaunchBackground`（生成物照规矩提交，不手改），project.yml
  填上两个键。纯客户端，第 0 轮。

#### 4.1.2 登录方式（108）

不照做：登录页由用户自己设计。参考 App 在这里用的是“添加账户”（多账户），见 6.20。

### 4.2 主页

#### 4.2.1 首页：实例列表（1、119、120、111、110、113）

- **布局**
  - 没有导航标题。左上是玻璃圆按钮，里面是账号头像（昵称第一个字）；右上是玻璃圆“+”。
  - plain 列表，没有分隔线，每行约 72pt：左边 48pt 实例头像，右下角叠状态角标；中间第一行名字（`.headline`）、
    右边时间（`.caption`、`.tertiary`，今天显示 HH:mm，更早显示日期）；第二行预览（`.subheadline`、`.secondary`，单行截断，内容见 6.7）。
  - 置顶的实例（第 2 轮）在列表最上面变成居中的大头像网格（80pt + 名字 `.footnote`，每排 3 个；参考只截到置顶一个的样子，多个时怎么排是推测的），下面接普通行，中间没有分区标题。
  - 有待审批或未读时，列表最上面一行提示胶囊：“2 个审批在等你 · 3 条未读”，点了进审批中心或收件箱（6.1）。
  - 底部浮动：左边玻璃圆按钮（工作台，`square.grid.2x2`，带角标），右边占满剩余宽度的玻璃胶囊搜索栏。列表从上下玻璃下面滚过去。
- **原生控件**
  - 根：`NavigationStack` 的根页，不设标题，`.toolbarTitleDisplayMode(.inline)`。
  - 左上：`ToolbarItem(placement: .topBarLeading) { Button { router.open(.settings) } label: { 头像 } }`。
  - 右上：`ToolbarItem(placement: .topBarTrailing) { Button("新建 Botin", systemImage: "plus") { router.open(.adopt(agentID: nil)) } }`。
  - 列表：`List { 提示行; 置顶网格行; ForEach { NavigationLink(value: AppRoute.conversation(id)) { HomeInstanceRow } } }`
    + `.listStyle(.plain)` + `.listRowSeparator(.hidden)`；置顶网格是 `LazyVGrid`，放在第一行（`.listRowBackground(Color.clear)`）。
  - 时间：外面包 `TimelineView(.everyMinute)`，用 `Formatting` 的时间格式。
  - 底部：`.searchable(text:isPresented:)` + `DefaultToolbarItem(kind: .search, placement: .bottomBar)`；
    工作台 `ToolbarItem(placement: .bottomBar) { Menu { … } label: { Image(systemName: "square.grid.2x2") } }.badge(n)` + `ToolbarSpacer(.fixed, placement: .bottomBar)`。
  - 工作台菜单项：收件箱、审批、进行中、计划、团队、产出物，每项用 `Button { } label: { Text(标题); Text("3 条未读") }`
    （第二个 `Text` 在菜单里显示成副标题）。
  - 下拉刷新 `.refreshable { await model.refresh() }`；左滑 `.swipeActions`；长按 `.contextMenu(menuItems:preview:)`（4.2.2）。
  - 空状态：`ContentUnavailableView`。
- **交互**：点一行压栈进对话；左上进设置（sheet）；“+”新建 Botin（sheet）；左下工作台菜单；点搜索栏原地搜索（4.2.4）；
  左滑置顶 / 隐藏（第 2 轮）；长按菜单；下拉刷新；从对话返回时回到原来的滚动位置。
- **状态**
  - 加载中：没有缓存时 `ProgressView`；有缓存先显示缓存再刷新（现有规则）。
  - 离线：显示缓存 + 顶部离线横幅（现有）。
  - 没有实例（第一次登录就是这样）：`ContentUnavailableView`，图标位置放 `BrandLogo`，标题“还没有 Botin”，说明“Botin 是替你干活的助手。
    起个名字、选一个引擎，它就能帮你写东西、查资料、跑任务。”，按钮“新建 Botin”（用户 2026-11-05 定的文案；英文 “No Botins yet” /
    “A Botin is an assistant that works for you. Give it a name and pick an engine, and it can write, look things up and run tasks for you.” /
    “New Botin”；在 `HomeText`）。按钮 `.glassButtonStyle(.prominent)` + `.controlSize(.large)`，打开和“+”同一张新建表单（4.7.1）。
    联网拉到了、账号里没有 Botin 才显示它（`HomeList.placeholder` / `AppModel.homePlaceholder` 的 `.noBotins`）；离线时不引导新建，
    还是“这台设备上还没有保存的 Botin”（`.offlineWithoutCache`）。第一次登录不弹引导（12.17），看到的就是这个空状态（用户 2026-11-05
    定的“首次登录首页是空的”；新用户登录不再进 `.onboarding`，换新机时只有有 Botin、没有 key 的账号才弹，引导从设置里打开）。
    网络回来时实例列表没拉到过就补拉（`AppModel` 收到 `.reachable`），不会一直转圈。已做（2026-11-05）。
  - 全部隐藏（113，第 2 轮）：“Botin 都藏起来了” + `Button("查看藏起来的 Botin")`（`.bordered`、胶囊）。文案是 ThinkTin 自己的
    （2026-11-05 改；原来照参考的“所有 Bot 均已隐藏”“显示已隐藏的 Bot”只换了名词）。
  - 拉取失败：`ErrorBanner`，可重试。
  - 有运行在等你处理：行内第二行换成“N 个在等你处理”（现在抽屉里就有），角标用 `warning` 色。
  - 运行中：状态角标会呼吸（`StatusTone` 规则不变）。
- **ThinkTin 现在**：实例列表在抽屉 `Shell/ShellDrawer.swift`（`DrawerInstanceList`、`DrawerInstanceRow`：状态点、名字、
  相对时间、“N 个在等你处理”，`VStack` + `Button(.plain)` 自己画）；根是 `Shell/AppShell.swift` 的 `RootPage`（抽屉按钮、
  左缘右划手势、`InstanceSwitcher`）；没有实例时是 `ConversationHomeScreen`；数据在 `ViewModels/Shell/AppModel.swift`
  （`instances`、`activity(for:)`、`badges`）；头像是 `Screens/Agents/AgentMonogram.swift`。
- **要改**
  - 新建 `Shell/Home/`：`HomeScreen.swift`、`HomeInstanceRow.swift`、`PinnedInstancesGrid.swift`（第 2 轮）、`WorkbenchMenu.swift`。
  - 新建 `ViewModels/Shell/HomeListModel.swift`：排序（置顶在前，其余按最后活动）、隐藏过滤、预览文字、提示行的数；
    `InstancePreferencesStore`（按账号存置顶、隐藏，仿 `AppModel.swift` 里的 `InstanceSelectionStore`）。Linux 上能测。
  - 删掉 `ShellDrawer.swift`、`InstanceSwitcher.swift`、`RootPage` 的抽屉按钮和左缘手势。
  - 预览：`cachedRuns(instanceID:limit: 1)` 的摘要或任务（6.7），agent 写的摘要带小号 AI 标识。
  - 参考的“主 Bot”橙色星标不做，那个位置放状态角标。（2026-11-05 改了：主 Botin 做了以后，没有状态角标时画星标，见 4.4.5。）
  - 第 0 轮先出最小可用的列表，第 1 轮做完整版，置顶、隐藏第 2 轮。

- **已做（2026-11-05，第 1 轮 A 线，对过参考 01、110、111、113、119、120；第 2 轮的置顶、隐藏一起做了）**
  - 版式照参考量（393pt 宽，1pt ≈ 1.525px，`HomeLayout`）：行高约 83pt，44pt 头像（`Metrics.Avatar.list` 48 → 44）离左边 22pt，
    文字从 82pt 起，时间离右边 24pt，名字和预览中间 4pt；左上账号、右上“+”、左下工作台、底部搜索栏的位置不变（第 0 轮已经对上）。
  - 行换成按钮（`Router.open(.conversation(id))`），不再是 `NavigationLink`：plain 列表里的 `NavigationLink` 会画 chevron，参考没有。
  - 预览照 6.7 B：在等你处理、进行中照旧说状态；闲着时是本机缓存里的最后一条（`HomeLastMessage.latest(in:)`：最近一次的摘要，
    前面放“AI 生成”标识，参考那个位置是个小图标；没有摘要、是你发的写“你：任务原文”；计划派的跳过）。创建中、不认识的状态照旧说状态。
    `AppModel.lastMessages` 启动时从缓存读，刷新完、回到首页时（`reloadLastMessages()`）重读，只读缓存、不联网。
  - 置顶（参考 111、120）：列表第一行是居中的大头像（80pt + `.footnote` 名字，一排 3 个、每排居中，`PinnedInstancesGrid`），
    上面比普通行多留约 18pt、下面 20pt，中间没有分区标题；按置顶的先后排。置顶的头像长按是同一套菜单，没有左滑。
  - 左滑（参考 110）：系统 `.swipeActions`，最右边红色“隐藏”，再是灰色“置顶”（`HomeInstanceMenu.swipeItems`）。
  - 置顶、隐藏只存这台设备（`InstancePreferencesStore`，`UserDefaults` 一个键，按实例 id、不分账号，和头像外观一样；6.10 A），
    互斥：隐藏时取消置顶。删了 Botin（资料页、首页长按删除、事件流说没了）时删记录。
  - 都隐藏了（参考 113）：正中小的 `eye.slash` + 灰字“Botin 都藏起来了” + 玻璃胶囊“查看藏起来的 Botin”（比
    `ContentUnavailableView` 小一号，照参考自己排；文案 2026-11-05 换成自己的，见下面还原度评审那条）。部分隐藏时列表最底下一行灰字
    “已隐藏 N 个 Botin”（参考没有，不然找不到入口）。
  - 还没做：从对话返回时回到原来的滚动位置（要在模拟器上看系统是不是本来就保留）。
  - “等你处理”提示行（2026-11-05，四条 r2 线合进来以后补的）：有待审批或收件箱未读时列表最上面一个玻璃胶囊（`HomeAttentionRow`，
    ThinktinKit `HomeAttentionHint`）：“2 个审批在等你 · 3 条未读”，只有一样时只写那一样；图标用警告色（有审批是 `checkmark.shield`，
    只有未读是 `tray`）；点了 `openTopLevel`：有待审批进审批中心，只有未读进收件箱（和工作台菜单一样是顶级页面）。待确认的计划、
    进行中的运行不算（只在工作台菜单的副标题上）。参考里没有这一行，在模拟器上看一眼它和置顶大头像、第一行的间距。
- **审查修正（2026-11-05）**：行的预览是最后一条时，暂停、归档等状态只画在头像角标上（头像对读屏隐藏），读屏在名字后面
  另外念状态（`HomeRowPreview.spokenState`）；置顶的格子同样。预览里引用回复只取正文（`MessageQuote.body`），不显示“你：> 引用…”。
- **还原度评审修正（2026-11-05，截图 00、01、25、27 对参考 01、113、119、120）**
  - 左上账号按钮：iOS 26 给非符号的标签（头像）套的是加了内边距的胶囊（约 56×44pt，里面一个 24pt 的头像），和右上 44pt 的“+”圆对不上。
    现在这一项去掉工具栏共用的玻璃底（`hidesSharedGlassBackground`），按钮自己画 44pt 的玻璃圆（`glassBackground(in: Circle(),
    interactive: true)`，iOS 17 / 18 是材质），里面 36pt 的 `AccountAvatar` 几乎填满（`Metrics.Avatar.account`，参考约 36–38pt），
    和系统工具栏按钮一样不跟动态字体变大。macOS 照旧是工具栏里 24pt 的头像。
  - 工作台的角标：View 的 `.badge(_:)` 在 iOS 26 的工具栏里不画，之前演示数据有 1 个审批、3 条未读，按钮上却没有数。现在角标加在
    `ToolbarItem` 上（Glass.swift 的 `toolbarItemBadge`，iOS 26 / macOS 26 是 `ToolbarContent.badge(_:)`），数由首页 `body` 读好传给
    `HomeToolbar`；按钮上的 `toolbarBadge` 只在旧系统上叠数。
  - 底部搜索栏的占位字从“搜 Botin、任务、收件箱、计划、产出物”改成“搜索”/“Search”（`SearchText.prompt`）：原来的在约 270pt 宽的胶囊里
    带省略号，参考是一个词；能搜什么由搜索时顶上的筛选胶囊说。
  - 都隐藏了（参考 113）：`eye.slash` 从 `.title3`（约 26pt）缩到 `.body`（约 19pt），按钮的字从 17pt 改成 medium 的 `.subheadline`。
    文案换成自己的：“Botin 都藏起来了”“查看藏起来的 Botin”（英文 “Your Botins are all tucked away” / “See Hidden Botins”；`HomeText`），
    和“关于隐藏”的“随时放回来”一个口气，不再是参考的句子只换名词。
  - 留着不改的（评审确认是 ThinkTin 的东西）：空状态的 `BrandLogo` 和大号橙色“新建 Botin”、橙色的“+”和工作台图标、`square.grid.2x2`、
    “等你处理”提示行、预览的警告色和状态角标、首页第一行离按钮近约 12pt（系统 iOS 26 工具栏比参考自画的顶栏低，第一行的绝对位置一样）。

#### 4.2.2 实例长按菜单（32、33、112）

- **布局**：背景模糊变暗；上面是预览卡（小头像 + 名字，分隔线，最近一条消息的灰气泡，多行）；下面是玻璃菜单；
  “更多 ›”在原地展开子菜单，父菜单变暗。
- **原生**：`.contextMenu { … } preview: { InstancePreviewCard(…) }`；子菜单 `Menu("更多", systemImage: "ellipsis") { … }`；
  隐藏、删除 `role: .destructive`；复制后 `.sensoryFeedback(.success, trigger:)`。
- **ThinkTin 的菜单项（建议）**
  - 第一组：置顶 / 取消置顶（`pin` / `pin.slash`）、隐藏（`eye.slash`，destructive）。第 2 轮才有。
  - 第二组：实例资料（`info.circle`）、改名（`pencil`）、新建计划（`calendar.badge.plus`）。
  - 更多：复制实例 ID（`doc.on.doc`）、模型路由（`cpu`）、删除实例（`trash`，destructive，接 `InstanceDeleteSheet`）。
  - 参考里的“标为未读”“新建分组”“替换主 Bot…”“分享为模板”见 6.10、6.21。
- **交互**：点预览卡进对话；点菜单项执行后菜单收起；点空白处收起。
- **状态**：置顶与否文案跟着变；离线时要联网的项（改名、新建计划、删除）禁用；实例在运行或等你处理时预览卡顶上显示状态。
- **ThinkTin 现在**：首页没有长按。改名以前是 `InstanceRenameSheet`（2026-11-05 C 线换成压栈的编辑页 `InstanceEditScreen`，A 线的长按改名照旧用 `.alert` + `InstanceNameRule`）、删除是 `InstanceDeleteSheet`（都在 `Screens/Agents/`）；
  复制用 `Support/Pasteboard.swift`。
- **要改**：预览里的最近一条用 `cachedEventsBefore(instanceID:beforeSeq: nil, limit:)` 取最后一条 agent 消息，没缓存时退回
  `cachedRuns` 最新一次运行的摘要。改名用 `.alert` + `TextField`，按 `InstanceNameRule` 校验，Shell 自己调 `renameInstance`，
  不依赖 Agents 的页面。第 1 轮（置顶、隐藏第 2 轮）。

- **已做（2026-11-05，第 1 轮 A 线，对过参考 32、33、112）**：系统 `.contextMenu(menuItems:preview:)`，和参考一样一列、不分组，
  最后“更多”在原地展开（嵌套的 `Menu`）。顺序在 ThinktinKit 的 `HomeInstanceMenu`：Botin 资料、置顶 / 取消置顶、新建计划、改名…、
  隐藏（红），更多里复制 Botin ID、删除（红）。参考的“标为未读”“新建分组”“替换主 Bot…”“分享为模板”ThinkTin 没有（6.10、6.21），
  那几个位置换成资料、新建计划、改名；模型路由没放进来（资料页和对话页的菜单里有）。离线时新建计划、改名、删除灰掉。
  预览卡（`HomeInstancePreviewCard`，宽 320pt，量自参考 32）：28pt 头像 + 名字（在等你处理、进行中时下面一行状态），分隔线，
  最后一条的气泡（agent 的在左、`agentBubble`、下面带“AI 生成”标识，你发的在右、`userBubble`，最多 8 行），没缓存时一行灰字状态；
  卡片底是 `paper`、气泡亮一档，和参考一样。改名是系统弹窗 + 输入框（`HomeRenameAlert`，`InstanceNameRule` 不合规时“保存”灰着，
  改不成再弹一个说原因），调 `AppModel.renameInstance`，首页、对话页标题马上变。删除弹资料页同一张确认页（`InstanceDeleteSheet`，
  列影响 + 二次确认），删成了走 `InstanceDetailScreen.leaveDeletedInstance`。复制 ID 有成功的触感（`appFeedback`）。

#### 4.2.3 已隐藏的实例和说明（114、115、116）

- **布局**：压栈页，标题“已隐藏的实例”，右上玻璃“?”；plain 列表，每行头像 + 名字 + 右边小胶囊“取消隐藏”；
  全部取消后中间一行灰字“没有隐藏的实例”。“?”弹 sheet“关于隐藏”：左上 ×，一组 insetGrouped 三行（图标 + 标题 + 多行说明）。
- **原生**：`List(.plain)`；`Button("取消隐藏").buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)`；
  空时 `.overlay { ContentUnavailableView(…) }`；说明 `.sheet` + `.presentationDetents([.medium, .large])` + `Button(role: .close)`；
  每行 `Label { VStack { 标题; 说明 } } icon: { Image(systemName:) }`。
- **交互**：点“取消隐藏”这一行带动画移除，实例回到首页；点行进对话；“?”看说明。
- **ThinkTin 现在**：没有。
- **要改**：Shell 本地页（不加路由）。入口有两个：全部隐藏时的空状态按钮，和列表最底下一行“已隐藏 N 个”（0 个时不显示，
  参考 App 只有前一个，部分隐藏时找不到入口）。说明文案写 ThinkTin 的实际行为：隐藏只是首页不显示，计划照常跑，
  审批和推送照常发（6.10）。第 2 轮。

- **已做（2026-11-05，第 1 轮 A 线，对过参考 114、115、116）**：`HiddenInstancesScreen`，首页本地压栈（`navigationDestination(isPresented:)`，
  不加路由），标题“已隐藏的 Botin”（系统的 inline 标题；参考的标题在玻璃胶囊里，别的线都用系统标题，没照做），右上玻璃“?”。
  plain 列表、行和首页一样高（44pt 头像 + `.body` 名字），右边玻璃小胶囊“取消隐藏”（`smallCapsuleButton()`；2026-11-05 改成常规大小，
  见下面还原度评审那条），点了带动画回到首页；
  点头像和名字进对话（`Router.open`，“首页 → 对话”）。都取消了以后正中一行灰字“没有隐藏的 Botin”（参考 116，没有图标）。
  “?”弹 `HidingHelpSheet`（large，左上 ×，一组分组卡片三行：照常干活 / 只是首页不显示、只在这台设备上 / 随时放回来，
  文案 `HomeText.hidingFacts` 是 ThinkTin 自己的，写的是真实行为）。
- **审查修正（2026-11-05）**：改成有路由的页 `.hiddenBotins`（归 `.shell`、压栈、离线有缓存），首页的两个入口都走
  `router.open`：以前是本地 `navigationDestination(isPresented:)`，`Router` 看不见它，推送、深链、`popToRoot()` 换掉主栈时它还留在
  栈里（返回落到已隐藏页，首页的刷新在别的页面上跑）。标题照参考 114 放进玻璃胶囊（`capsuleNavigationTitle`：iOS 26 玻璃、
  旧系统材质，工具栏的共用玻璃底去掉免得两层）。
- **还原度评审修正（2026-11-05，截图 26 对参考 114）**：“取消隐藏”从小号胶囊（约 27pt 高、15pt 字）改成常规大小的玻璃胶囊（约 34pt 高），
  字是 medium 的 `.footnote`（约 13pt），和参考一样胶囊高、字小。胶囊里的标题（`capsuleNavigationTitle`）从 `.headline`（semibold）
  改成 medium 的 `.body`，系统标题（`inlineNavigationTitle`）不变。橙色的“?”和“取消隐藏”（强调色）、头像的状态角标、
  标题“已隐藏的 Botin”照旧。

#### 4.2.4 首页搜索（78、79、80）

- **布局**：点底部搜索栏后原地进入搜索：导航栏收起；顶上一排横向筛选胶囊（全部、消息、实例、收件箱、计划、产出物）；
  底部搜索框聚焦，右边系统给的玻璃 ×。空查询 + “全部”时直接列出实例（行尾一个灰色类型标签）；空查询 + 某一类时中间一个小放大镜 + “搜索消息”；
  有结果时 plain 列表：40pt 头像（2026-11-05 照参考 78、80 量出来改成 44，和首页的行一样）+ 粗体“你发给 X” / “X 发给你” + 右边日期
  （本周内写星期几）+ 下面一行灰色摘录。
- **原生**：`.searchable(text:isPresented:)` + `DefaultToolbarItem(kind: .search, placement: .bottomBar)`；搜索时
  `.toolbarVisibility(.hidden, for: .navigationBar)`（iOS 18；iOS 17 用 `.toolbar(.hidden, for: .navigationBar)`）；筛选用 `FilterChipBar`，放 `.safeAreaInset(edge: .top)`；空状态
  `ContentUnavailableView`；没结果 `ContentUnavailableView.search(text:)`；`.scrollDismissesKeyboard(.immediately)`。
- **交互**：点胶囊换类型；点结果：实例 → 对话，运行 → 运行详情，收件箱 → 那一条，计划 → 计划详情，产出物 → 产出物页；
  点 × 回到首页。
- **状态**：空查询、有结果、没结果、离线时只搜了缓存（现有 `SearchText.cacheOnly` 提示）。
- **ThinkTin 现在**：`.search` → `Screens/Search/SearchScreen.swift`（压栈页，结果分组卡片）+ `ViewModels/Search/SearchModel.swift`
  （`SearchKind`：instance / run / inbox / plan / artifact；每个实例搜本机缓存里最近 200 条运行的任务和摘要，联网时再拉计划和每个实例
  最近 100 个产出物）。agent 回复的正文（事件）现在不搜。
- **要改**
  - `SearchModel` 加类型筛选；一次运行拆成两种结果：任务命中显示“你发给 X”，摘要命中显示“X 发给你”（带 AI 标识）。
  - “消息”想更接近参考（搜回复正文），可以再搜本机缓存的事件（`cachedEventsBefore`，每个实例最多 2000 条），纯客户端；缓存以外的
    全文搜索才要后端。
  - 结果视图拆成能嵌进别处的 `SearchResultsView`，首页嵌进去；`.search` 路由改成回首页激活搜索。
  - 参考的“群聊”筛选 ThinkTin 没有，换成“收件箱”（6.24）。
  - iOS 17/18 上 `.searchable` 在导航栏下面，照样能用。
  - 第 1 轮做嵌入和空查询列实例，第 2 轮做筛选和“谁发给谁”。
- **已做（2026-11-05，第 1 轮 D 线，对过参考 78、79、80；第 2 轮的筛选和“谁发给谁”一起提前做了）**：Search 目录拆出
  `SearchResultsView`，首页（`HomeScreen`，A 线的文件，只换了这一块）在搜索栏激活时就换成它（以前要有字才换），点 × 回首页时筛选
  回到“全部”；iOS 26 上搜索时藏导航栏（`hidesNavigationBarWhileSearching`，Glass.swift；iOS 17 / 18 的搜索栏挂在导航栏下面，不藏）。
  顶上 `FilterChipBar`：全部 / 消息 / Botin / 收件箱 / 产出物 / 计划（`SearchModel.filters`、`SearchModel.filter`；6.24 A，参考的“群聊”
  换成收件箱、“文件”是产出物），用 `floatingBar(edge: .top)` 浮在列表上。没输入：“全部”和“Botin”列出 Botin（最近活动的在前，
  右边灰字“Botin”，`SearchModel.suggestions`），别的类正中一个小放大镜和“搜索消息”这样一句（`SearchText.searchKind`）。
  有字：plain 列表、没有分隔线；“全部”按种类分组（运行这一组改叫“消息”），选了一类的不分组、最多 100 条（`filteredLimit`）。
  一次运行拆成两条消息：任务“你发给 X”、摘要“X 发给你”（`SearchResult.direction`、`SearchText.messageTitle`，各自要包含全部关键词，
  摘要那条带 AI 标识）。一行 `SearchResultRow`：40pt 头像（Botin、消息）或种类图标方块，粗体标题，右边时间（今天写时刻、昨天、一周内
  写星期几、更早写日期，`SearchText.date`），一行灰色摘录。没结果是 `ContentUnavailableView`，离线时说只搜了缓存。压栈的 `SearchScreen`
  内容一样。回复正文（缓存的事件）还没搜。
- **还原度评审修正（2026-11-05，截图 09 对参考 78、80）**
  - 筛选胶囊（`FilterChipBar`，计划、产出物、保险箱、连接目录也用它）：字从 17pt 改成 medium 的 `.footnote`（参考 22、36、78 量出来约
    13pt），两个字的胶囊从约 58pt 窄到约 52pt，首页搜索的六个胶囊一屏放得下；没选中的字是正文色（`Theme.ink`），只有选中的那个是强调色的
    `.glassProminent`，以前没选中的字也是橙色，选中的不显眼。搜索里胶囊左右留 20pt（参考第一个胶囊离左边约 20pt），别处照旧。
  - 一行和首页的行一样排（`SearchLayout`）：44pt 头像（或同样大的种类图标）离左边 22pt、文字从约 82pt 起、右边的种类标签 / 日期离右边
    22pt、`.footnote`（以前 `.subheadline`），上下各 18pt，一行约 80pt（参考 80 量出来约 81pt）。“还有 N 条”“只搜了缓存”的灰字左右对齐到
    同一条边。
  - 占位字改成“搜索”（见 4.2.1 的还原度评审那条）。
  - 截图脚本：09-search 浅色那张被系统的“滑动输入”介绍盖住了键盘（深色那张没有，是整轮第一次弹键盘才出）。`defaults write` 是开着机写的，
    键盘没读到；`tools/apple/screenshots.sh` 现在写完重启一次模拟器（`shutdown` → `boot` → `bootstatus -b`）。
  - 留着不改的：键盘弹着、搜索栏和 × 贴着键盘（iOS 26 系统的，参考没键盘是因为镜像拍不到）；选中的胶囊是橙色 `glassProminent`（参考是白底黑字）；
    胶囊的种类是 6.24 A 定的。

### 4.3 对话

#### 4.3.1 对话页（2、118）

- **布局**
  - 导航栏透明：左系统返回；中间玻璃胶囊（24pt 头像 + 名字）；右玻璃“…”。
  - 时间线：agent 回复是左对齐的灰色气泡（圆角 20，最宽约屏宽 85%，内边距 16，`.body`），“AI 生成”标识在气泡下方；
    用户消息是右对齐的气泡（`userBubble`；参考截图里没有出现用户打字发的消息，只有通话记录行，这一条是按 iOS 习惯定的，没有参照）。工具调用、审批、产出物、子运行、保险箱填写这些卡片仍是全宽卡片，不放进气泡。
  - 运行之间加居中的小灰字时间分隔（`.footnote`、`.secondary`，今天“今天 22:09”，本周“星期二 02:22”，更早写日期）；
    计划、流水线、委派发起的运行，来源行改成居中的小灰 `Label`。
  - 底部浮动的玻璃胶囊输入框（高约 52，左右留约 20）：输入、右边发送 / 停止圆按钮；附件“+”等 6.13（之前不放）。
    模型标签、排队提示、字数、错误横幅放在输入框正上方一行小字（左对齐），超限时字数标红。
- **原生控件**
  - 标题：`ToolbarItem(placement: .principal) { Button { router.open(.instance(id)) } label: { HStack { InstanceAvatar(size: 24); Text(name) } } }`。
  - 右上：`ToolbarItem(placement: .topBarTrailing) { Menu { … } label: { Image(systemName: "ellipsis") } }`（4.3.2）。
  - 时间线保留 `ScrollView` + `LazyVStack` + `.defaultScrollAnchor(.bottom)` + `.scrollDismissesKeyboard(.interactively)`。
  - 气泡：`.background(Theme.agentBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))`。
  - 输入框：`.safeAreaBar(edge: .bottom) { GlassEffectContainer { HStack { … } }.glassEffect(.regular.interactive(), in: .capsule) }`；
    `TextField(axis: .vertical).lineLimit(1...6)`。
  - 发送：`Button("发送", systemImage: "arrow.up").labelStyle(.iconOnly).buttonStyle(.glassProminent).buttonBorderShape(.circle)`；停止换 `stop.fill`；
    发送中换 `ProgressView`。
  - 去掉 `solidTopScrollEdge()`，用系统默认的软渐隐。
- **交互**：点标题进实例资料；“…”菜单；长按消息（4.3.4）；左缘右划或点返回回首页；下拉加载更早的记录（现有）。
- **状态（全部保留）**：加载中、空对话、实例已删、正在唤醒、流式输出、运行状态行（等审批 / key / 电脑、失败后重试）、
  发送或停止失败的横幅、排队提示、字数超限、离线只读、密码拦截 sheet、没配 main 路由的提示。
- **新实例第一次进来（118）**：参考是自动欢迎语 + “你最想让我先做什么”的 A/B/C/D 选择卡。ThinkTin 没有欢迎消息，
  也没有“agent 提问 + 选项”的结构化事件；建议第 2 轮在客户端画一张静态卡：先查 main 路由和 key，没配好时卡片引导去配；
  配好了给 3–4 个示例任务，点一个就 `sendMessage`（6.18）。第 1 轮先用 `ContentUnavailableView`“给 X 布置第一个任务”。
- **已做（第 1 轮 B 线，2026-11-05）**：照参考 02、118 的版式。导航栏中间是能点的 `ConversationTitle`（24pt 头像 + 名字，
  `Button`，玻璃胶囊是自己画的、见下面的还原度评审修正，点了 `router.open(.instance(id))`），右边“…”（4.3.2）。agent 的回复、思考、待办、
  没有过程记录的运行结果是左边的 `agentBubble` 气泡（圆角 20，内边距 16 × 12，右边留 48pt），“AI 生成”标识在气泡下面；
  用户消息是右边的 `userBubble` 气泡，开头是引用块的（4.3.5）在气泡里先画一小块引用（`QuotedBlock`）。运行之间的时间分隔
  `ConversationTimeSeparator`（ViewModels/Conversation，隔 15 分钟以上或跨天才加，今天 / 昨天 / 星期几 / 日期，`.footnote` +
  三级灰，参考里就是这个灰度）；来源行改成居中的小灰字和图标。输入框是 `floatingBar` 里的玻璃胶囊（高 48，左右各留 32pt，
  参考量出来约 31pt；主按钮是 36pt 的 `glassProminent` 圆，发送 `arrow.up`、停止 `stop.fill`、发送中转圈），有引用时长成
  圆角 28 的卡片；模型标签、排队提示、超限提示、字数是输入框正上方的小玻璃胶囊（旧系统的 `safeAreaInset` 下也挡得住后面滚过的
  内容）。参考输入框里的“+”（附件，6.13）、麦克风和语音（6.23）没有对应的功能，没放。还没有任务时是 `ConversationWelcome`
  （参考 118 的版式：最上面 Botin 创建时间、左边一个说明气泡——App 的话不是 Botin 说的，不带 AI 标识——下面同宽的卡片：没配
  main 时“开始之前”+ 去配模型路由，配好了“想让 X 先帮你做什么？”+ A–D 四个示例任务，点了放进输入框、聚焦，右上 × 收起；卡片
  下面“也可以在下面直接写”）；这就是 6.18 A，示例任务先按引擎无关的通用任务写（`ConversationText.starterSuggestions`）。
  找不到这个 Botin 用 `ContentUnavailableView`。工具调用、审批、保险箱、产出物、子运行、计划卡片照旧全宽，去掉描边、底色和
  气泡同一个灰（`cardSurface()`、`Card(bordered: false)`），按钮换成系统的玻璃按钮（`smallCapsuleButton()`；审批的选项是全宽的
  大胶囊，第一个批准类的突出）。举报 sheet 换成 `Form`（原因 `Picker(.inline)`，左上关闭、右上“提交”），密码拦截 sheet 的按钮
  换成系统的、底部“仍然发送”是浮动的全宽玻璃胶囊。`Metrics.Radius.input` 删了。
- **还原度评审修正（2026-11-05，截图 02 浅深对参考 02、118）**
  - 标题胶囊：上面“已做”说的“iOS 26 由工具栏画成玻璃胶囊”不对——iOS 26 不给 `.principal` 项套共用的玻璃底，截图里只有光秃秃的头像和名字。
    现在 `ConversationTitle` 自己画 44pt 高的玻璃胶囊（`glassBackground(in: Capsule(), interactive: true)`，和返回、“…”两个玻璃圆一样高；
    iOS 17 / 18 是材质），头像离胶囊左边 10pt、和上下一样（同心），名字后面 12pt（参考 118 量出来约 10、13）；名字改成和
    `capsuleNavigationTitle` 一样的 medium `.body`（参考比系统标题的 semibold 轻一档）。`inlineNavigationTitle(_:ownsGlass:principal:)`
    多了 `ownsGlass`，为 true 时这一项 `hidesSharedGlassBackground()`（Glass.swift 的帮手多了个 `Bool` 参数），免得哪个系统版本再套一层。
    实例列表里还没有这个 Botin 时只有一行标题字，不画胶囊。
  - 对话里的审批卡片：“在审批中心查看”的 44pt 点按区域照旧，但不再占版面（上 −8、下 −12 的负内边距，往上伸到和上一项的间距为止、
    往下伸进卡片的内边距），字下面从约 30pt 变成和卡片顶上差不多的约 17pt。
  - 运行状态行：同一组里有待处理的审批卡片时（`ConversationTurn.pendingApprovalItemID`）不再放“去审批”——它只会滚到眼前这张卡片，卡片自己
    有选项和“在审批中心查看”（`RunStatusPresentation(approvalCardShown:)`，测试在 `ConversationTextTests`）。状态点、“等你审批”、ⓘ 照旧；
    卡片还没出现时（事件没到）“去审批”照旧去审批中心。运行详情页的状态行在卡片上面，照旧带“去审批”。
  - 审批选项按钮的字换成 `ApprovalOptionLabel`（勾 / 叉 + 名字，自己排，不用 `Label`），和审批详情页共用（见 7.3 收尾那条的评审修正）。
  - 留着不改的（评审确认是 ThinkTin 的东西）：全宽的工具调用、审批卡片，“AI 生成”标识，状态行，模型标签胶囊，输入框没有麦克风和语音、
    右边是橙色的发送 / 停止，“+”，自己的首字头像和占位字，“…”和“+”的橙色，气泡的几何。
- **ThinkTin 改版前**：`.conversation(id)` → `Screens/Conversation/ConversationScreen.swift`（`ConversationContent`）、
  `ConversationTimeline.swift`、`MessageViews.swift`（`UserMessageView` 右侧卡片，`AssistantTextView` 不带气泡）、
  `ConversationCards.swift`（`SourceHeaderView`）、`ConversationComposer.swift` + `Components/ComposerBar.swift`；
  `ViewModels/Conversation/ConversationModel.swift`。标题现在是 `Shell/InstanceSwitcher.swift`。
- **要改**
  - `ComposerBar` 重写成玻璃胶囊（它只有对话页用，第 1 轮归对话这条线）。
  - 时间分隔按 `Run.createdAt` 在客户端算（隔 15 分钟以上或跨天才加），逻辑放 `ViewModels/Conversation/`，Linux 上测。
  - 气泡和左右对齐按 6.2 的决定。参考的语音模式按钮、通话记录不做（6.23）。
  - 第 1 轮。

#### 4.3.2 对话“…”菜单（3）

- **布局**：点“…”从按钮位置变形展开玻璃菜单，盖住标题，背景不变暗；每项左图标右文字。
- **原生**：`Menu { Section { … } Section { … } } label: { Image(systemName: "ellipsis") }`；分享类用 `ShareLink`。
- **ThinkTin 的菜单项**：第一组 实例资料（`person.crop.circle`）、在对话中查找（`magnifyingglass`，第 2 轮）；
  第二组 模型路由（`cpu`）、新建计划（`calendar.badge.plus`）、产出物（`folder`）。参考的“分享为模板”不做（6.21）。
- **已做（第 1 轮 B 线，2026-11-05）**：`ConversationMoreMenu`，iOS 放 `.topBarTrailing`（macOS `.primaryAction`），图标
  `ellipsis`；分组在 ThinktinKit 的 `ConversationMenu`（Linux 上测顺序）：第一组 Botin 资料（`person.crop.circle`）；第二组 计划
  （`calendar`，这个 Botin 的计划）、新建计划（`calendar.badge.plus`）、产出物（`folder`）、模型路由（`cpu`）；有任务在跑时最后一组
  “停止当前任务”（`stop.circle`，destructive，`model.stop()`）。参考的三项里“在聊天中查找”是第 2 轮（做了放第一组），“分享为模板”不做。
- **ThinkTin 改版前**：`ConversationScreen.swift` 的 `ToolbarItem(placement: .primaryAction)` 里的 `Menu`（实例详情、模型路由、
  新建计划、产出物），图标 `ellipsis.circle`。
- **要改**：分组、换图标、放 `.topBarTrailing`。第 1 轮。
- **审查意见（2026-11-05）**：缺“在对话中查找”、分组和参考 03 不一样。这一项在 `r2/conversation` 分支做了（`cd773e3`：第一组
  Botin 资料、在对话中查找，ThinkTin 自己的项放第二组），已经合进本分支（见 4.3.3 的“已做”）。

#### 4.3.3 对话内查找（4、5）

- **布局**：底部输入框换成一条查找栏：玻璃胶囊搜索框（约占屏宽 45%，占位“在对话中查找”）、两个玻璃圆（上一个、下一个）、
  “完成”玻璃胶囊。搜索框尾部显示“第 i 个，共 n 个”，0 个时红字。
- **原生**：`TextField` + `.glassEffect(in: .capsule)`（系统 `.searchable` 放不下计数）；箭头
  `.buttonStyle(.glass).buttonBorderShape(.circle)` + `.disabled(n == 0)`；完成 `Button("完成", role: .close)`；定位用
  `ScrollViewReader` 的 `scrollTo(id, anchor: .center)`；命中文字用 `AttributedString` 加背景高亮；回车跳下一个（`.onSubmit`）；
  计数变化发 `AccessibilityNotification.Announcement`。系统的 `.findNavigator` 只支持文本视图，消息列表用不上。
- **交互**：从“…”进来，搜索框自动聚焦；输入后高亮所有匹配并跳到最新一处；上下箭头跳；点“完成”退出、恢复输入框。
- **状态**：没输入（箭头灰）、有匹配（灰字计数）、没匹配（红字 0）、“已加载的记录里没有，加载更早的再找”。
- **ThinkTin 现在**：没有。
- **要改**：纯客户端。在 `ConversationModel` 已加载的记录（任务、回复文字）里搜，再往上用 `cachedEventsBefore`
  （每个实例本机最多 2000 条）和 `olderRuns`；超出缓存的搜不到，要提示。查找状态放 `ViewModels/Conversation/ConversationFind.swift`，
  查找栏 `Screens/Conversation/ConversationFindBar.swift`。查找时模型标签、错误横幅先藏起来。第 2 轮。
- **已做（第 2 轮 r2/conversation，2026-11-05）**：照参考 04、05。“…”菜单第一组 Botin 资料后面加“在对话中查找”（`magnifyingglass`，
  `ConversationMenuItem.find`；只看本次过程、找不到 Botin 时没有）。点了输入框换成 `ConversationFindBar`：玻璃胶囊的查找框（放大镜、
  占位“在对话中查找”、尾部“第 i 个，共 n 个”，没找到红字“第 0 个，共 0 个”）、上 / 下两个玻璃圆（没找到时灰）、“完成”玻璃胶囊；
  查找框自动聚焦，回车和上箭头一样往前找，上下到头绕回，计数变了发读屏播报。找的是已读进来的用户消息、agent 回复、没有过程记录的
  运行的结果（思考、工具调用、卡片不找），不分大小写、变音符号、全角半角；改字后跳到最新一处，新事件、往上翻时当前这一处不跳。
  上面还能翻时查找栏上方多一个小胶囊“已加载的记录里没有，加载更早的再找”（参考没有）。高亮：所有匹配浅强调色底，当前这一处实心
  强调色底白字；位置按画出来的字算（`InlineText.plainText`，即 `AttributedString(markdown:)` 的结果），每个 `Text` 是一段
  （`MarkdownBlock.findSegments`），视图模型数的和界面画的一一对上；折起来的长消息、三行的引用块里有当前这一处时自动展开。
  逻辑在 ThinktinKit 的 `ConversationFind.swift`（`ConversationModel.find`、`beginFind` / `setFindQuery` / `findPrevious` /
  `findNext` / `endFind`，`render()` 时重新找）和 `MarkdownInline.swift`（Linux 上测试用的近似去标记）。

- **还原度评审修正（2026-11-05，截图 28 对参考 04）**：查找栏四个控件一样高。上 / 下原来是系统的 `.glass` 圆按钮 + `.controlSize(.large)`，
  有约 53pt，“完成”约 49pt，查找框（44pt）被挤到约屏宽 28%，占位只剩“在对…”。现在箭头是自己画的 44pt 玻璃圆（`glassBackground(in: Circle(),
  interactive: true)`，能跳时强调色、不能跳时三级灰），“完成”是 44pt 高的玻璃胶囊（字两边 16pt，强调色），控件之间 8pt，两个圆的
  `GlassGroup` 融合距离也给 8（同 `FilterChipBar`，挨着取样、不连成一块）。参考 04 量出来：都约 45pt 高、间距约 10.7pt、圆约 45pt、
  “完成”约 64pt、查找框约 155pt；我们的查找框约 160pt。

#### 4.3.4 消息长按（6、90）

- **参考**：长按 agent 气泡后背景变暗，底部升起带拖动条的玻璃面板：上面两排表情（最后一个“笑脸 +”进完整表情选择器，90），
  下面两组：回复、标为未读；复制、选择文本、复制请求 ID。
- **ThinkTin（建议）**：先用系统长按菜单（带预览），不做表情面板（6.11）。
  - agent 回复：第一组 回复（引用，第 2 轮）、复制、选择文本、分享；第二组 复制运行 ID；最后一组 举报（destructive）。
  - 用户消息：复制、再发一次、选择文本。
- **原生**：`.contextMenu { Section { … } … }`；选择文本弹 sheet，里面放只读的 `UITextView`（`isEditable = false`、`isSelectable = true`，
  `UIViewRepresentable` 包一层）——iOS 上 `Text(...).textSelection(.enabled)` 只能整段复制，不能划选一部分；复制用现有的
  `Pasteboard.copy`（agent 输出带 AI 生成标识）；复制 ID 加 `.sensoryFeedback(.success, trigger:)`。
- **已做（第 1 轮 B 线，2026-11-05）**：系统长按菜单（`MessageMenus.swift` 的 `messageMenu(_:previewShape:)`，iOS 上预览是
  气泡的外形），分组在 ThinktinKit 的 `MessageMenuLayout`：agent 写的 引用回复；复制、选择文本、复制运行 ID；分享；举报
  （destructive）。用户消息 引用回复；复制、选择文本、复制运行 ID；再发一次。“只看本次过程”里没有引用回复。选择文本弹
  中号起的 sheet，iOS 里是只读的 `UITextView`（`UIViewRepresentable`，能划选一部分），macOS 是 `Text.textSelection`；agent 写的
  下面带 AI 标识。复制运行 ID 有成功的触感（`.sensoryFeedback(.success)`）。删除不做（没有删运行的接口），表情、标为未读不做（6.11）。
- **ThinkTin 改版前**：`MessageViews.swift` 的 `MessageMenu`（复制、分享、举报）、`UserMessageView`（复制、再发一次）、
  `ContentReportSheet.swift`。
- **要改**：加“选择文本”“复制运行 ID”，分组。表情、标为未读要后端（6.11）；真要做表情时长按改成
  `.sheet` + `.presentationDetents([.medium, .large])` + `.presentationDragIndicator(.visible)`。第 1 轮。
- **审查意见（2026-11-05）**：长按要照参考 06 换成底部玻璃面板（拖动条 + 两组 + 表情一排）。`r2/conversation` 分支做了
  （`b6393fd`：长按弹面板，表情一排、更多表情的选择器），已经合进本分支（见下一条）。
- **已做（第 2 轮 r2/conversation，2026-11-05，用户要求照参考把没有的功能也做出来）**：表情回应照参考 06、90 做了，**只存这台设备**
  （ThinktinKit `MessageReactions.swift` 的 `MessageReactionStore`，`UserDefaults` 一个键，按“Botin id / 消息 id”记，最多 2000 条消息、
  每条 12 个；不上传、不告诉 Botin；6.11 B 要后端存）。iPhone 上长按消息不再是系统菜单，改成上面说的 sheet（`MessageActionSheet`，
  中号起、拖动条）：上面两排圆形的系统玻璃按钮（👍 👎 ❤️ 😂 🎉 😮 / 🔥 👀 🙏 😢 💯 + “更多表情” `face.smiling`，点过的是突出样式），
  下面是 `List` 的分组（agent 写的第一组 引用回复、标为未读——参考 06 的“回复、标为未读”）。点“更多表情”面板拉到全高、原地换成参考 90
  的选择器（`EmojiPickerView`：左上返回圆、“搜索表情”胶囊，8 列，按 Unicode 的八类分组、小灰字分类名；搜中文关键词、Unicode
  英文名、分类名，没结果是 `ContentUnavailableView.search`）。点表情加上或去掉、关面板；点操作先关面板再做（引用回复、选择文本、
  再发一次、举报都要弹别的东西），分享是 `ShareLink`。“标为未读”没有（6.10），点了弹“即将推出”。回应画在气泡下面（`ReactionChips`，
  小玻璃胶囊，点了去掉；用户消息靠右）：用户消息、agent 回复、没有过程记录的运行结果有，思考和待办没有。Mac 还是右键菜单，多一组
  “回应”子菜单（常用 11 个 + “更多表情…”弹选择器）。读屏多一个“回应”操作（打开面板）。长按有触感。

#### 4.3.5 引用回复（7）

- **布局**：输入框从胶囊长成大圆角卡片（约 28）：上面引用条（灰胶囊，单行截断，右边 ×），中间输入，下面一行按钮。
- **原生**：`VStack { … }.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))`；引用条
  `.background(.fill.tertiary, in: Capsule())`；`@FocusState` 自动聚焦；胶囊和卡片的切换用系统的 `withAnimation`。
- **ThinkTin 现在**：没有；`sendMessage(instanceID:text:allowSecrets:)` 只收纯文本。
- **要改**：按 6.11 的方案 A，发送时把引用拼成 Markdown 引用块（`> …`）放在正文前，算进 32000 字、照样过密码检测。第 2 轮。
- **已做（提前到第 1 轮 B 线，2026-11-05）**：`ConversationModel.quotedText` / `setQuote` / `clearQuote` / `outgoingText`，
  拼法在 `MessageQuote`（每行加 `> `、空行只留 `>`，空一行接正文；引用超过 1000 个字符截断加“…”；正文空时不带引用、不能发）；
  字数和超限按 `outgoingText` 算；发出去以后引用和输入框一起清，发送失败都留着；密码拦截拦下的是整段，存进保险箱后整段放回
  输入框、不再单独带引用。输入框长成圆角 28 的卡片：顶上一条浅灰胶囊（一行截断、右边 ×“取消引用”），中间输入，下面一行右边
  是主按钮；选了引用自动聚焦。时间线里用户消息开头的引用块拆出来画（`MessageQuote.split`）。
- **审查修正（2026-11-05）**：发出去的是“> 引用 + 空行 + 正文”，别处只显示正文（`MessageQuote.body`）：运行树的标题、
  进行中的行、首页预览和长按卡、搜索“你发给 X”的匹配和摘要；运行详情的任务和气泡一样拆成引用块 + 正文；用户气泡的读屏先念
  正文再念“引用：……”（`MessageQuote.spoken`），不念“>”。

#### 4.3.6 附件菜单（8）

- **参考**：“+”向上展开玻璃菜单：照片或视频、拍照、选择文件；选好后输入框长成卡片，顶上一排缩略图。
- **原生**：`Menu` + `.photosPicker`、`UIImagePickerController`（`sourceType = .camera`，`UIViewControllerRepresentable` 包一层；
  SwiftUI 没有相机控件）、`.fileImporter`。
- **ThinkTin 现在**：12.22 运行附件，等 1.1 拍板和后端 5.6，`ClientProtocol` 没有上传接口。
- **要改**：第 3 轮（6.13）。在那之前输入框不放“+”。
- **已做（第 2 轮 r2/conversation，2026-11-05，用户要求“没有的功能也照参考把页面做出来”，推翻上一条的“不放‘+’”）**：
  输入框左边一个玻璃圆“+”（`ComposerBar` 的 `attachments` / `onAttach`，有引用的卡片里在下面一行的左边，参考 07），系统 `Menu`
  三项照参考 08：照片或视频（`photo.on.rectangle`）、拍照（`camera`，Mac 没有）、选择文件（`folder`）（ThinktinKit 的
  `ComposerAttachmentSource`）。上传要服务端（12.22、后端 5.6），现在点哪一项都弹系统提示“即将推出”（说明等服务端能收附件以后就能用，
  先把内容贴进输入框），不打开选择器。接口有了以后换成 `.photosPicker`、`UIImagePickerController`、`.fileImporter`，
  选好的放在输入框上面一排缩略图。只看本次过程、找不到 Botin 时没有“+”。

### 4.4 实例管理（参考的“Bot 管理”）

#### 4.4.1 实例资料（9）

- **布局**
  - 没有标题；右上两个分开的玻璃圆：分享、“…”（分享先不放，6.21）。
  - 头部居中：120pt 头像（右下状态角标）、名字（`.title2.bold()`）、小号玻璃胶囊“编辑”。
  - 第一组：计划（`clock`，值“N 个生效”）、产出物（`folder`）、工作区（`desktopcomputer`，值是实例状态，如“休眠”）。
  - 第二组：默认模型（值是 main 路由的上游模型，没配时橙色“未配置”），点进模型路由。
  - 第三组：所在团队（每个团队一行）。
  - 最后：信息（agent、接入方式、创建时间）。
  - 参考的“通知”开关：按 Botin 开关要后端（6.14）；2026-11-05 照 1:1 的要求先放了一个跟着系统通知权限、不能拨的开关（见下面的截图审查）。
- **原生**：`List(.insetGrouped)`；头部是第一个 Section，`.listRowBackground(Color.clear)`；编辑
  `Button("编辑").buttonStyle(.glass).controlSize(.small)` + `.navigationDestination(isPresented:)`；带值的行
  `NavigationLink { … } label: { LabeledContent { Text(值) } label: { Label(标题, systemImage:) } }`；右上
  `ToolbarItem(placement: .topBarTrailing) { Menu }`。
- **交互**：从对话标题进来（压栈）；计划 → 4.5.1；产出物 → 4.5.2；工作区 → 4.6.1；默认模型 → `.modelRoutes(id)`；
  编辑 → 4.4.3；“…” → 4.4.2；团队行 → `.team(id)`。
- **状态**：加载中、离线（只读，改动类禁用）、找不到实例、拉取失败可重试、没配 main 路由的提醒（模型那一组的行内警告）。
- **ThinkTin 现在**：`.instance(id)` → `Screens/Agents/InstanceDetailScreen.swift`（`InstanceHeader`、`modelSection`、
  `versionSection`、`workSection`、`teamSection`、`infoSection`，全用 `GroupedSection`）+ `ViewModels/Agents/InstanceDetailModel.swift`
  （`plans`、`teams`、`routeStatus`、`versionOptions`）。
- **要改**：重写成上面的版式。“N 个生效”是 `InstanceDetailModel.plans` 里没暂停、已确认的数；版本升级 / 回滚挪进工作区页；
  改名挪进编辑页；删除挪进“…”菜单。第 1 轮。
- **已做（2026-11-05，第 1 轮 C 线，对过参考 09）**：`List` + insetGrouped（macOS 用 `.inset`，`insetGroupedList()`），导航栏中间空着；
  头部头像量出来是 80pt 左右（不是上面写的 120，`ProfileAvatarMetrics`，最大跟到 xxxLarge 的动态字体），名字 `.title2.bold()`，“编辑”是
  普通大小的玻璃胶囊（参考约 54 × 38pt）；第一组 计划（`clock`，“N 个生效 · M 个待确认”，`InstanceDetailModel.activePlanCount`）、
  产出物（`folder`）、工作区（`desktopcomputer`，值是状态名）；默认模型（`cpu`，`InstanceRouteStatus.defaultModelValue`，没配警告色
  “未配置”，脚注写原因）；所在团队；信息（引擎 · 版本、接入方式、创建于、最近活动）。右上两个分开的玻璃圆：参考是分享和“…”，
  ThinkTin 第一个放“打开对话”（`bubble.left`，从对话进来时是退回去），中间 `GlassToolbarSpacer(.fixed)`。“打开对话”胶囊、
  资料页上的计划列表、“新建计划”行、底部的删除按钮去掉了（计划进计划页，新建计划在“…”和计划页的“+”，删除在“…”）。
  找不到、拉不到是 `ContentUnavailableView`。
- **审查修正（2026-11-05）**：右上只留“…”（规范上面写的）：去掉了“打开对话”（`bubble.left`）。参考那个位置是分享，ThinkTin
  不做（6.21）；从对话标题进来时它和返回是一回事，别的入口（首页长按、计划详情、团队成员、引擎详情）回首页点那一行进对话。
- **截图审查（2026-11-05，对过参考 09）**：
  - 导航栏中间以前照样画出了名字（`{ EmptyView() }` 不管用，见 2.6），换成 `hiddenInlineNavigationTitle`。
  - 照参考加了第二组“通知”（工作组下面）：开关显示系统的通知权限能不能送到（`NotificationPermission.canDeliver`，从系统设置
    回来重读），**不能拨**；脚注是自己的话“做完任务、需要你处理时发通知。现在跟着系统的通知设置，按 Botin 单独开关即将推出。”
    按 Botin 开关要后端（6.14 A）；只在本机记一个开关做不到静音（6.14 B 不推荐），所以不做成能拨的假开关。
  - 行首图标换成细的中性灰小图标（`RowLabel`，以前是强调色、和正文一样大）；“工作区”的图标 `desktopcomputer`（实心一体机）
    换成空心的 `display`。“…”和“编辑”是中性色（2.2）。
  - 收紧上下：`compactGroupedList()`；头部上面 8pt、下面 16pt（以前上下各 12，这一行贴边，“编辑”的玻璃阴影被行的下边切掉一截）。
  - “所在团队”“信息”的分组标题换成 13pt 的浅灰（`groupHeader()`，2.5）。
  - 右上的分享照旧不放（审查问过 1:1 要不要放）：ThinkTin 没有能分享给别人的 Botin 页面或模板，深链 `thinktin://instance/{id}`
    只有自己能打开（6.21 C），放一个分享只能分享一段没用的字。等 6.21 A / B 有了再加（`ShareLink` + `GlassToolbarSpacer(.fixed)`）。

#### 4.4.2 资料页“…”菜单（10）

- **参考**：替换主 Bot…、复制 ID。
- **ThinkTin 的菜单项**：复制实例 ID（`doc.on.doc`）、模型路由（`cpu`）；最后一组 删除实例（`trash`，destructive，接现有的
  `InstanceDeleteSheet`，带影响说明）。“替换主 Bot”不做（6.10）。
- **原生**：`Menu` + `Section` + `role: .destructive`；复制后 `.sensoryFeedback(.success, trigger:)`。
- **ThinkTin 现在**：`InstanceDetailScreen` 的 `Menu`（改名、删除实例，图标 `ellipsis.circle`）。
- **要改**：第 1 轮。
- **已做（2026-11-05）**：分组在 ThinktinKit 的 `InstanceProfileMenu`（测试 `InstanceProfileTests`）：复制 Botin ID（`doc.on.doc`，
  成功触感）；模型路由（`cpu`）、新建计划（`calendar.badge.plus`）；删除这个 Botin（`trash`，destructive，接 `InstanceDeleteSheet`）。
  离线时新建计划、删除灰掉（`needsConnection`）。删除确认页也换成了 insetGrouped 的 `List`（影响清单一组一组）、左上 `CloseButton`、
  底部浮动的红色整宽胶囊“删除这个 Botin”，二次确认照旧。
- **审查意见（2026-11-05）**：复制 ID 应该在最后（参考 10）。`r2/conversation` 分支已经把第一组改成“替换主 Botin、复制 Botin ID”
  （`ff8b335`，和参考 10 那一组一样），已经合进本分支。


#### 4.4.3 编辑实例（12；13–17、85–88 是它的语音菜单）

- **布局**：压栈页，标题“编辑实例”，右上“完成”。头像约 100pt 居中，右下玻璃小铅笔（第 2 轮才有，见 4.4.4）；
  “名称”组一个单行输入；“外观”组“头像 >”（第 2 轮）；参考的“语音通话”组（语音、速度、语言）不做（6.23）。
- **原生**：`Form { Section("名称") { TextField } footer: { 名字规则或错误 } }`；`ToolbarItem(placement: .confirmationAction) { Button("完成") }`，
  名字不合法时 `.disabled`，保存中换 `ProgressView`。压栈页要拦返回只能藏掉系统返回键自己画（`.navigationBarBackButtonHidden(true)`），
  和 2.6“不自定义返回项”冲突，参考也不拦，所以不拦。
  参考在“语音”“语言”行用的 `Picker(.menu)`（长列表系统菜单自己能滚、选中项打勾）是好写法，单选项都照它做。
- **交互**：点“完成”保存并返回；点返回直接放弃改动（只有一个名字字段，丢了好重填）。
- **状态**：名字为空或太长（`InstanceNameRule`）、保存中、保存失败（`ErrorBanner`）、离线整页禁用。
- **ThinkTin 现在**：`InstanceDetailScreen.swift` 里的 `InstanceRenameSheet`（sheet，取消 / 保存，`AgentsNameField`）+
  `InstanceDetailModel.rename(to:)`。
- **要改**：sheet 改成压栈的 `Form`（Agents 目录里本地 `NavigationLink`，不加路由）；第 1 轮只有名字。
- **已做（2026-11-05，对过参考 12）**：`InstanceEditScreen.swift`，资料页“编辑”用 `navigationDestination(isPresented:)` 压进来；
  标题“编辑 Botin”，右上 `ConfirmButton`（“完成”，保存中转圈，名字不对灰掉）；头像 80pt 居中、右下玻璃小铅笔；“名称”组输入框，
  脚注是名字规则 / 问题 / 离线不能改名；保存失败是一条 `ErrorBanner`；“外观”组“头像”行（右边小头像 + 箭头）。点头像、铅笔、“头像”行
  都进头像页。离线时名字不能改、“完成”只是返回。旧的 `InstanceRenameSheet`、`AgentsNameField` 删了。
- **审查修正（2026-11-05）**：“外观”组的“头像”行只有标题和 chevron（参考 12），去掉了行尾的小头像（大头像在页面最上面）。
- **已做（2026-11-05，第 2 轮 r2/botin，对过参考 12、13–17、85–88）**：用户要先照参考把没有后端的页面也排出来（以后再删减），
  编辑页最下面加了“语音通话”组：语音、速度、语言三行系统的 `Picker(.menu)`（行尾是值和上下箭头，菜单里选中的打勾，长菜单系统
  自己能滚）。音色第一项“未设置”，后面是 28 个自己起的名字（植物、矿物、自然景物，`BotinVoiceDemoData.voices`，不用参考的名字）；
  速度 0.5x、0.75x、1x、1.25x、1.5x、2x；语言第一项“自动”，后面中文（简体、繁体）、粤语、英语，其余按英文名排（30 种）。
  选了只记在这台设备上（ThinktinKit `ViewModels/Agents/BotinVoice.swift`：`BotinVoiceStore`，`UserDefaults` 一个键、按 Botin 的 id，
  默认的不存，认不出的值当没选；`BotinVoiceEditor` 是草稿，点“完成”才记，点返回放弃），脚注“语音通话即将推出。这里的选择先只保存在
  这台设备上。”删 Botin（资料页“…”里删、首页长按删）、注销账号时一起删记录（2026-11-05 合并后统一走 ThinktinKit 的
  `BotinLocalData`，见 4.9.2 的“本机记录”）。
  1.4 和 6.23 原来定的是不做语音，这一组以后要不要留由用户定。
- **截图审查（2026-11-05，对过参考 12）**：名字下面平时不写脚注了（以前总有“最多 64 个字。”）：只在离线、名字有问题（删空了、
  太长）、快到上限时写，和新建表单同一条规则（`AdoptionModel.nameNote(for:hidesUntouchedEmpty:language:)`，编辑页删空了也说）；
  语音、速度、语言三行的值和上下箭头是灰的（`menuPickerTint()`）；“名称”“外观”“语音通话”的分组标题 13pt 浅灰；头像下面留 16pt
  （铅笔的玻璃阴影以前被行的下边切掉）；上下收紧（`compactGroupedList()`）。

#### 4.4.4 头像（18、19、20）

- **参考**：压栈页“头像”，右上“完成”；顶上分段“形状 / 生成 / 上传”；大预览；形状网格（14 个）+ 色板（11 个，选中带环）+
  “重置为默认”；“生成”是多行描述 + 生成按钮；“上传”是从相册选、拍照两行 + 脚注（最大 25 MB，之后可以裁剪）。
- **原生**：`Picker(.segmented)`；`LazyVGrid` 里 `Button(.plain)` + 选中环 + `.accessibilityAddTraits(.isSelected)` +
  `.sensoryFeedback(.selection, trigger:)`；`PhotosPicker`（不用相册权限）；相机 `UIImagePickerController`（`sourceType = .camera`、
  `allowsEditing = true`，要 `NSCameraUsageDescription`）。
- **ThinkTin 现在**（2026-11-05）：`Components/InstanceAvatar.swift`：形状里放名字的第一个字（不小于 9pt），右下角可选状态角标（圆心落在
  形状右下方的轮廓上，右下角空着的形状往里挪）；形状和颜色
  （`InstanceAppearance`：`AvatarShape` 15 种、`AvatarColor` 12 种，ThinktinKit `ViewModels/Shell/InstanceAppearanceStore.swift`）
  **在新建表单里挑**（4.7.1：形状网格 3 × 5 + 色板 2 × 6，选中带环），先只存在这台设备上（6.9 A，`InstanceAppearanceStore`，按实例 id）；
  没挑过的是圆形、按名字取色（和第 0 轮的首字头像一样）。形状自己设计（`Components/AvatarShapes.swift`，几何、有机形状，只放首字，
  **不画脸和眼睛**，不照搬参考的形象）。`Instance` 还没有头像字段，也没有上传、生成接口。
- **要改**：建好之后改头像（编辑页“外观”组的“头像 >”，压栈页：大预览 + 同一套形状网格和色板 +“重置为默认”，右上“完成”）第 2 轮，
  复用新建表单的 `AvatarPicker`（挪成共用组件）；后端加了头像字段（6.9 B）后新建时一起提交、从实例上读，本机的存储当缓存或删掉；
  生成、上传不做。
- **已做（2026-11-05，对过参考 18）**：编辑页 →“头像”（`InstanceAvatarScreen`）：标题“头像”、右上“完成”记进
  `InstanceAppearanceStore`（`InstanceAppearanceEditor`，默认的删掉记录）；80pt 大预览；和新建表单同一张卡片（`AvatarPicker` 挪成
  `Screens/Agents/AvatarPicker.swift`，两处共用），卡片最下面分隔线 +“重置为默认”（已经是默认时灰掉）；下面一句“只保存在这台设备上”。
  参考顶上的“形状 / 生成 / 上传”分段只有形状能做，不放分段。点返回放弃改动。
- **审查修正（2026-11-05）**：形状和色板之间不画分隔线（参考 18 只有“重置为默认”上面那一条）；选中的形状外面是一圈贴着它的
  中性灰细环（`Theme.inkSecondary`，2pt），不再是强调色的圆角框。新建表单用的是同一个 `AvatarPicker`。
- **已做（2026-11-05，第 2 轮 r2/botin，对过参考 18、19、20）**：照参考加回顶上的分段（系统 `Picker(.segmented)`，`.fixedSize()`
  居中，“形状 / 生成 / 上传”，`AvatarSourceTab`），页面换成 insetGrouped 的 `List`，分段和 80pt 大预览是第一组（透明底）。
  形状：原来的卡片（形状网格、色板、“重置为默认”）和“只保存在这台设备上”的脚注。生成（19）：多行输入（`TextField(axis: .vertical)`，
  4–8 行，占位字“描述想要的头像，比如……”，最多 300 字，超了脚注标红）+ 整宽玻璃胶囊“生成”（没写描述灰掉），脚注说即将推出，点了弹
  系统提示“即将推出”。上传（20）：“从相册选择”（`photo`）、“拍照”（`camera`）两行带箭头，脚注“图片不超过 25 MB，选好之后可以裁剪。
  上传头像即将推出。”，点了弹“即将推出”。上传没用 `PhotosPicker` 存本机：存下的照片要画在首页、搜索、对话标题这些地方，得改
  `InstanceAvatar` 和 `ViewModels/Shell` 的外观存储（别的线的），这次不做。文案在 ThinktinKit `ViewModels/Agents/AvatarSources.swift`。
- **截图审查（2026-11-05，对过参考 18）**：分段离导航栏太远、离大预览太近：列表收紧（`compactGroupedList()`），分段和预览之间
  改成 40pt（以前 20），去掉第一组上面多加的 12pt；“重置为默认”上面的分隔线从字的起点画到卡片右边（以前两头都缩进）。
  `AvatarPicker` 加了 `showsCard`：这一页照旧画卡片（参考 18），新建表单不画（4.7.1）。

#### 4.4.5 选择主 Bot（11）

不做（ThinkTin 没有主实例，6.10）。它的 sheet 选择器版式（左上 ×、右上 `.confirmationAction`“确认”、`List(selection:)` 单选、
底部 `.searchable`、空时 `ContentUnavailableView`、没结果 `ContentUnavailableView.search(text:)`）用来改两处现有的选择：
`Shell/ShellDestination.swift` 的 `NewTaskSheet`（选在哪个实例上下任务）和团队编辑里的成员选择（`Screens/Teams/TeamsScreens.swift`）。

已做（2026-11-05，收尾线）：两处都换成了这个版式。`NewTaskSheet`：左上 `CloseButton`、右上 `ConfirmButton("确认")`（选中的 Botin 还在才能点）、
一行一个 Botin（40pt 头像带状态角标、名字、状态，选中的右边系统勾，默认选当前的），`.searchable`，最后一组“新建 Botin”，没有 Botin、没搜到用
`ContentUnavailableView`。单选没用 `List(selection:)`：iOS 上它不进编辑模式时选中是整行灰底，和参考的勾不一样，改成按钮行 + 系统勾。团队编辑：
同样的关闭 / 保存，名字一组，成员是多选（同样的勾），负责人另起一组 `Picker(.menu)`（只列选中的成员），`.searchable` 筛成员。

- **已做（第 2 轮 r2/conversation，2026-11-05，用户要求“没有的功能也照参考把页面做出来”，推翻上面的“不做”）**：主 Botin 只记在
  这台设备上（ThinktinKit `PrimaryBotin.swift` 的 `PrimaryBotinStore`，6.10 说的“本机存就行”的默认 Botin）。新路由
  `AppRoute.primaryBotin`（sheet，归 `.conversation`，离线也能用，标题“选择主 Botin”），页面 `PrimaryBotinPickerScreen`
  照参考 11：左上 ×、右上“确认”（`.confirmationAction`，没选或选的就是现在的主 Botin 时灰）、分组列表里系统单选
  `Picker(.inline)`（头像 + 名字 + 状态）、`.searchable`“搜索 Botin”；不列现在的主 Botin 和删掉的，一个都没有时是参考 11 的
  “暂无其他可选的 Botin”（`ContentUnavailableView`），搜不到是 `ContentUnavailableView.search`；脚注说明主 Botin 是干什么的、
  只在这台设备上。入口照参考 10：Botin 资料“…”菜单第一组“替换主 Botin…”（`arrow.left.arrow.right`）、复制 ID。删了 Botin
  时是主 Botin 的话清掉。
- **已接（2026-11-05，四条 r2 线合进来以后补的跨线小事）**：主 Botin 从 `AppModel.local.primary` 读（App 里就是
  `PrimaryBotinStore.shared`）。新任务的选择（`NewTaskSheet`）默认选主 Botin（没有、删掉了才选当前的 Botin，
  `PrimaryBotinStore.defaultSelection`），主 Botin 排第一行、头像是星标、状态前面写“主 Botin ·”；快捷指令“给 Botin 下任务”的
  Botin 参数默认是主 Botin（`InstanceEntityQuery.defaultResult()`），建议列表里排最前（`primaryFirst`）。头像的星标是
  `InstanceAvatar.Badge.primary`（强调色圆里一颗白星，比状态点大，最小 14pt，读屏念“主 Botin”）：Botin 资料的头像上换掉状态角标
  （参考 10；状态在“工作区”那行照样看得到）；首页的行和置顶的大头像只在没有状态角标时画（参考 01；在等你处理、进行中、暂停这些
  比“主”要紧，**有状态时先画状态，要不要两个都画请用户看一眼**）。小组件只有几个数、不选 Botin，用不到主 Botin。
- **截图审查（2026-11-05，对过参考 11）**：两处照参考 11 的选择器的行以前长得不一样（一处名字 `.headline` 没有状态角标，一处
  `.body` 带角标），现在共用 `Components/BotinPickerRow.swift`：40pt 头像带状态角标（主 Botin 是星标）、`.headline` 名字、
  `.subheadline` 灰字。新任务的选择改成只有 large 一档（参考 11 是 large、没有拖动条），列表上面的“交给哪个 Botin？”分组标题
  去掉，改成脚注“选一个 Botin 接这个任务。”。左上 × 是中性色（2.2）。空状态的字换成自己的话“没有别的 Botin 可选”（以前是
  参考的原句换了个词）；截图加了 `52-primary-botin-empty`（新账号，`THINKTIN_MOCK_EMPTY=1`），看空状态的版式。

### 4.5 任务与资料

#### 4.5.1 实例的计划（21）

- **布局**：压栈页，标题“计划”（参考叫“定时任务”）；没有计划时屏幕正中一段两行的灰字（参考只有这一段，没有图标、标题、按钮）；
  有计划时 insetGrouped 列表。参考右上没有按钮（只能在对话里让 Bot 建）；ThinkTin 能手动新建，所以加右上玻璃“+”，空状态也多一个按钮。
- **原生**：`ContentUnavailableView { } description: { Text("在对话里让它安排，或者手动新建。") } actions: { Button("新建计划") { router.open(.newPlan(instanceID: id)) }.buttonStyle(.glassProminent) }`；
  右上 `Button("新建计划", systemImage: "plus")`；行 `NavigationLink(value: AppRoute.plan(id))` + `.swipeActions`（暂停 / 恢复；
  删除 destructive，加 `.confirmationDialog`）+ `.contextMenu`。
- **交互**：资料页“计划”行进来；点行进计划详情；“+”新建（sheet）。
- **状态**：加载中、空、离线（没有缓存：空状态 + 横幅）、待确认的计划排最上面（现有的“待确认”分区保留）。
- **ThinkTin 现在**：`.plans` → `Screens/Plans/PlanListScreen.swift`（全局，顶上按实例筛选的 `PlansFilterChip`；空状态
  `EmptyStateView`）+ `ViewModels/Plans/PlanListModel.swift`（已经支持 `instanceFilter`）。实例详情的 `workSection` 现在直接列出本实例的计划。
- **要改**：路由改 `.plans(instanceID:)`（第 0 轮）；`PlanListScreen` 接上 `instanceFilter`，有实例时不显示实例筛选；全部实例的
  计划列表（从工作台进）同一版式，筛选换 `FilterChipBar`。第 1 轮。
- **已做（2026-11-05，第 1 轮 D 线，对过参考 21）**：`PlanListScreen` 换成 insetGrouped `List`（`insetGroupedList()`，macOS `.inset`），
  inline 标题“计划”，右上玻璃“+”（`ToolbarSlot.trailing`，预选这个 Botin / 当前的 Botin；离线或没有 Botin 时灰掉）。
  Botin 资料进来的（`PlanListModel.scopeInstanceID`）只列这个 Botin 的、不显示筛选；工作台进来的第一行是 `FilterChipBar`
  （全部 + 各个 Botin，带数，透明行跟着内容滚），`PlansFilterChip` 删掉（触发器编辑器的“规则的写法”也换成 `FilterChipBar`）。
  分组：待确认（标题带数，点行进确认页，脚注说要确认才运行）、按时运行、已暂停；一行 `PlanRow`：左边按状态的图标和颜色
  （`PlanStatus.systemImage` / `tone`），单行标题，灰色副标题（规则摘要，全部的页面带 Botin 名，`PlansText.rowSubtitle`），
  一行状态（`PlanMetaLine`），Botin 写的带 AI 标识。左滑：删除（二次确认）+ 暂停 / 恢复；长按是同样的系统菜单（等确认的只有
  “查看并确认”和删除）。空着时（`PlanListModel.placeholder`）：参考 21 那样正中一段说明（`PlansText.listEmptyMessage`，没有图标和
  标题）+ “新建计划”玻璃按钮；拉不到时 `ContentUnavailableView` + 重试；全部的页面筛到没有时“看全部”。原来的 `PageHeader`
  说明拿掉（确认的说明挪到待确认一组的脚注）。
- **计划详情也换了（2026-11-05，D 线，参考里没有这一页，按第 2 节换原生）**：`PlanDetailScreen` 换成 insetGrouped `List`，
  版式跟 Botin 资料一样：居中的头部（44pt 状态图标、`.title2.bold()` 标题、AI 标识、状态 · 下一次、所属 Botin 的玻璃小胶囊），
  等确认 / 步骤卡住 / 规则失效各一行提示（等确认的带“查看并确认”`NavigationLink`），目标、触发规则（失效规则的“修改规则”“删除”
  换成系统小胶囊）、策略（`LabeledContent`）、流水线步骤、运行历史，最后一组暂停 / 恢复和红色“删除计划”整行按钮；右上 `ellipsis`
  菜单（不再是 `ellipsis.circle`）。找不到、拉不到用 `ContentUnavailableView`。新建 / 编辑表单、确认页、触发器编辑器还是原来的自画版式。
- **审查修正（2026-11-05）**：左滑“删除”只弹确认，按钮不用 `.destructive`（系统会先把行收走，取消后又跳回来），改成红色
  `tint`。产出物、保险箱、登录设备的“下线”、团队模板、运行树的“停止”同样处理；直接删掉的（收件箱、触发规则、电脑的吊销）照旧。
- **截图审查（2026-11-05，资料这一组，对过参考 21；计划详情参考里没有，对 Botin 资料 09 的版式）**：
  - 一行只有两行：标题（Botin 写的后面跟 AI 标识）和一行灰字（规则摘要 · Botin 名 · “下次：明天 09:00”，`PlansText.rowSubtitle`）。
    以前第三行“● 按时运行 下次：…”把分组标题又写了一遍；现在状态交给分组标题，只有规则失效、不会再运行、有规则失效时多一行
    （`PlanRowNotice`）。分组标题 `groupHeader()`，列表 `compactGroupedList()`。
  - 演示数据的“下一次”按规则真的算（`ScheduleForecast`，工作日 09:00 Asia/Shanghai），以前写死 21 小时后，截图上钟点和规则对不上。
    模拟器不在东八区时显示的是换算后的本地钟点，这是对的。
  - 空状态的说明换成自己的句式（“到点让 Botin 自己动手：……”），以前那句和参考 21 的句式太像。
  - 新截图 `53-plans-empty`（`THINKTIN_OPEN_SCREEN=allplans` + `THINKTIN_MOCK_EMPTY=1`：新账号的全部计划）专门对参考 21 的空状态；
    `04-plans` 是有计划时的列表。新账号没有 Botin，“新建计划”按钮和“+”是灰的 / 不显示，正好只剩那段字。
  - 计划详情：导航栏不写“计划详情”（`hiddenInlineNavigationTitle`，头部已经有计划名，和资料页一样），`compactGroupedList()`、头部
    上 8 下 16；触发规则一行改成图标一列、文字一列（规则、下次、上次、失效的说明和按钮都从同一个 x 起，以前后两行跑到图标底下）；
    策略几行一律是“图标 + 标题，下面一行灰字”的 `LabeledRow`（以前“审批”右对齐成一行、别的折成两行，不齐），图标中性灰；
    右上“…”中性色（`neutralTint()`）。确认页的策略也是这几行。
  - 留着没改的：右上玻璃“+”（能手动新建）、标题“计划”、insetGrouped 卡片和状态色图标、chevron（`NavigationLink` 进详情）。

#### 4.5.2 产出物（22、23、26、81、82、83、84）

- **布局**：压栈页，标题“产出物”（参考叫“资料库”）。顶上一排筛选胶囊“全部 / 媒体 / 文件”（参考是“全部 / 媒体 / 链接”），
  跟着内容一起滚；下面按时间分组（今天、本周、更早）；insetGrouped 卡片，每行：图标或 28pt 圆角缩略图 + 单行文件名
  （尾部截断）+ 灰色副标题（类型 · 日期 · 大小）+ AI 生成标识；列表最下面居中一个灰色文字按钮“展开”（还有更多时）。
- **原生**：`List(.insetGrouped)` + `Section(header:)`；筛选胶囊作为第一行（`.listRowBackground(Color.clear)`）；行
  `NavigationLink(value: AppRoute.artifact(id, runID:))`；`.contextMenu { ShareLink; 删除 }`；`.swipeActions` 删除；
  `.refreshable`；空状态 `ContentUnavailableView`；iOS 18 起图片行可以用 `.matchedTransitionSource(id:in:)` +
  `.navigationTransition(.zoom(sourceID:in:))` 放大进入（包在 `Design/Glass.swift` 的兼容层里，iOS 17 普通压栈）。
- **交互**：切筛选；点图片进全屏查看（4.5.3），点其他进产出物详情；长按或左滑删除（二次确认，现有）。
- **状态**：加载中、整体为空、某一类为空、离线（没有缓存：空状态 + 横幅）、刷新失败保留上次的结果（现有）。
- **ThinkTin 现在**：`.artifacts(instanceID:)` → `Screens/Artifacts/ArtifactScreens.swift`（`ArtifactLibraryScreen`、
  `ArtifactRow` 右边“…”菜单、`ArtifactIcon` 只有类型图标）+ `ViewModels/Artifacts/ArtifactModels.swift`（`ArtifactLibraryModel`：
  一个实例或全部实例、按实例筛选、删除）；`ArtifactFiles.isImage` 已经能按 `contentType` 认图片。
- **要改**
  - 第 1 轮：版式换 `List`；全部实例时保留“按实例筛选”（换 `FilterChipBar`）；AI 标识留在行尾（合规）。
  - 第 2 轮：按类型筛选和按日期分组在 `ArtifactLibraryModel` 里本地做；图片缩略图要下载整份文件，只给图片做、限数量、缓存。
  - “链接”分类没有数据，“展开”只能本地折叠（`instanceArtifacts` 只有 `limit`、没有游标），见 6.19。
- **已做（2026-11-05，第 1 轮 D 线，对过参考 22、23、26、81–84；第 2 轮的类型筛选、按日期分组、缩略图一起提前做了）**：
  `ArtifactLibraryScreen` 换成 insetGrouped `List`。第一行“全部 / 媒体 / 文件”`FilterChipBar`（带数，透明行跟着内容滚；媒体是
  图片、视频、音频，`ArtifactFiles.category`；“链接”按 6.19 C 换成“文件”）；按日期分组（今天、本周、更早，`ArtifactDateGroup`，
  组标题 `.textCase(nil)`）；一行 `ArtifactRow`：28pt 缩略图（能显示的图片、4 MB 以内、一次打开最多 30 张，`ArtifactThumbnailLoader`
  下整份文件，界面用 ImageIO 缩小解码，`ArtifactThumbnail`）或没有底的灰色类型图标，单行名字，灰色副标题（类型 · 日期 · 大小，
  v2 起带版本，全部 Botin 的库带 Botin 名，`ArtifactsText.rowSubtitle`），行尾 AI 生成标识。图片点了全屏查看（4.5.3，iOS 18
  缩放转场），别的 `NavigationLink` 进详情；左滑删除、长按“详情 / 查看生成它的运行 / 删除”。超过 20 个时最下面居中灰色“展开”
  （`ArtifactLibraryModel.expand()`，本地折叠）。全部 Botin 的库按 Botin 筛选挪到右上的系统菜单（`Picker(.inline)`，有筛选时实心图标），
  免得两排胶囊。空着时（`ArtifactLibraryModel.placeholder`）：还没有、没有这一类、拉不到（重试）。原来的 `PageHeader` 说明拿掉。
- **审查修正（2026-11-05）**：每一行都是按钮（文件行 `router.open(.artifact…)`、图片行全屏查看），不再用 `NavigationLink`：
  分组列表里它会画 chevron，文件行和图片行对不齐，参考 22、81、82 的行都没有。类型胶囊只写名字、不带个数（参考 22、23，和搜索的胶囊一样）。
- **截图审查（2026-11-05，资料这一组，对过参考 22、23）**：胶囊离导航栏、卡片离胶囊都比参考远一截（整页往下约 60pt）：列表
  `compactGroupedList(top: 4)`（分组间距 `.compact`，滚动内容顶上 4pt）；日期组标题照参考是 `.footnote` 的 `inkTertiary`；
  胶囊外面不再包 `GlassGroup`（见 2.8，那块灰影）。截图上胶囊的字 17pt、没选中的是橙字，是截图之后 `37c19b1` 已经改成 medium
  `.footnote` 和正文色的（参考 22 量出来约 13pt），没再动。空状态（还没有、这一类没有）换成参考 21 那样正中一段灰字，没有图标和
  标题（读屏照样先念标题）。演示数据加了一张自己画的小图（`DemoData.digestImageArtifactID`，“通知汇总截图.png”，通知汇总那次运行的），
  `35-artifacts-media` 有一行 28pt 缩略图可以对参考 23。右上按 Botin 筛选的菜单中性色。

#### 4.5.3 图片全屏查看（24、25）和产出物详情

- **布局**：纯黑全屏；左上玻璃 ×，右上玻璃“…”（分享、保存；参考还有“转发”）；图片按屏宽适配、左右留 16、圆角约 12；
  底部一行灰字（文件名）。
- **原生**：Artifacts 目录本地的 `.fullScreenCover`（不加路由），里面套 `NavigationStack`；`Button(role: .close)`；
  `Menu { ShareLink(item: fileURL); Button("保存", systemImage: "square.and.arrow.down") }`；图片存相册用 `PHPhotoLibrary`
  （只申请“添加”权限），别的文件 `.fileExporter`；缩放、平移交给 `.quickLookPreview`（现在就有）；
  `.toolbarBackground(.hidden, for: .navigationBar)`、`.preferredColorScheme(.dark)`；保存成功 `.sensoryFeedback(.success, trigger:)`。
- **交互**：点 × 或下滑回产出物；“…”分享、保存。
- **状态**：加载中、下载失败可重试、离线又没下载过时分享和保存禁用、没有相册权限时提示。
- **ThinkTin 现在**：`.artifact(id, runID:)` → `ArtifactDetailScreen`（名字带 AI 标识、版本 / 大小 / 时间 / 实例、“预览”用
  QuickLook、`ShareLink`、删除，按钮是 `PillButton`）+ `ArtifactDetailModel.prepareFile()`。
- **要改**：第 1 轮把产出物详情改成 `List(.insetGrouped)`（头部图标 + 名字 + AI 标识，信息一组），“预览”“分享”放底部，
  删除放“…”菜单最后（destructive）。第 2 轮加图片全屏查看和存相册（Info.plist 加 `NSPhotoLibraryAddUsageDescription`，
  隐私清单同步）。“转发给另一个实例”要后端（`sendMessage` 只能发文字），不做。
- **已做（2026-11-05，第 1 轮 D 线，对过参考 24、25；全屏查看和存相册从第 2 轮提前）**：`ArtifactImageViewer.swift`，库里点图片
  iOS 用 `.fullScreenCover`（macOS 是 sheet），纯黑底、深色外观；左上 `CloseButton`，右上“…”系统菜单：分享（`ShareLink`，文件名带
  AI 标识）、保存到相册（只有 iOS，`PHPhotoLibrary.requestAuthorization(for: .addOnly)`，Info.plist 加了
  `NSPhotoLibraryAddUsageDescription`，存好了成功触感，没权限 / 失败弹 `.alert`），第二组“详情”（关掉后压进产出物详情，那里有版本、
  运行、删除）。图片 ImageIO 解码、按屏宽适配、左右 16、圆角 12，点图片用 QuickLook 放大平移；底部一行灰字是文件名加 AI 标识。
  视图模型 `ArtifactViewerModel`（下载并落到本机、保存的状态，保存的办法由界面传进来）。参考的“转发”不做。
  产出物详情换成 insetGrouped `List`：居中的头部（44pt 类型图标、名字、AI 标识），信息一组（Botin、类型、版本、大小、生成于），
  文字类的“内容”一组，“查看生成它的运行”；底部浮着“预览”（`.prominent`）和“分享”两个胶囊；右上“…”里删除（二次确认）。
  找不到用 `ContentUnavailableView`。隐私清单不用改（只“添加照片”，不是要写理由的 API）。
- **审查修正（2026-11-05）**：导出的文件名没有扩展名时按 MIME 类型补上（`ArtifactFiles.preferredExtension`，`首页截图` +
  `image/png` → `首页截图（AI 生成）.png`；图片的“扩展名”不是图片格式的也补），存相册、QuickLook 预览、分享才认得类型。

### 4.6 电脑

#### 4.6.1 工作区（ThinkTin 新页，接实例资料的第三行；参考 27、65 的位置）

- **参考**：资料页“电脑”行（值“空闲”）进 Bot 云桌面的实时画面（27）；设置里的“Bot 电脑”可以从快照重置、看磁盘空间（65），
  脚注说所有 Bot 共用这台电脑。
- **ThinkTin**：每个实例一个云端沙箱；用户自己的电脑是账号级配对的（设置 → 登录设备），两者不对等（6.8）。
- **布局（建议）**：压栈页“工作区”，`Form`：
  - 状态组：实例状态 + 一段说明（复用 `AgentsText` 现有的说明：运行中、休眠、冷存储，唤醒要多久）。
  - 版本组：当前版本；有新版本时“升级到 x.y”按钮，旧版本在 `Picker(.menu)` 里选，选了用 `.confirmationDialog` 确认（挪自资料页）。
  - 以后加：“观看与接管”（4.6.2）、“重置工作区”（destructive + 确认）、“磁盘空间”（`LabeledContent`）。
- **原生**：`Form`、`LabeledContent`、`Picker(.menu)`、`Button(role: .destructive)`、`.confirmationDialog`。
- **ThinkTin 现在**：`InstanceDetailScreen` 的 `versionSection`、`InstanceVersionRow`（自己画的行，点了弹确认）、`setInstanceVersion`。
- **要改**：Agents 目录新页 `InstanceWorkspaceScreen.swift`（本地 `NavigationLink`），第 1 轮；重置、磁盘要后端（6.17），第 3 轮。
- **已做（2026-11-05，对过参考 65、27、28）**：`InstanceWorkspaceScreen.swift`，资料页“工作区”行 `NavigationLink` 压进来，`Form`：
  有新版本（或现在的版本下架了）时第一组是参考“重置电脑”那种行：强调色“升级到 vX”+ 灰字“下次唤醒时按新版本重建……”，脚注
  “这个 Botin 自己的云端沙箱……”；“状态”一行（状态点 + 名字），脚注是状态说明；“引擎”组：引擎版本、“换到别的版本”
  `Picker(.menu)`（选了先 `.confirmationDialog`）、接入方式，脚注是换版本的规矩 / 刚换到哪个 / 下架提醒。右上“?”（参考 27 的位置）
  弹“关于工作区”说明 sheet（参考 28 的版式：large、左上 ×、insetGrouped 两组，图标 + 标题 + 多行灰字；`WorkspaceHelp`）。
- **审查修正（2026-11-05）**：现在的版本已经不在目录里时，“换到别的版本”菜单补一项“v1.2.0（已下架）”（tag 是现在的版本，
  `needsDelistedVersionPlaceholder`），不然系统 `Picker` 的选中值没有对应的项（报错、右边空白）。选它不做事。
- **截图审查（2026-11-05，对过参考 65）**：照参考 65 把两组排出来（用户要的 1:1 版式，接口等 6.17）：
  - “重置工作区”（红字 + 一行 `.footnote` 灰字“回到最近一次快照，之后改过的文件会丢。”，没有箭头，`Button(role: .destructive)`），
    脚注“这个 Botin 自己的云端沙箱……”（参考“你的 Bot 共用的那台电脑”那一句的位置，以前挂在升级那一组或状态的脚注里）；点了弹
    “即将推出”（说现在的文件不受影响），不先弹确认框（确认完了又说做不了，白点一次）。
  - “磁盘空间”和“状态”放一组，值写“即将推出”（灰），不编一个“正常”。
  - 顺序：观看与接管 →（有新版本时）升级 → 重置 → 状态、磁盘空间 → 引擎。
  - “观看与接管”的说明改成一行 `.footnote`（`LabeledRow` 加了 `detailTypography`，文案“看它在云端桌面上做什么，随时接管。”）；
    右上“?”和“换到别的版本”的值是中性色 / 灰（2.2）；“引擎”分组标题 13pt 浅灰；上下收紧（`compactGroupedList()`）。
  - 文案在 ThinktinKit `InstanceWorkspaceText`（`reset`、`resetDetail`、`diskSpace`、`comingSoon`、`resetComingSoonMessage`）。

#### 4.6.2 观看与接管（27、29、30、31、89）

- **布局**
  - 黑底；标题是小头像 + 名字；右上玻璃“?”，控制时再加“…”（两个分开的圆）。
  - 中间是画面，按比例铺满宽度，上下留黑边。连接中是居中的 `ProgressView("正在连接…")`。
  - 只看时右下一个玻璃胶囊“接管控制”。
  - 控制时底部左边玻璃圆剪贴板按钮（菜单：从手机粘贴、复制到手机），右边玻璃圆键盘按钮；“…”里是“触控板模式”开关，
    建议再加“交还给实例”“结束接管”（参考没有明显的交还入口）。
- **原生**：`ToolbarItem(placement: .principal)`；`ToolbarItem(placement: .bottomBar)` + `ToolbarSpacer(.flexible, placement: .bottomBar)`；
  `Menu`；`PasteButton`（不能放进 `Menu`，放工具栏）；隐藏的 `TextField` + `@FocusState` 调出系统键盘；手势用系统的
  `SpatialTapGesture`、`DragGesture`、`MagnifyGesture`；画面要自己画（帧图片或 `AVSampleBufferDisplayLayer`）。
- **交互**：工作区或对话里“等你接管”的状态行进来；连上后自动显示画面；“接管控制”进控制；“?”看使用说明（4.6.3）；返回断开观看。
- **状态**：连接中、只看、控制中、断线重连、控制权被别的设备拿走、控制租约过期（先冻结输入，提示重新接管）、会话结束、
  连接失败（`ContentUnavailableView` + 重试）、离线、用蜂窝网络时的流量提示。
- **ThinkTin 现在**：没有。docs/browser.md 只有设计（只读票据和控制票据、单独的限帧画面通道、agent → waiting_owner → human → agent），
  而且讲的是沙箱里的浏览器，不是整个桌面；剪贴板、键盘、触控板模式它都没写；
  `ClientProtocol` 没有任何画面、会话接口；`Screens/Computer/` 只有配对、授权、电脑审批。
- **要改**：第 3 轮，新路由 `.instanceScreen(InstanceID)`（压栈）。看的是实例沙箱的浏览器、用户自己的电脑还是两者都要，见 6.8。
- **已做（2026-11-05，第 2 轮 r2/botin，对过参考 27、29、30、31、89；版式先做，画面是演示）**：
  - 路由 `.instanceScreen(InstanceID)`：归 `.agents`、压栈、离线 `unavailable`、标题“观看与接管”、从外面打开时经过 Botin 的对话
    （`returnsToConversation`），没有深链；`AppRouteTests` 的样本加一个。入口是工作区页最上面一行“观看与接管”（`display` 图标 +
    一行灰字，本地 `NavigationLink`）；对话里“等你接管”的状态行以后接 `router.open(.instanceScreen(id))`。
  - 页面 `Screens/Agents/InstanceScreenView.swift`：黑底，只这一页按深色画（`colorScheme` 环境 + iOS 的 `toolbarColorScheme`，不改整个
    App 的外观）；导航栏中间 24pt 头像 + 名字；右上“?”（使用说明，4.6.3），控制时旁边再一个分开的“…”（`GlassToolbarSpacer(.fixed)`）：
    “触控板模式”开关（`Toggle`，打勾）、“交还给 Botin”。中间连接中是转圈 +“正在连接…”（参考 27，演示停 0.8 秒），之后是按屏宽铺满、
    16:10、上下留黑边的占位画面（深灰渐变 + `display` 图标 +“画面即将推出”+ 一句说明；触控板模式时中间一个光标）。底部用 iOS 的底部
    工具栏（iOS 26 系统画玻璃）：只看时右边“接管控制”（连接中、离线灰掉，参考 27、29）；控制时左边剪贴板菜单（`clipboard`：
    “从本机粘贴”“复制到本机”，参考 89；参考写的是“手机”，iPad、Mac 上也对，所以写“本机”）、右边键盘（参考 30）。macOS 没有底部工具栏，
    这几个放右上。
  - 视图模型 ThinktinKit `ViewModels/Agents/InstanceScreen.swift`：`InstanceScreenModel`（连接中 → 只看 → 控制中，接管、交还只在本机切换
    版式，交还时关掉触控板模式）、`InstanceScreenAction`（剪贴板两项、键盘：点了弹“即将推出”）、`InstanceScreenDemoData`（16:10、连接停多久）。
    没用 `PasteButton`、隐藏输入框调键盘：没有后端，读剪贴板、调键盘只会让人以为发出去了。
  - **截图审查（2026-11-05，对过参考 27、29）**：浅色外观下状态栏是黑字，在黑底上看不见（时间、信号全黑，只剩绿色电池）：
    导航栏的底藏着时 `toolbarColorScheme(.dark)` 不管用。这一页给导航栏画黑色的底（`toolbarBackground(Color.black)` +
    `.visible`，和页面一样黑，看不出来；2.1 说的“不加 `.toolbarBackground(.visible)`”是给会滚动的页面的，这一页不滚）。
    “?”“…”、剪贴板、键盘、“接管控制”都是白字（以前是强调色）；“接管控制”的字换成 `.subheadline` 中等粗细（参考约 15pt）。

#### 4.6.3 使用说明（28）

- **布局**：large sheet“使用电脑”，左上 ×；insetGrouped 两组（移动操作：接管控制、滚动、点击与拖动、右键、放大；
  输入与剪贴板：输入、复制与粘贴），每行 SF Symbol + 标题 + 多行灰色说明。
- **原生**：`.sheet` + `.presentationDetents([.large])` + `Button(role: .close)` + `List(.insetGrouped)` + `Label { VStack } icon:`。
- **要改**：静态文案，跟 4.6.2 一起做（第 3 轮）。
- **已做（2026-11-05，第 2 轮 r2/botin，对过参考 28）**：画面页右上“?”弹 `InstanceScreenHelpSheet`：标题“使用说明”，large、左上 ×，
  “手势”（接管控制、滚动、点按与拖动、右键、放大）和“输入与剪贴板”（输入、复制与粘贴）两组，每行 SF Symbol + 标题 + 多行灰字，
  文案自己写的（`InstanceScreenHelp`），最后一组脚注“画面和控制即将推出，这里先说明以后怎么用。”。和工作区说明（4.6.1）共用一个
  `GroupedHelpSheet`（`InstanceWorkspaceScreen.swift`）。

### 4.7 新建与分组

#### 4.7.1 新建 Botin（34、35、117）

代码里还是领养（`AppRoute.adopt(agentID:)`、`AdoptionModel`、`adopt(agentID:name:harness:)`），界面上一律是“新建 Botin、选一个引擎”（6.6）。
同一个 agent 可以给好几个 Botin 当引擎：服务端只限每个账号的实例数，不限每个 agent 领养几次，`adopt` 每调一次就建一个新实例。

**已做（2026-11-05）**：第一版做成了原生分组 `Form` + 右上“新建”，用户对过参考图说不像，当天照参考重排了版式（下面写的是现在的样子）；
逻辑（名字规则、默认引擎和引擎详情要的引擎、接入方式、离线、上限和错误、取消前确认、建好进对话）和测试没变。

- **布局**（从上到下，深浅色一样）
  - large sheet；顶上左边玻璃 ×（`CloseButton`），中间标题“新建 Botin”，**右边不放按钮**。
  - 居中的大头像预览（`Metrics.Avatar.profile`，固定 120pt，**不跟动态字体缩放**：跟着缩放时最大字号下有 370pt 宽，比屏幕还宽）：
    选的形状、选的颜色（没选按名字取）、名字的第一个字；还没输入名字时是中性的占位符号（`ellipsis`）。读屏不念（下面的输入框和网格自己会念）。
  - 大号名字输入框：整宽、圆角 16 的填充底（`paperElevated`，`Metrics.Radius.nameField`；参考 34 是圆角矩形，2026-11-05 以前是胶囊），`.title2` 半粗、居中，占位“起个名字”（以前是参考的原句换了个词），
    **默认空的**（以前默认填引擎名，删了）；点胶囊的哪儿（两头、上下的边）都聚焦输入框。下面的小字只在有用时出现（`AdoptionModel.nameNote`）：只输了空格说“起个名字吧。”、太长说问题
    （失败色），快到 64 个字的上限（还剩 10 个以内）时提示上限；空的不说（按钮灰着就够了）。
  - 紧凑的引擎卡片紧跟在名字下面，只占一行（2026-11-05 两次截图：放在头像卡片下面时被底部的“新建”按钮挡住；挪上来后占三行，又把色板挤到按钮后面。现在是一行“引擎 ⓘ ……菜单”，ⓘ 是“了解引擎”，接入方式并进同一个菜单的第二组；头像预览改成 100pt、各块间距改成 `Spacing.m`，一屏放得下）。下面“紧凑的引擎卡片”里说的“接入方式”一行、“了解引擎 ›”链接以这条为准。
  - 头像选择（2026-11-05 起直接画在 sheet 的底上，不画卡片，参考 34、35、117；改头像页照旧是卡片）：形状网格 3 行 × 5 个（`AvatarShape`，15 种），色板 2 行 × 6 个
    （`AvatarColor`，12 种）。每个形状格子都用现在的颜色和名字的首字画、按格子的宽度画（窄屏、大字号不挤出格子），选中的有强调色的
    圆角框；色板选中的外面一圈同色的环。没选过颜色时带环的是按名字取的那个色，输名字时环跟着走；点了就固定。
  - 紧凑的引擎卡片（位置在名字和头像卡片之间）：一行“引擎”+ 系统 `Menu`（按钮上是选的引擎名和上下箭头；菜单里是行内的系统 `Picker`，每项名字 + 一句话介绍当副标题，
    选中的由系统打勾、读屏念“已选中”，不能用的灰掉、点不了；都不能用时按钮上写“暂时没有能用的”）；引擎有多种接入方式时下面一行“接入方式”`Picker(.menu)`。卡片下面一个小链接
    “了解引擎 ›”压进引擎目录。目录在拉时按钮位置转圈；拉不到写“暂时拉不到引擎列表”+“重试”（离线不给重试，联网自己补拉）；目录是空的写
    “还没有能用的引擎，稍后再来看看。”。
  - 底部固定的一条（键盘弹出时在键盘上面，`floatingBar(edge: .bottom)`）：失败、Botin 数到上限的 `ErrorBanner`；离线时一句说明和
    “重新检查网络”；一行许可小字（`NewBotinText.licenseCaption`：专有许可——目录给了许可说明的——写“新建即表示同意 X 的许可条款”，
    英文“By creating, you agree to the X terms”，开源的写“X 采用 Y 许可”，没写许可证的写“X 没有注明许可证”）+“查看”
    （一行放不下时——英文的长名字、大字号——小字居中折行、“查看”换到下一行，`ViewThatFits`；小 sheet，medium / large：许可证、专有许可的说明和
    “新建即表示你同意按上面的条款使用这个引擎。”，或者在沙箱里运行的说明，有上游仓库时给链接，`NewBotinText.licenseDetails`）；
    最下面胶囊主按钮“新建”（`glassButtonStyle(.prominent)` + `.buttonBorderShape(.capsule)` + `.controlSize(.large)`，两边比页边多缩进 20pt，参考 34）。
  - 默认引擎：预选的（从引擎详情进来），其次最近活跃的那个 Botin 用的引擎（“上次用的”），再次目录里第一个能用的（`AdoptionModel.defaultEngine`）。
- **原生**：`.sheet` + `NavigationStack`（`SheetStack`）+ `ScrollView`（`.scrollDismissesKeyboard(.interactively)`）；
  `TextField(_:text:prompt:)` + `.textFieldStyle(.plain)` + `.submitLabel(.done)`、`@FocusState`（不自动弹键盘，先看到整张表）；
  `LazyVGrid` 里 `Button(.plain)` + 选中框 / 环 + `.accessibilityAddTraits(.isSelected)`（读屏念形状、颜色的名字），`.sensoryFeedback(.selection)`；
  引擎 `Menu` 里放 `Picker(.inline)`（每项一个视图、两个 `Text` 是标题和副标题，`.tag(AgentID?)`，`.disabled(!isAvailable)`，
  选不能用的在视图模型里也拦；不自己画勾）；接入方式 `Picker(.menu)`；
  “了解引擎”`NavigationLink(value: AppRoute.agentCatalog)`（压进 sheet 自己的栈）；工具栏只有 `CloseButton`（Design/Glass.swift）；
  底部按钮新建中换成转圈（读屏“正在新建”）；`.interactiveDismissDisabled(isAdopting || hasUserInput)`；填了东西点 × 时
  `.confirmationDialog`（“不建这个 Botin 了？”）。
- **交互**：首页“+”、首页空状态的“新建 Botin”、引擎详情的“用它新建 Botin”（预选那个引擎）打开；名字合法、选了能用的引擎、在线才能点“新建”
  （`AdoptionModel.canCreate(isOffline:)`），不能点时按钮灰着；建好关 sheet、从首页压栈进新 Botin 的对话（`AppModel.openCreatedInstance`，
  4.3.1 的首次状态：空状态下面“还差一步：给它配模型路由……”和“配置模型路由”按钮），挑的头像外观记进这台设备（见下面“头像”）；
  × 取消（填了名字、挑过形状或颜色时先确认，`hasUserInput`），没填东西时下滑也能取消（新建中、填了东西时不能，只能点 × 确认）。从表单的
  “了解引擎”进到引擎详情再点“用它新建 Botin”时回到这张表单、换成那个引擎，不叠第二张（`Router.engineRequest`）；表单自己的目录还没拉到时
  先记下，拉到后再换（`AdoptionModel.requestEngine`），不会落回默认的引擎。
- **头像**：形状默认圆形、颜色默认按名字取（`InstanceAppearance.default`，没挑过的 Botin 和以前一样）。服务端还没有头像字段（6.9），
  建好之后记进这台设备的 `InstanceAppearanceStore`（ThinktinKit `ViewModels/Shell/`，`UserDefaults` 一个键、按实例 id，`AppModel.appearances`；
  默认的不记；删了 Botin（`InstanceDetailModel.delete()`）、注销账号时 `forget` 掉；认不出的形状、颜色原样存回去，见 6.9）；首页的行、
  搜索结果（首页的和搜索页的）、对话页导航栏中间的小头像 + 名字（`inlineNavigationTitle(_:principal:)`，导航栏中间只有这一项；实例列表里
  还没有这个 Botin 时只写页面标题、不画头像）、Botin 资料的头部按它画。首字的字号按形状的比例、不小于 9pt（导航栏的 24pt 头像上窄的形状
  也看得清）；状态角标的圆心落在形状右下方的轮廓上（`AvatarShapeGeometry.badgeAnchors`，四角星、叶子、菱形的右下角是空的）。形状是自己设计的
  简单几何、有机形状（`Components/AvatarShapes.swift`：圆形、圆角方形、拱形、六边形、八边形、菱形、圆角三角形、盾牌、叶子、鹅卵石、四角星、
  五角星、花朵、花边圆、云朵），只放首字，不画脸和眼睛，不用参考 App 的形象。颜色 12 种（`InstanceAvatar.colors(of:)`，浅深各一套，白字对比度
  4:1 以上，避开强调色和成功 / 警告 / 失败色；石板灰、石墨灰、灰褐是中性色；前 8 种是按名字取色的那套，色值和顺序没变）。
- **状态**：引擎列表在拉、拉不到、目录是空的、都不能用；名字不合法（`AdoptionModel.nameNote`）；提交中（底部按钮转圈）；失败和实例数到上限
  （`ErrorRecovery.limitReached`，不给重试）在底部条的 `ErrorBanner`；离线一句说明和“重新检查网络”，“新建”不能点。
- **ThinkTin 现在**：`Screens/Agents/AdoptAgentSheet.swift` + `ViewModels/Agents/AdoptionModel.swift`（`EngineOption`、`NewBotinText`）。
  原来的“领养好了”页（`AdoptionDoneView`，引导配模型或加 key）删了，引导挪到新 Botin 对话的空状态（第 2 轮换成 6.18 的首次卡片）；
  没有能用的 key 时路由页自己引导加 key。
- **已做（2026-11-05，第 1 轮 C 线）**：引擎目录（`.agentCatalog`）换成 plain 列表行（参考 101、104）：40pt 圆角方块图标（`EngineIcon`，
  `.squircle` 形状 + 名字首字 + 按名字取色，和 Botin 默认的圆形分开）+ 名字 + 最多两行灰字（`AgentCatalogCard.rowSubtitle`）+ 右边玻璃小胶囊
  “选这个”（`actionTitle`，不能用的“暂不可用”灰掉；点了 `router.open(.adopt(agentID:))`：在新建表单里时退回表单换引擎，别处弹预选它的表单）；
  不画分隔线；以前的页头说明挪到列表最后一段灰字；空、拉不到是 `ContentUnavailableView`。点行弹引擎详情 sheet（4.8.3 的版式，medium / large，
  本地 `.sheet(item:)`，不改路由；详情里的“用它新建 Botin”“在用它的 Botin”先关 sheet、在 `onDismiss` 里再走路由）。“N 个 Botin 在用”
  不在行上了（读屏标签里有，详情里列出来）。`.agent(id)` 路由（压栈）还在，画的是同一个详情页，没有 ×、操作直接走路由。
  建好之后改头像第 1 轮顺带做了（4.4.4）；多端同步等后端字段（6.9 B）。
- **截图审查（2026-11-05，对过参考 34、35、117、101、104、38、52）**：
  - 新建表单：形状网格和色板不画白色卡片（`AvatarPicker(showsCard: false)`，上下的内边距一起去掉）；省下的 32pt 让头像预览回到
    120pt（`Metrics.Avatar.profile`，参考约 125；以前为了一屏放得下改成 100）；名字输入框圆角 16；底部“新建”两边多缩进 20pt，
    不能点时换成灰色的填充（`Theme.inkTertiary` 的 tint，参考是实心的灰胶囊；系统灰掉的突出按钮在浅色底上几乎看不见）；
    引擎菜单按钮上的名字和上下箭头是灰的（`menuPickerTint()`，和表单里的菜单选择器一样），ⓘ 是链接，照旧强调色；左上 × 中性色。
  - 引擎目录：行的灰字换成 `.footnote`（参考约 13pt），行不再自己加上下边距；“选这个”从强调色的小胶囊换成普通大小的玻璃胶囊、
    中性色的字（参考“连接”）。
  - 引擎详情：导航栏中间以前照样画出了名字（见 2.6），换成 `hiddenInlineNavigationTitle`；头部贴着导航栏
    （`compactGroupedList(top: 0)`），介绍换成 `.subheadline`；分组标题 13pt 浅灰。medium 档时内容照旧从底部的“用它新建 Botin”
    下面滚过去（2.1 的滚动边缘效果，参考的介绍短所以后面是空的），头部上移以后挡住的少了，没另外加底部边距。

#### 4.7.2 分组（91、92、93）

- **参考**：首页长按“新建分组” → 带输入框的 alert；列表出现可折叠的分组标题“名字 ⌄”；长按分组标题 → 菜单（重命名、上移、
  下移、删除）；删除前 alert 确认（“其中的 Bot 会移到未分组，不会删除任何 Bot”）。
- **原生**：`.alert` + `TextField`；`Section(isExpanded:)`（iOS 17 起；系统只在 `.listStyle(.sidebar)` 里自动画折叠箭头，
  首页是 plain 列表，标题要自己做成 `Button` 切换 `isExpanded`，箭头用 `chevron.down` 跟着转）；分组标题 `.contextMenu` + `.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))`；
  删除 `.alert` + `role: .destructive`；排序也可以用 `EditButton` + `.onMove` 拖动，代替上移、下移。
- **ThinkTin 现在**：没有。“团队”（`.teams`）是协作单位，不是列表分组。
- **要改**：按 6.10，建议先不做；要做就是第 2 轮、本机存，和置顶、隐藏一起设计数据结构（`InstancePreferencesStore`）。

### 4.8 应用与连接

#### 4.8.1 连接目录（36、40–51）

- **参考**：首页左下进“连接应用”：large sheet，左上 ×，标题“连接应用”，右上玻璃胶囊“已连接 N 个”；顶上一排横向滚动的
  分类胶囊（全部、iPhone、密码管理器、效率、通信、设计、代码、数据、销售、营销、财务、研究、支持），选中的白底，滚到最左；
  分组标题 `.title3.bold()`（“为你推荐 >”“精选插件 >”可以点开完整列表）；plain 列表行：40pt 圆角图标 + 标题 + 两行灰色说明 +
  右边小胶囊按钮（连接 `.bordered`、授权 `.borderedProminent`、已连接 `.bordered` + `.disabled`）；底部浮动搜索“搜索应用和技能”。
  “iPhone”分类能把日历、提醒、通讯录、位置、家庭、闹钟开放给 Bot；“密码管理器”接第三方密码管理器。
- **原生**：`.sheet` + `NavigationStack`；`Button(role: .close)`；`ToolbarItem(placement: .primaryAction) { NavigationLink("已连接 \(n) 个") }`；
  分类 `FilterChipBar`（分类多，不用 `Picker(.segmented)` 或 `.searchScopes`）；`List(.plain)` + `.listRowSeparator(.hidden)`；
  `.searchable`；OAuth 用 `@Environment(\.webAuthenticationSession)`；图标 `AsyncImage`，没有时拼图 SF Symbol 占位。
- **ThinkTin 现在**：没有第三方连接器、插件、技能；架构上 shim 只注入平台工具和电脑工具，在线技能市场关闭、技能走白名单（15.3）。
  已有的“接入”分散在设置里：模型 key（`Screens/Models/CredentialsScreen.swift`、`AddCredentialSheet.swift`）、IM 渠道
  （`Screens/ImChannels/ImChannelScreens.swift`）、保险箱（`Screens/Vault/VaultScreens.swift`）、电脑配对
  （`Screens/Computer/ComputerLinkViews.swift` 的 `ComputerLinkSection`、`PairComputerSheet`）。
- **要改**：按 6.12 的方案 A，第 2 轮做一个“连接”汇总页：分类是 全部 / 电脑 / IM 渠道 / 模型 key / 保险箱，每类一行或几行
  （已配对的电脑、已绑的群、已加的 key、保险箱条目数），行上的按钮直接打开现有的 `PairComputerSheet`、`ImChannelEditorView`、
  `AddCredentialSheet`、`.vault`。新功能目录 `Screens/Connections/` + `ViewModels/Connections/`（只用现有的 `devices()`、
  `imChannels()`、`credentials()`、`vaultItems()`），新路由 `.connections`，入口是设置里的“连接”行（参考设置里也有“连接应用”一行，
  53）。第三方应用、“此 iPhone”、第三方密码管理器要后端和产品决定，第 3 轮或不做。
- **已做（2026-11-05，r2/connections，对过参考 36、40–51、53）**：用户要求先把参考的版式 1:1 全做出来（包括 ThinkTin 还没有的应用），
  以后再按真实功能删改。`ConnectionsCatalogScreen`（`.connections(category:)`，`category` 是预选的胶囊）：设置里压栈进来，标题“连接”，
  右上系统按钮“已连接 N 个”（压栈到 4.8.2）；第一行 `FilterChipBar`：全部、iPhone（只在 iOS 上有）、电脑、模型、密码管理器、效率、通信、
  设计、代码、数据、销售、营销、财务、研究、支持（参考的分类之外多了“电脑”“模型”）；“全部”是“为你推荐 >”（露 4 个）“精选 >”（露 6 个）
  两组，标题 `.title3.bold()` + 小箭头，点了压栈到 4.8.4；选了分类是同一个页面换成那一类的一组（一个按数据生成的分类页，参考 40–51；
  “此 iPhone”标题下有说明）；组标题放在行的位置（plain 列表的 Section header 会吸顶带底色，参考没有）；行是 40pt 圆角方块图标
  （SF Symbol + 系统色底，不用别家的 Logo）+ 名字 + 两行灰字 + 右边小胶囊（连接 `.glass`、允许 / 添加 / 配对 `.glassProminent`、
  灰掉的已连接）；`.searchable`“搜索应用和技能”（名字、说明、技能，中英文都搜），有字时换成搜索结果、搜不到 `ContentUnavailableView.search`；
  末尾一段灰字说清楚现在能连哪几样。数据：`ViewModels/Connections/`（`ConnectionsModel`、`ConnectionCatalog`、`ConnectionsText`）。
  ThinkTin 已有的接入（电脑、飞书、企业微信、钉钉、模型 key、密码保险箱）用真数据算“已连接 / 添加”，按钮和账户打开现有页面
  （登录设备、IM 渠道、添加 key、模型 key、保险箱）；其余是本地演示数据 `ConnectionsDemoData`（通用叫法：在线文档、代码仓库、客户管理……，
  不写别家的产品名），按钮弹系统 alert“即将推出”。没改 `ClientProtocol` / Mock / CoreClient。设置根页第二组的“IM 渠道”换成“连接”
  （副标题“电脑、IM 渠道、模型 key 和更多应用”，规范 4.9.1 说的挪进连接）。截图 `THINKTIN_OPEN_SCREEN=connections`（`19-connections`）。
  **还没做**：“此 iPhone”、第三方应用、网页授权（6.12 的 B）。
- **已做（2026-11-05，四条 r2 线合进来以后补的跨线小事）**：参考从首页左下的“应用”按钮进目录；ThinkTin 那里是工作台菜单，菜单最后加
  一项“连接”（`WorkbenchEntry.connections`，图标和设置那一行一样是 `puzzlepiece.extension`，不带数、不算进总角标），点了
  `openTopLevel(.connections(category: nil))`（关掉 sheet、回首页再压）；`.connections(category: nil)` 算顶级页面，预选了分类的不算。
  设置里的那一行照旧（压进设置 sheet 的栈）。

#### 4.8.2 已连接列表（37）

- **参考**：目录右上“已连接 N 个”压栈到“你的插件”：分组“已安装”，行同目录，尾部按钮三种（授权、浏览插件、已连接），底部搜索。
- **要改**：第 2 轮的汇总页里，“已连接 N 个”压栈列出全部已有的接入（电脑、群、key、保险箱条目数），点进各自的管理页。
  第三方插件版本第 3 轮。
- **已做（2026-11-05，r2/connections，对过参考 37）**：`ConnectedAppsScreen`（`.connectedApps`，标题“已连接”）：plain 列表，灰色小标题
  “已安装”，下面是 ThinkTin 自带的六项；连上的副标题写账户数（“1 台电脑”“1 个群”“3 个 key”“2 个条目”，参考“2 个连接器”的位置）、右边灰掉的
  “已连接”，没设置的写说明、右边突出的“添加 / 配对”（参考“授权”的位置）；点行弹 4.8.3 的详情；底部搜索“搜索已连接的应用”；末尾一句
  “第三方应用即将推出”。从添加 key、IM 渠道这些页面回来时重新数（看 `router.visibleRoute`）。参考的“浏览插件”那种按钮没有对应的。

#### 4.8.3 插件详情 sheet（38、39、52、105、106、107）

- **参考**：在目录 sheet 上再弹 medium / large 两档的 sheet；左上 ×，已连接时右上“…”（菜单里只有红色“断开连接”）；居中 56pt 图标 +
  名称（`.title2.bold()`）+ 说明；“账户”分组（账户名 + 蓝色“添加账户”）；底部居中的胶囊（没连接时蓝色“连接”，连上了变成灰色
  不可点的“已连接”）。
- **原生**：`.sheet(item:)` + `.presentationDetents([.medium, .large])`；`Button(role: .close)`；`Menu { Button("断开连接", systemImage: "trash", role: .destructive) }`
  + `.confirmationDialog`；`Section("账户") { … Button("添加账户") }`；底部 `.safeAreaBar`。
- **已做（2026-11-05，借给引擎详情）**：`AgentDetailScreen`：目录点行弹的 medium / large sheet，左上 `CloseButton`，没有标题；居中 56pt
  圆角方块图标 + 名字（`.title2.bold()`）+ 出处，下面一段灰字介绍（左对齐）；许可证（和上游仓库）、接入方式、版本、模型接口、能用的地区、
  在用它的 Botin 几组（insetGrouped）；底部 `floatingBar` 里居中的胶囊“用它新建 Botin”（`.prominent`、不占满整宽，medium 档也看得到）。
  参考右上“…”（断开连接）没有对应的操作，不放。下架的是 `ContentUnavailableView` +“看看别的引擎”。
- **要改**：插件本身第 3 轮。这个版式第 2 轮可以借给 agent 详情（`.agent(id)`：图标、名字、介绍、上游、许可，底部“领养”），
  要不要把 agent 详情从压栈改成 sheet 一起定。注意：说明很长时 medium 档放不下关键信息（106），状态和主按钮要放在说明前面，
  或者说明限制行数加“展开”。
- **已做（2026-11-05，r2/connections，对过参考 38、39、52、105、106、107）**：`ConnectionDetailView`：目录、列表点行弹的本地 sheet
  （medium / large，和引擎详情一样，`ConnectionsHost` 管 sheet、“即将推出”和关 sheet 后再走路由），`.connection(id)` 路由是压栈的同一个页面。
  左上 `CloseButton`；已连接时右上 `ellipsis` 菜单：“管理”（进现有的管理页）+ 红色“断开连接”——ThinkTin 自带的接入弹 alert 说清楚去哪删
  （带“去 IM 渠道 / 去模型 key …”按钮，这一页不替用户一次删光），演示数据弹“即将推出”。居中 56pt 图标 + 名字（`.title2.bold()`）+
  左对齐的灰字长说明，演示数据下面多一句“即将推出”；“账户”组（已连接时）：群、key、电脑、保险箱条目，停用 / 离线的灰字（参考 107），
  点了进 key 详情、保险箱条目、IM 渠道、登录设备，最后一行强调色“添加账户”；带技能的（演示的“代码仓库”，参考 105）多一组“技能”；底部
  `floatingBar` 里居中的胶囊：没连时“连接 / 允许 / 添加群机器人 / 添加 key / 配对电脑”，连上了灰掉的“已连接”，medium 档也看得到。

#### 4.8.4 推荐 / 精选完整列表（101、102、103、104）

- **参考**：点“为你推荐 >”“精选插件 >”压栈到完整列表：plain 列表，行同目录，一次加载完，没有分页。
- **要改**：第三方目录第 3 轮。行版式第 1 轮借给 agent 目录（4.7.1）：“领养 / 已领养”对应“连接 / 已连接”。2026-11-05 做了，
  右边的胶囊是“选这个”（同一个引擎能建好几个 Botin，没有“已连接”那种灰掉的状态）。
- **已做（2026-11-05，r2/connections，对过参考 101–104）**：`ConnectionListScreen`（`.connectionList(.recommended / .featured)`，标题“为你推荐”
  “精选”）：plain 列表，行同目录，一次显示完；推荐的行副标题写理由（连了相关的那一项时“因为你连了飞书”，没连就写说明，不编造理由）；
  精选打头的是 ThinkTin 自带的四项。点行弹 4.8.3 的详情。

### 4.9 设置

#### 4.9.1 设置根页（53、70、75）

- **布局**：sheet，左上玻璃 ×，没有标题。insetGrouped 分组（ThinkTin 的版本）：
  1. 账号行（44pt 首字头像 + 昵称 + 打码手机号 + chevron）、模型 key、用量（值：今天用了多少 token）、保险箱（副标题“实例能用的账号密码”）。
  2. 连接（副标题“电脑、IM 渠道、模型 key”，第 2 轮）。
  3. “实例”组：审批（进审批中心；自然语言规则见 6.15）、登录设备、IM 渠道（第 2 轮挪进连接）、实时活动（现有的那一组）。
  4. 通知（开关）、外观（值）、语言（值）、触感反馈（开关，第 2 轮）。
  5. 安全：全部停止（destructive + 确认）、下线其他设备。
  6. 外部链接（右边 `arrow.up.right`）：帮助中心（等网址）、用户协议、隐私政策；关于 ThinkTin、开源许可、上手引导。
  7. 发送反馈（第 3 轮）。
  8. 退出登录（红字，单独一组，确认）。
  9. 版本区：`BrandLogo` 高 40 + “ThinkTin” + 版本（构建号）。
- **原生**：`List(.insetGrouped)`；`NavigationLink(value: AppRoute.x)`（sheet 里的导航栈用 `.appRouteDestinations()` 接住）；
  `LabeledContent`；`Toggle { Text(标题); Text(说明) }`；`Link(destination:)` + `Image(systemName: "arrow.up.right")`；
  `Button(role: .destructive)` + `.confirmationDialog`；版本区放最后一个 Section 的 footer。
- **交互**：点各行压栈；× 或下滑关闭。通知开关反映的是系统权限：没问过时拨开就请求权限，拒绝过的跳系统设置；App 自己关不掉
  系统通知，`ClientProtocol` 也没有“停止给这台设备推送”的接口，所以拨到关也是跳系统设置（真要 App 内关推送，要后端加开关，
  和 6.14 一起做）。拿不准就保持现在的做法：一行带状态值、点了跳系统设置，不做成开关。
- **注意**：设置变成 sheet 以后，里面各子页现有的 `router.open(...)`（保险箱条目、模型 key 的“添加”、用量跳 key、上手引导）会把设置关掉，
  第 0 轮要先改 `Router`（3.3 “sheet 里的跳转”一行）。
- **状态**：不用联网（`local`），离线时各子页自己显示离线状态。
- **ThinkTin 现在**：`.settings` → `Screens/Settings/SettingsScreen.swift`（`SettingsContent`，`AccountScrollPage` / `AccountSection` /
  `AccountRow`，每行带图标）+ `ViewModels/Settings/SettingsModel.swift` 的 `sections(_:)`（账号、模型 key 与用量、保险箱、通知、
  外观与语言、安全、关于）+ `LiveActivitySettingsSection.swift`；底部 `SettingsFootnote` 只有一行字；入口是抽屉底部头像。
  通知现在是跳系统设置的一行。
- **要改**：`.settings` 改 sheet（第 0 轮）；`SettingsModel` 按上面重排（纯 Swift，Linux 上测）；整页换 `List`；用户协议、隐私政策从
  关于页挪一份到根页（关于页保留，备案号和 AI 说明是合规要求）；注销账号挪进账号页。参考的订阅、权限规则、时区、Bot 电脑、
  导入记忆、连接应用见第 6 节。第 1 轮。

- **已做（2026-11-05，第 1 轮 E 线，对过参考 53、70、75）**：`SettingsScreen` 换成 insetGrouped `List`，没有标题（`inlineNavigationTitle` 放空），
  行里不放图标；分组照参考的顺序（`SettingsModel.sections(_:pendingApprovals:)`，ThinktinKit 里测）：① 账号行（44pt `InstanceAvatar` + 昵称 +
  打码手机号）、模型 key（副标题）、用量（值“今天 1.2 万”，`UsageToday` 按东八区今天拉，离线不显示）、保险箱（副标题）；② IM 渠道（参考
  “连接应用”的位置）；③ 标题“Botin”：审批（参考“权限”的位置，副标题“N 条等你批准”或说明）、登录设备，后面接实时活动的一组开关；
  ④ 通知（系统 `Toggle`，状态是系统权限，拨它跳系统设置，回前台重读）、外观、语言、触感反馈（值“开启 / 关闭”，进子页）；⑤ 安全（全部停止、
  下线其他设备，参考没有，带标题）；⑥ 用户协议、隐私政策（`Link` + `arrow.up.right`，地址挪进 ThinktinKit 的 `LegalLinks`）；⑦ 关于 ThinkTin、
  开源许可、上手引导（参考“发送反馈”的位置）；⑧ 红字“退出登录”（确认）。最底下版本区 `SettingsVersionFooter`（`BrandLogo` 高 40、
  “ThinkTin”、版本（构建号））。昵称、手机号、注销账号挪进账号页（4.9.2）。`AccountSection` / `AccountRow` / `SettingsOptionRow` /
  `SettingsFootnote` 在设置根页和外观、语言页不再用。
- **审查修正（2026-11-05，对过参考 53、70、75）**：第一组改成 账号、用量、模型 key、保险箱（参考 53 用量紧跟账号）；链接组隐私政策在前、
  用户协议在后（参考 75）；通知那组只在通知没开着时有脚注（参考 70 没有，`NotificationPermission.footer`）。通知开关：还没问过权限时
  拨它在 App 里请求（`\.notificationAuthorizer`，和引导同一个），问过了才去系统设置（`NotificationToggleAction`）。实时活动的两个开关
  是“Botin”组里审批后面的两行（参考 53 那组里的“自动设置时区”），说明挪进那组的脚注，不再单独一组带“实时活动”标题
  （`LiveActivitySettingsRows`）。账号行的头像换成中性灰的首字圆（`AccountAvatar`，底色 `userBubble`、字是次要色，参考 53、54），
  和 Botin 的彩色头像分开；首页左上的账号按钮同样。“全部停止”出错时横幅是同组里单独的一行，点横幅不再弹“全部停止？”。
- **已做（2026-11-05，r2/connections）**：第 ② 组的“IM 渠道”换成“连接”（副标题“电脑、IM 渠道、模型 key 和更多应用”，进 4.8.1 的目录；
  IM 渠道从目录的“通信”、已连接列表、飞书 / 企业微信 / 钉钉的详情进）。
- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 53、70、75）**：根页加了四行，按参考的位置：第一组用量后面“订阅”（`.subscription`）；
  “Botin”组第一行“权限”（`.permissions`，副标题按演示规则写“自动审查已开启 · 3 条规则”），审批挪到它下面照旧进审批中心，登录设备后面
  “导入记忆”（`.importMemory`）；链接组后面单独一组“发送反馈”（`.feedback`，`SettingsSection.ID.feedback`）。参考的“自动设置时区 / 时区 /
  Bot 电脑”没加（6.17 时区不做；工作区是每个 Botin 一个，在 Botin 资料里），“帮助中心”还没有网址。
  合进 ios-ui-redesign 以后第一组是 账号、用量、订阅、模型 key、保险箱（订阅照参考 53 紧跟用量，用量照审查修正紧跟账号）。

#### 4.9.2 账号（54）

- **布局**：压栈页“账号”；第一组：头像 + 昵称 + 打码手机号（ThinkTin 用手机号登录，没有邮箱）；第二组：昵称（点了 alert 改）、
  手机号；最后单独一组：红色垃圾桶“注销账号”，footer 写“永久删除，不能恢复”。参考的“切换账户 / 添加账户”不做（6.20）。
- **原生**：`List(.insetGrouped)`；改昵称 `.alert` + `TextField`；注销 `NavigationLink` 进现有的注销页。
- **ThinkTin 现在**：`.account` → `Screens/Account/AccountView.swift`（`AccountScreen`）、`DeleteAccountView.swift`（短信验证码注销）、
  `ViewModels/Account/AccountModel.swift`；组件是 `AccountSection` / `AccountRow`。
- **要改**：换 `List`；退出登录挪到设置根页。第 1 轮。

- **已做（2026-11-05，E 线，对过参考 54）**：insetGrouped `List`：第一组 `SettingsProfileRow`（44pt 头像、昵称、打码手机号，不能点）；
  “个人资料”组昵称（进改昵称页，改昵称页换成 `Form` + 脚注里的说明和字数、右上 `ConfirmButton("保存")`）、手机号（只读，脚注不能换）；
  红字“退出登录”单独一组（确认，脚注“只影响这台设备”）；红色垃圾桶“注销账号”单独一组，脚注写后果，进现有的注销页（注销页没改版式）。
  改昵称没用 `.alert`（要显示字数和校验）。登录设备、全部停止不在账号页了（设置根页有）；`StopAllRow` 换成 `List` 里的系统
  `Button(role: .destructive)` 一行。
- **审查修正（2026-11-05）**：账号页第一行的头像也是中性灰的首字圆（`AccountAvatar`，和设置根页同一个 `SettingsProfileRow`）。
- **本机记录（2026-11-05，四条 r2 线合进来以后补的跨线小事）**：服务端没有、只存在这台设备上的按 Botin 记的五样（头像外观
  `InstanceAppearanceStore`、首页置顶和隐藏 `InstancePreferencesStore`、语音通话 `BotinVoiceStore`、表情回应 `MessageReactionStore`、
  主 Botin `PrimaryBotinStore`）放进 ThinktinKit 的 `BotinLocalData`（`AppModel.local`）。删 Botin（资料页、首页长按，都经过
  `InstanceDetailModel.delete()` 和 `InstanceDetailScreen.leaveDeletedInstance`）、事件流说它没了时 `forget(_:)` 五样一起删；
  注销账号成功后 `forgetAccount(_:)` 删掉注销前列表里的 Botin 的记录、主 Botin 也清掉（以前只清了头像外观）。退出登录不清。
  以后再加按 Botin 记在本机的东西，也加进 `BotinLocalData`。

#### 4.9.3 用量（55）

- **参考**：一张卡：“试用用量”+“N 天后结束”+ 细进度条 + 百分比。
- **ThinkTin 现在**：`.usage` → `Screens/Models/UsageScreen.swift`（7 / 30 / 90 天分段、总计、`UsageChart` 按天柱状图、按天 / 实例 /
  模型 / key 分组）+ `ViewModels/Models/UsageModel.swift`。ThinkTin 用用户自己的 key，没有平台额度和试用期。
- **要改**：换 insetGrouped；顶上加一组“今天”：每把设了每日上限的 key 一行 `Gauge(value:).gaugeStyle(.linearCapacity)`
  （已用 / `Credential.dailyTokenLimit`，已用量取 `usage(group: .credential, from: 东八区今天零点, timeZone: Asia/Shanghai)`——模型网关的每日上限按东八区切天
  （docs/llm-gateway.md），不能用手机本地的零点），没有上限的 key 不显示；其余保留。第 1 轮。

- **已做（2026-11-05，E 线，对过参考 55）**：insetGrouped `List`：最上面“今天”一组（`UsageModel.loadToday()`：key 列表 + 东八区今天按 key 的用量，
  每把设了上限的 key 一行 `UsageGaugeRow`：名字、右边“已用 / 上限”、系统 `Gauge(.linearCapacity)`、下面百分比，用满是警告色；没有上限的 key
  不列，一把都没有时整组不显示），然后透明行的时间范围分段、总计一行、“每天”的图、“明细”的分组分段和行（能点开的是系统 `NavigationLink`），
  空状态和拉不到是 `ContentUnavailableView`（`ModelsUnavailableView` 跟着换了）。
#### 4.9.4 订阅（56）

参考是一个网页容器（截图停在转圈）。ThinkTin 的 12.23 App 内购买等 1.1 拍板；做的话用 StoreKit 的 `SubscriptionStoreView` +
`.manageSubscriptionsSheet`，不用网页、不放站外购买引导（6.20）。

- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 56）**：`SubscriptionScreen`：先照参考在页面中间转圈（`SubscriptionModel.isLoading`，
  演示数据等 0.6 秒），再换成 insetGrouped `List`：每个方案一组（名字、价格、“当前方案”、一条条权益带勾，不是当前的方案底下全宽的“订阅”），
  最后“恢复购买”一组，脚注说是示例、以后走 App Store。方案是 `SubscriptionDemoData`（免费版是当前的，专业版“价格即将公布”），订阅、恢复购买弹
  “即将推出”（`SettingsComingSoon`）。接 StoreKit 时把 `SubscriptionModel` 的 `loader` 换成查商品，订阅换成 `SubscriptionStoreView` 或购买。

#### 4.9.5 保险箱（57、58）

- **布局**：压栈页“保险箱”，右上玻璃“+”；标题下一排筛选胶囊带计数；没有条目时一行卡片“还没有保存任何内容。”+ 脚注
  （实例能看到什么、看不到什么）；有条目时 insetGrouped 行（名字、用途）。
- **原生**：`List(.insetGrouped)`；`FilterChipBar`；行 `NavigationLink(value: AppRoute.vaultItem(id))` + `.swipeActions` 删除；
  空状态就是一行 `Text(...).foregroundStyle(.secondary)` + Section footer（参考不用大插画）；“+”只有一种类型时直接 `Button`，
  有多种类型时 `Menu`（58：登录信息、卡、联系信息）。
- **ThinkTin 现在**：`.vault` → `Screens/Vault/VaultScreens.swift`（`VaultScreen`：说明、“等你填写”的请求、条目、处理过的请求；
  “+”直接弹 `VaultItemEditorView`）+ `ViewModels/Vault/`。
- **要改**：换 `List`；筛选胶囊改成 ThinkTin 自己的：条目 / 等你填写 / 处理过的（只有一种条目类型，6.16）；脚注沿用
  “密码不会发给模型”。第 1 轮。

- **已做（2026-11-05，E 线，对过参考 57、58）**：insetGrouped `List`，标题“密码保险箱”，右上玻璃“+”（只有一种条目，直接压进新建表单，
  不弹菜单）；第一行 `FilterChipBar`：全部 / 条目 / 等你填写 / 处理过的（带数，`VaultModel.filter`、`count(of:)`、`shows(_:)`）；筛空了是一行灰字
  （`VaultText.empty`，全部和条目是“还没有保存任何内容。”）+ 脚注 `VaultText.footer`（Botin 看不到密码、只拿引用）；有的时候“等你填写”、
  条目（“N / 200 条”，名字 + 用途和能用的 Botin，左滑删除并确认）、“处理过的请求”几组，行是 `NavigationLink(value:)`。条目详情换成
  `List`（引用点了复制带触感、用途、账号、密码打点、能用的 Botin；时间；红字删除），找不到用 `ContentUnavailableView`。填写请求页换成
  `Form`（字段标签在上，底下突出的“存进保险箱”和“拒绝”）。

- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 57、58）**：“+”换成系统 `Menu`（参考 58：登录信息、卡、联系信息，`VaultItemKind`），
  登录信息照旧压进表单（满了、离线时那一项灰），卡、联系信息压进 4.9.7 的表单；筛选胶囊照参考 57 改成“全部 / 登录信息 / 支付 / 联系信息”，
  后面接 ThinkTin 的“等你填写 / 处理过的”（`VaultFilter.cards`、`.contacts` 的数总是 0，筛到它们时空状态的脚注说即将推出）。

#### 4.9.6 登录信息表单（59、99）

- **布局**：标题“新登录信息”，右上“保存”（没填好时灰）。几张卡：名称；网站（可以多个，“添加网站”，追加的行带“移除”）；
  账号 + 密码（密码行尾一个眼睛按钮）；提示（多行，脚注“告诉实例什么时候用这一条”）。字段是“标签在上、输入在下”。
- **原生**：`Form`；每行 `VStack(alignment: .leading) { Text(标签).font(.footnote).foregroundStyle(.secondary); TextField(…) }`；
  账号 `.textContentType(.username)`；密码在 `SecureField` 和 `TextField` 之间切换，眼睛是 `Button(.borderless)`，
  `.textContentType(.newPassword)`；提示 `TextField(axis: .vertical).lineLimit(4...8)`；保存 `.confirmationAction`。
- **ThinkTin 现在**：`VaultItemEditorView`（sheet，取消 / 保存；名字 = 引用名 `[vault:名字]`、用途、账号、密码、能用的实例；
  输入框是 `PlansTextField`）+ `VaultItemEditorModel`、`VaultRules`。
- **要改**：参考是在保险箱的导航栈里压栈（左上返回、右上“保存”），不是 sheet。改版后保险箱本身就在设置 sheet 里，建议照参考改成压栈
  （Vault 目录本地的 `.navigationDestination(isPresented:)`，不加路由），不再 sheet 叠 sheet；保存成功后返回上一页。字段对应：参考的“名称”= 引用名（规则提示保留，建好不能改）、
  “提示”= 用途、账号、密码（加眼睛，只显示正在输入的，存进去以后照样谁都看不到）；ThinkTin 的“能用的实例”放最后一组
  （`Toggle("所有实例")`，关掉后勾选列表）。网站字段要后端（6.16）。第 1 轮。

- **已做（2026-11-05，E 线，对过参考 59）**：新建和修改都在保险箱的导航栈里压栈（`navigationDestination(isPresented:)`），不再 sheet；
  `Form`，右上 `ConfirmButton("保存")`；“标签在上、输入在下”（`VaultLabeledField`）：名称（新建时；改的时候灰字，脚注说不能改）、
  账号 + 密码（行尾眼睛切换明文，`.borderless`）、提示（= 用途，多行 `lineLimit(4...8)`，脚注“告诉 Botin 什么时候用这一条。”和字数）、
  能用它的 Botin（`Toggle` 所有 Botin，关掉后勾选行）。压栈后用系统返回就是放弃，没有“有改动先确认”（以前 sheet 拦下滑）。网站要后端，没做。

- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 59、99）**：标题照参考改成“新登录信息”；名称下面加“网站”一组（`VaultWebsitesSection`：
  标签在上、输入在下，不止一个时标签那行右边“移除”，最后一行强调色“添加网站”，最多 5 个，网址不对时脚注标红，`VaultFieldList`、
  `VaultWebsiteRules`）。接口没有网站字段，填了不保存，脚注写着“网站即将推出，现在填了不会保存”。

#### 4.9.7 卡片和联系信息表单（60、94、95、96；61、97、98）

要后端，而且卡片牵涉代付和 PCI 合规（6.16），先不做。版式记下来备用：`Form` 左标签右输入（`LabeledContent`）；系统自动填充
（`.textContentType(.creditCardNumber / .creditCardExpiration / .creditCardSecurityCode / .telephoneNumber / .emailAddress / .fullStreetAddress / .postalCode …)`）；
可以重复的字段（电话、邮箱）是“字段行 + 行内移除 + 末尾‘添加’”；账单地址是 `Picker(.menu)`（已存的地址 / 新地址）；
底部全宽保存按钮。

- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 60、94–98、61）**：用户要先照参考排版，表单做了、保存弹“即将推出”。新卡片
  `VaultCardFormView`：`Form`，“标签在左、输入在右”的行（`VaultInlineField`，标签一样宽，输入框对齐）：卡号（每 4 位一格、Luhn 校验）、
  有效期（MM / YY、过期提示）、安全码（行尾眼睛）、持卡人姓名、备注名、账单地址（系统 `Picker(.menu)`：不填 / 新地址，选了新地址多一组地址，
  参考 95、96）；脚注“Botin 永远看不到你的完整卡号和安全码。”；“提示”一组；右上相机（扫描卡片，即将推出）；底部全宽“添加卡片”（没填好灰）。
  新建联系信息 `VaultContactFormView`：标签、姓名、手机（“添加电话”加“电话 2”，下面“设为首选”“移除”）、邮箱同样；脚注“至少要有地址、
  电话或邮箱中的一项”；“地址”一组；“提示”一组；底部“保存联系信息”。自动填充用系统的 `textContentType`（只在 iOS，`vaultFieldInput`）。
  校验在 ThinktinKit 的 `VaultCardDraft`、`VaultContactDraft`、`VaultFieldList`（`VaultExtraFormsTests`）。

#### 4.9.8 权限与规则（62、63、64、100）

- **参考**：自动审查总开关（带说明）；“始终询问”“无需询问即允许”两组，每组标题右边小玻璃胶囊“添加规则”；规则是一段自然语言；
  新建 / 编辑规则页：“适用于”多行输入（示例当占位）+ 脚注 + 底部“添加规则 / 保存规则”和文字“取消”，编辑页多一行红色“删除规则”。
- **原生**：`Form`；`Toggle { Text; Text(说明) }`；Section header 里 `HStack { VStack { 标题; 说明 }; Button("添加规则").buttonStyle(.glass).controlSize(.small) }`；
  规则行 `NavigationLink` + `.swipeActions` 删除；删除 `Button(role: .destructive)` + `.confirmationDialog`。
- **ThinkTin 现在**：没有。相关的有审批中心（`Screens/Approvals/ApprovalScreens.swift`，逐条批准）、计划的预授权工具
  （`PlanPolicy.preauthorizedTools`，按计划、按工具种类）、电脑的能力令牌。
- **要改**：第 3 轮或不做（6.15）。第 1 轮设置里这一行叫“审批”，进审批中心。

- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 62、63、64、100）**：用户要先照参考排版，规则是本地的演示数据（`PermissionsDemoData`：
  自动审查开着，“始终询问”没有规则，“无需询问即允许”3 条 ThinkTin 的例子），开关、保存、删除弹“即将推出”。`PermissionsScreen`：
  insetGrouped `List`：`Toggle { 自动审查; 说明 }`；两组规则，组标题左边名字和说明、右边小玻璃胶囊“添加规则”（`PermissionRuleSectionHeader`），
  规则一句一行（点了压进修改页，左滑删除并确认），没有规则是灰字“暂无规则”；ThinkTin 多一组进审批中心（逐条批准照旧），脚注说电脑上的高危操作
  规则管不到、现在是示例。新建 / 编辑规则 `PermissionRuleEditorScreen`（页面里 `navigationDestination(item:)` 压栈）：“适用于”多行输入
  （占位按组不同：参考 63 是始终询问的、100 是自动允许的）+ 脚注和字数；编辑多一组红字“删除规则”；底部浮着全宽“添加规则 / 保存规则”和一行
  “取消”（`SettingsBottomActions`）。

#### 4.9.9 登录设备和设备详情（66、67、68、69）

- **布局**：列表 insetGrouped 一组：状态点 + 设备图标 + 名字 + 副标题（“iOS · 这台设备”/“电脑 · 上次打开于 …”）+ chevron；
  点进详情：名称行（点了 alert 改名）、状态行；电脑的详情多一组配对和授权、单独一组红字“移除电脑”。参考电脑详情里还有
  “在此设备上执行：始终允许 / 每次询问 / 从不允许”（6.20）。
- **原生**：`List(.insetGrouped)`；`NavigationLink`；`.refreshable`；`.swipeActions` 下线；改名 `.alert` + `TextField`；
  `Picker(.inline)`；移除 `Button(role: .destructive)` + `.confirmationDialog`。
- **ThinkTin 现在**：`.devices` → `Screens/Account/DevicesView.swift`（`DevicesScreen`：本机、其他设备两组，行内“下线”，底部
  `PillButton`“下线其他设备”，再下面嵌着 `ComputerLinkSection`）+ `DevicesModel`、`ComputerLinkModel`；`DeviceInfo` 有
  `platform`、`name`、`isCurrent`、`isOnline`、`lastSeenAt`。
- **要改**：拆成列表 + 详情（Account 目录本地 `NavigationLink`，不加路由）；行内“下线”挪进详情和左滑；配对、授权、解除配对挪进
  电脑详情；“下线其他设备”放列表底部单独一组。改名要后端（6.20）。第 1 轮。

- **已做（2026-11-05，E 线，对过参考 66、67、69）**：列表是一组 insetGrouped 行（`DeviceRow`：状态点（本机、在线的电脑亮）、平台图标、名字、
  “iOS · 本机”/“电脑 · 在线”/“Android · 最近活跃 …”，`DeviceInfo.listSubtitle`），本机在前，点进 `DeviceDetailScreen`（本地压栈），别的设备
  左滑“下线”；有别的设备时单独一组红字“下线其他设备”（sheet 换成 `Form` + 浮动的红色整宽按钮 + `CloseButton`）；签名密钥失效、签不了、出错时
  多一组电脑的说明和“生成新密钥”（`ComputerLinkStatusSection`）。详情：名称（不能点，改名要后端）、状态点 + 状态、类别、登录时间；电脑多一组
  “在这台电脑上执行”（`ComputerDeviceSections`：配对状态、配对 / 授权目录和应用 / 现有授权左滑吊销 / 重新配对 / 红字解除配对，脚注是签名说明）；
  最后红字“下线这台设备”（本机“下线本机”）。参考的三档执行策略不做（6.20）。`ComputerLinkSection` 删了。
- **审查修正（2026-11-05）**：还没有电脑登录这个账号时，设备列表下面有一组“电脑”：一行“在电脑上装好 ThinkTin 并登录后，这里会出现”
  （`ComputerLinkText.noComputers`）+ 配对说明的脚注（`ComputerLinkStatusSection(hasComputer:)`）；以前这时整页看不到 12.9 从哪儿开始。
  只弹确认的左滑“下线”不用 `.destructive`（红色 `tint`）。
- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 67、68）**：设备详情的名称行带箭头（`DeviceDetailScreen.nameRow`），点了弹系统的改名
  弹窗（`.alert` + `TextField`：标题“重命名 …”、取消 / 保存，空名字不能保存）；没有改名接口，保存弹“即将推出”。

#### 4.9.10 导入记忆（71）

参考：第 1 步复制一段导出提示词去别的 AI 助手里跑，第 2 步把结果粘贴回来，“添加到记忆”。ThinkTin 没有写入实例记忆的接口，
各 agent 的记忆机制也不一样（6.20），先不做。版式备用：`Form` 两个 Section（header 写步骤）、`Text(...).textSelection(.enabled)`、
`Button("复制提示词")`、`PasteButton`、多行 `TextField`、底部全宽按钮。

- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 71）**：`ImportMemoryScreen`：`Form` 两组，组标题写步骤：① 导出提示词
  （ThinkTin 自己写的，中英文各一份，`ImportMemoryText.exportPrompt`，最多露 8 行、能选中）+ “复制提示词”（复制后换“已复制”，带触感）；
  ② 粘贴框（多行）+ ThinkTin 多的一行“添加到”（系统 `Picker(.menu)` 选 Botin，各 Botin 的记忆分开；没有 Botin 时写“还没有 Botin”）；
  底部全宽“添加到记忆”（没粘贴、没选 Botin 时灰）。没有写记忆的接口，点了弹“即将推出”，内容不离开设备。

#### 4.9.11 外观（72）

- **参考**：两排大方块：跟随系统 / 浅色 / 深色；深色底色：黑色 / 跟随 Bot 颜色。选中的实心底、标签加粗。
- **原生**：`LazyVGrid` 里 `Button`，选中 `.buttonStyle(.glassProminent)`、没选中 `.glass`，`.buttonBorderShape(.roundedRectangle(radius: 16))`，
  `.accessibilityAddTraits(.isSelected)`，`.sensoryFeedback(.selection, trigger:)`；更省事的是 `Picker(.inline)`。
- **ThinkTin 现在**：`Screens/Settings/DisplaySettingsViews.swift` 的 `AppearanceSettingsView`（`SettingsOptionRow` 打勾单选，
  “只改这台设备”脚注）+ `SettingsPreferences.AppearancePreference`。
- **要改**：第 1 轮换方块（第一排）；第二排的“纯黑”第 2 轮（`SettingsPreferences` 加深色底色、Theme 加纯黑这套值），
  “跟随实例颜色”跟着头像走（6.9、6.22）。

- **已做（2026-11-05，E 线）**：一排三个方块（`AppearanceTile`：圆角 16、高 64 的系统按钮，选中 `glassButtonStyle(.prominent)`、没选中
  `.regular`，下面名字选中加粗），脚注“只改这台设备”，选中有选择触感。第二排（深色底色：纯黑）没做：纯黑要 Theme 的动态颜色按偏好换值，
  改了要所有页面重新取色，排第 2 轮。
#### 4.9.12 语言（73）

- **参考**：insetGrouped 一组纯文字行（各语言用自己的文字写），选中行右边打勾，选了立即生效。
- **原生**：`Picker(selection:) { … } label: { EmptyView() }.pickerStyle(.inline)`；同步中、失败的状态放 Section footer。
- **ThinkTin 现在**：`LanguageSettingsView` + `LanguageSettingsModel`（跟随系统 / 中文 / English，并同步服务端的 locale）。
- **要改**：换 inline `Picker`，去掉行图标，保留“正在同步”“同步失败可重试”。加不加别的语言不在这次范围。第 1 轮。

- **已做（2026-11-05，E 线）**：一组系统 `Picker(.inline)`（跟随系统（中文）/ 中文 / English，没有行图标），同步中、没同步上的说明在脚注里，
  失败的 `ErrorBanner` 单独一组可以重试。
#### 4.9.13 触感反馈（74）

参考是一个子页里一个开关加脚注。建议不单开页面，设置根页直接一行 `Toggle`。`SettingsPreferences` 加 `hapticsEnabled`（默认开），
各处 `.sensoryFeedback(trigger:) { _, _ in enabled ? .selection : nil }`。先定哪些操作带触感：发送、批准 / 拒绝审批、复制、
左滑、长按（6.22）。代码里现在没有任何触感。第 2 轮。

- **已做（2026-11-05，E 线，照参考 74 做成子页而不是根页的开关）**：`SettingsPreferences.hapticsEnabled`（默认开，键
  `cn.thinktin.settings.haptics`，关掉才存 false），`.settingsPreferences()` 放进环境 `\.hapticsEnabled`；界面里要震的地方统一用
  `appFeedback(_:trigger:)`（`Design/Haptics.swift`，关了就不震），原来的 5 处 `.sensoryFeedback`（筛选胶囊、复制运行 ID、存相册、头像挑选、
  复制 Botin ID）都换了，外观、语言选中也加了选择触感。根页一行“触感反馈 开启 ›”进 `HapticsSettingsView`（`Toggle` + 脚注）。
#### 4.9.14 发送反馈（76、77）

- **参考**：压栈页“发送反馈”：多行输入卡片 + 脚注；“和哪个 Bot 有关”一行 `Picker(.menu)`（无 / 各 Bot）；底部全宽“发送反馈”，空时禁用。
- **ThinkTin 现在**：没有通用反馈接口，只有针对某次运行或产出物的举报（`reportContent`）。
- **要改**：第 3 轮（6.20）；接口有了以后照上面的版式做，“和哪个实例有关”的选项来自 `AppModel.instances`。过渡可以先放一个
  `mailto:` 链接。

- **已做（2026-11-05，第 2 轮 r2/settings，对过参考 76、77）**：`FeedbackScreen`：`Form`：多行输入框 + 脚注（会用邮件发、带上版本）；
  组标题“你的问题和某个 Botin 有关吗？”下面系统 `Picker(.menu)`“Botin 无 ⌃⌄”（无 + 各个 Botin，`SettingsBotinPicker`）；底部全宽
  “发送反馈”（空的时候灰）。按 6.20 B 先用邮件：`FeedbackDraft.mailtoURL` 拼 `mailto:`（主题“ThinkTin 反馈”，正文末尾 App 版本、系统、
  选的 Botin 的名字和 id），`openURL` 交给系统邮件 App，打不开时提示邮箱、可以复制。反馈邮箱 `feedback@thinktin.cn` 是占位，上线前确认。

## 5. 对照表

状态的意思：**只改界面**＝功能和数据都有，只换版式和控件；**部分有**＝主体有，缺的部分要么纯客户端补、要么等后端；
**纯客户端能做**＝ThinkTin 没有，但不用后端就能做（多数是存在本机）；**要后端**＝要服务端和 client-core 新接口；
**不适用**＝ThinkTin 不做。轮次见第 7 节（0 底座、1 一一对应、2 纯客户端新功能、3 要后端）。

| 状态 | 张数 |
|---|---|
| 只改界面 | 6 |
| 部分有 | 35 |
| 纯客户端能做 | 18 |
| 要后端 | 50 |
| 不适用 | 11 |
| 合计 | 120 |

| 编号 | 参考页面 | ThinkTin 功能 | 现有代码 | 状态 | 轮次 | 规范 |
|---|---|---|---|---|---|---|
| 1 | 首页 Bot 列表 | 首页实例列表 | `Shell/Home/HomeScreen.swift`、`HomeInstanceRow.swift`（2026-11-05 照参考量过行高、边距） | 部分有 | 0–1 | 4.2.1 |
| 2 | 对话主页面 | 对话 | `Conversation/ConversationScreen.swift`、`MessageViews.swift`、`Components/ComposerBar.swift` | 只改界面 | 1 | 4.3.1 |
| 3 | 对话更多菜单 | 对话“…”菜单 | `ConversationScreen.swift` 的 `Menu` | 部分有 | 1 | 4.3.2 |
| 4 | 聊天内查找 | 对话内查找 | 无 | 纯客户端能做 | 2 | 4.3.3 |
| 5 | 查找无匹配 | 对话内查找 | 无 | 纯客户端能做 | 2 | 4.3.3 |
| 6 | 消息长按菜单 | 消息长按菜单 | `MessageViews.swift`（`MessageMenu`）、`ContentReportSheet.swift` | 部分有 | 1；表情、未读 3 | 4.3.4 |
| 7 | 引用回复输入框 | 引用回复 | 无 | 纯客户端能做 | 2 | 4.3.5 |
| 8 | 附件菜单 | 运行附件（12.22） | 无（没有上传接口） | 要后端 | 3 | 4.3.6 |
| 9 | Bot 资料 | 实例资料 | `Agents/InstanceDetailScreen.swift`、`InstanceDetailModel` | 部分有 | 1；通知 3 | 4.4.1 |
| 10 | 资料更多菜单 | 资料页“…”菜单 | `InstanceDetailScreen.swift` 的 `Menu` | 部分有 | 1 | 4.4.2 |
| 11 | 选择主 Bot 空状态 | 主实例（无） | 无（版式借给 `NewTaskSheet`） | 不适用 | 不做 | 4.4.5 |
| 12 | 编辑 Bot | 编辑实例 | `InstanceEditScreen`（2026-11-05，以前是 `InstanceRenameSheet`）、`renameInstance` | 部分有 | 1（已做） | 4.4.3 |
| 13 | 语音选择（上） | 语音通话（无） | `InstanceEditScreen` 的“语音通话”组、`BotinVoiceStore`（2026-11-05） | 不适用 | 页面已做（演示，本机存，r2/botin） | 4.4.3 |
| 14 | 语音选择（中） | 语音通话（无） | 同 13 | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 15 | 语音选择（下） | 语音通话（无） | 同 13 | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 16 | 语速选择 | 语音通话（无） | 同 13（`BotinVoiceSpeed`） | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 17 | 语言选择 | 语音通话（无） | 同 13（`BotinVoiceDemoData.languages`） | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 18 | 头像形状与颜色 | 实例头像 | `Components/InstanceAvatar.swift`、`AvatarShapes.swift` | 纯客户端能做 | 新建时挑已做（本机，2026-11-05）；改头像 2 / 同步 3 | 4.4.4 |
| 19 | 生成头像 | 实例头像（AI 生成） | `InstanceAvatarScreen` 的“生成”分段（2026-11-05） | 要后端 | 页面已做，点了“即将推出”（r2/botin） | 4.4.4 |
| 20 | 上传头像入口 | 实例头像（上传） | `InstanceAvatarScreen` 的“上传”分段（2026-11-05） | 要后端 | 页面已做，点了“即将推出”（r2/botin） | 4.4.4 |
| 21 | 定时任务空状态 | 实例的计划 | `Plans/PlanListScreen.swift`、`PlanListModel` | 只改界面 | 1（已做） | 4.5.1 |
| 22 | 资料库全部 | 产出物 | `Artifacts/ArtifactScreens.swift`、`ArtifactLibraryModel` | 部分有 | 1（已做）；链接不做 | 4.5.2 |
| 23 | 资料库媒体 | 产出物按类型筛选 | `ArtifactScreens.swift`、`ArtifactFiles.category` | 部分有 | 已做（2026-11-05，提前到第 1 轮） | 4.5.2 |
| 24 | 图片预览 | 图片全屏查看 | `ArtifactImageViewer`（2026-11-05） | 部分有 | 已做（提前到第 1 轮） | 4.5.3 |
| 25 | 图片操作菜单 | 分享、存相册（转发） | `ArtifactImageViewer`（`ShareLink`、相册的“添加”） | 部分有 | 已做（提前到第 1 轮）；转发不做 | 4.5.3 |
| 26 | 资料库链接 | 链接分类 | 无数据来源 | 要后端 | 不做（6.19） | 4.5.2 |
| 27 | 电脑启动页面 | 观看与接管 | `InstanceScreenView`、`.instanceScreen`（2026-11-05，演示；docs/browser.md 只有设计） | 要后端 | 版式已做（r2/botin）/ 画面 3 | 4.6.2 |
| 28 | 电脑操作说明 | 使用说明 | `InstanceScreenHelpSheet`（2026-11-05） | 纯客户端能做 | 已做（r2/botin） | 4.6.3 |
| 29 | 电脑查看模式 | 观看 | `InstanceScreenView`（占位画面） | 要后端 | 版式已做（r2/botin）/ 画面 3 | 4.6.2 |
| 30 | 电脑控制模式 | 接管 | `InstanceScreenView`（控制时的底部工具栏） | 要后端 | 版式已做（r2/botin）/ 控制 3 | 4.6.2 |
| 31 | 电脑控制更多菜单 | 触控板模式 | `InstanceScreenView` 的“…”（触控板模式、交还给 Botin） | 要后端 | 版式已做（r2/botin）/ 3 | 4.6.2 |
| 32 | 首页 Bot 长按菜单 | 实例长按菜单 | `Shell/Home/HomeInstanceActions.swift`、ThinktinKit `HomeInstanceMenu`（2026-11-05 做了） | 部分有 | 1；置顶隐藏 2 | 4.2.2 |
| 33 | 长按更多子菜单 | 复制 Botin ID、删除 | `HomeInstanceMenu.more`（2026-11-05 做了） | 纯客户端能做 | 1 | 4.2.2 |
| 34 | 创建新 Bot 空表单 | 新建 Botin | `Agents/AdoptAgentSheet.swift`、`AdoptionModel` | 部分有 | 已做（2026-11-05，含头像，本机） | 4.7.1 |
| 35 | 创建表单输入焦点 | 领养新实例 | `AdoptAgentSheet.swift` | 部分有 | 1 | 4.7.1 |
| 36 | 连接应用目录 | 连接汇总页 / 第三方连接器 | 分散：`ImChannelScreens`、`CredentialsScreen`、`ComputerLinkViews`、`VaultScreens` | 要后端 | 2（汇总）/ 3；版式已做（r2/connections） | 4.8.1 |
| 37 | 已安装插件列表 | 已连接列表 | 无 | 要后端 | 2（汇总）/ 3；版式已做（r2/connections） | 4.8.2 |
| 38 | 已连接插件详情 | 连接器详情 | 无（版式可借给 key、IM 详情） | 要后端 | 3；版式已做（r2/connections） | 4.8.3 |
| 39 | 插件管理菜单 | 断开连接器 | 无 | 要后端 | 3；版式已做（r2/connections） | 4.8.3 |
| 40 | iPhone 连接能力 | 手机当工具宿主 | 无 | 要后端 | 待定（6.12）；版式已做（r2/connections） | 4.8.1 |
| 41 | 密码管理器分类 | 保险箱入口 | `Vault/VaultScreens.swift` | 部分有 | 2；版式已做（r2/connections） | 4.8.1 |
| 42 | 效率应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 43 | 通信应用分类 | IM 渠道 | `ImChannels/ImChannelScreens.swift` | 部分有 | 2；版式已做（r2/connections） | 4.8.1 |
| 44 | 设计应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 45 | 代码应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 46 | 数据应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 47 | 销售应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 48 | 营销应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 49 | 财务应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 50 | 研究应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 51 | 支持应用分类 | 第三方连接器 | 无 | 要后端 | 3 / 待定；版式已做（r2/connections） | 4.8.1 |
| 52 | 未连接插件详情 | 连接器详情（版式借给 agent 详情） | `Agents/AgentDetailScreen.swift`（借版式） | 要后端 | 3；版式 2；版式已做（r2/connections） | 4.8.3 |
| 53 | 全局设置上半 | 设置根页 | `Settings/SettingsScreen.swift`、`SettingsModel` | 部分有 | 1（已做，E 线） | 4.9.1 |
| 54 | 账户管理 | 账号 | `Account/AccountView.swift`、`DeleteAccountView.swift` | 部分有 | 1；多账户不做（已做，E 线） | 4.9.2 |
| 55 | 用量 | 用量 | `Models/UsageScreen.swift`、`UsageModel` | 只改界面 | 1（已做，E 线） | 4.9.3 |
| 56 | 订阅加载状态 | App 内购买（12.23） | `Settings/SubscriptionScreen.swift`、`SubscriptionDemoData`（演示方案） | 要后端 | 版式已做（r2/settings）；购买待定 | 4.9.4 |
| 57 | 保管库空状态 | 保险箱 | `Vault/VaultScreens.swift`（`VaultScreen`） | 只改界面 | 1（已做，E 线） | 4.9.5 |
| 58 | 保管库新增菜单 | 新建保险箱条目 | `VaultScreen` 的“+”菜单（`VaultItemKind`） | 部分有 | 1（已做，E 线）；三种的菜单和胶囊已做（r2/settings），卡和联系信息存要 3 | 4.9.5 |
| 59 | 新增登录信息 | 登录信息表单 | `VaultItemEditorView`、`VaultItemEditorModel` | 部分有 | 1；网站 3（已做，E 线） | 4.9.6 |
| 60 | 新增卡片 | 卡片条目 | `Vault/VaultExtraFormViews.swift`（`VaultCardFormView`）、`VaultCardDraft` | 要后端 | 表单已做（r2/settings）；保存待定（6.16） | 4.9.7 |
| 61 | 新增联系信息 | 联系信息条目 | `VaultContactFormView`、`VaultContactDraft` | 要后端 | 表单已做（r2/settings）；保存待定（6.16） | 4.9.7 |
| 62 | 权限与规则列表 | 自然语言权限规则 | `Settings/PermissionsScreens.swift`、`PermissionsDemoData`（演示规则）；审批中心照旧 | 要后端 | 版式已做（r2/settings）；规则后端待定（6.15） | 4.9.8 |
| 63 | 新增规则 | 自然语言权限规则 | `PermissionRuleEditorScreen`、`PermissionRuleDraft` | 要后端 | 版式已做（r2/settings）；保存待定 | 4.9.8 |
| 64 | 编辑规则 | 自然语言权限规则 | `PermissionRuleEditorScreen` | 要后端 | 版式已做（r2/settings）；保存、删除待定 | 4.9.8 |
| 65 | Bot 电脑设置 | 工作区（重置、磁盘） | `InstanceWorkspaceScreen`（状态说明、版本，2026-11-05） | 要后端 | 1（工作区页，已做）/ 3 | 4.6.1 |
| 66 | 设备列表 | 登录设备 | `Account/DevicesView.swift`、`DevicesModel` | 只改界面 | 1（已做，E 线） | 4.9.9 |
| 67 | 手机设备详情 | 设备详情 | `DevicesView` 的 `DeviceRow` | 部分有 | 1；改名 3（已做，E 线） | 4.9.9 |
| 68 | 设备重命名弹窗 | 设备改名 | `DeviceDetailScreen` 的改名 `.alert`（没有改名接口） | 要后端 | 弹窗已做（r2/settings）；保存 3 | 4.9.9 |
| 69 | 电脑详情与执行权限 | 电脑详情、配对、授权 | `Computer/ComputerLinkViews.swift`、`ComputerLinkModel` | 部分有 | 1；三档策略不做（已做，E 线） | 4.9.9 |
| 70 | 全局设置中下 | 设置根页 | `SettingsScreen`、`DisplaySettingsViews.swift` | 部分有 | 1；触感 2（已做，E 线） | 4.9.1 |
| 71 | 导入记忆 | 记忆导入 | `Settings/ImportMemoryScreen.swift`、`ImportMemoryDraft` | 要后端 | 版式已做（r2/settings）；写记忆待定（6.20） | 4.9.10 |
| 72 | 外观设置 | 外观 | `DisplaySettingsViews.swift`（`AppearanceSettingsView`） | 部分有 | 1；纯黑 2（第一排已做，E 线） | 4.9.11 |
| 73 | 应用语言设置 | 界面语言 | `DisplaySettingsViews.swift`（`LanguageSettingsView`） | 只改界面 | 1（已做，E 线） | 4.9.12 |
| 74 | 触感反馈设置 | 触感开关 | 无 | 纯客户端能做 | 2（已做，E 线，照参考做成子页） | 4.9.13 |
| 75 | 全局设置底部与版本 | 设置根页底部、关于 | `SettingsScreen`、`AboutScreen.swift` | 部分有 | 1；反馈 3（已做，E 线） | 4.9.1 |
| 76 | 反馈空表单 | 发送反馈 | `Settings/FeedbackScreen.swift`、`FeedbackDraft`（邮件） | 部分有 | 已做（r2/settings，用邮件发，6.20 B）；接口 3 | 4.9.14 |
| 77 | 反馈关联 Bot 菜单 | 发送反馈 | `SettingsBotinPicker` | 部分有 | 已做（r2/settings） | 4.9.14 |
| 78 | 全局搜索 | 首页搜索 | `Search/SearchScreen.swift`（`SearchResultsView`）、`SearchModel` | 部分有 | 已做（2026-11-05，含筛选） | 4.2.4 |
| 79 | 搜索消息筛选空状态 | 搜索筛选 | `SearchResultsView` | 纯客户端能做 | 已做（提前到第 1 轮） | 4.2.4 |
| 80 | 搜索消息结果 | 搜运行（谁发给谁） | `SearchModel`（任务、摘要） | 部分有 | 谁发给谁已做（提前到第 1 轮）；本机缓存的回复正文 2；缓存外全文 3 | 4.2.4 |
| 81 | 资料库底部展开入口 | 产出物分页 | `ArtifactLibraryModel`（只有 `limit`） | 部分有 | 1（本地折叠，已做）/ 3 | 4.5.2 |
| 82 | 资料库展开后 | 产出物分页 | 同上 | 部分有 | 3 | 4.5.2 |
| 83 | 资料库媒体完整 | 产出物类型筛选 | `ArtifactScreens.swift`、`ArtifactFiles.category` | 部分有 | 已做（提前到第 1 轮） | 4.5.2 |
| 84 | 资料库链接完整 | 链接分类 | 无 | 要后端 | 不做（6.19） | 4.5.2 |
| 85 | 语音选择完整底部 | 语音通话（无） | 同 13 | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 86 | 语言选择中段一 | 语音通话（无） | 同 17 | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 87 | 语言选择中段二 | 语音通话（无） | 同 17 | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 88 | 语言选择完整底部 | 语音通话（无） | 同 17 | 不适用 | 页面已做（演示，r2/botin） | 4.4.3 |
| 89 | 电脑剪贴板菜单 | 接管时的剪贴板 | `InstanceScreenView` 的剪贴板菜单（点了“即将推出”） | 要后端 | 版式已做（r2/botin）/ 3 | 4.6.2 |
| 90 | 更多表情选择器 | 消息表情回应 | 无 | 要后端 | 不做（6.11） | 4.3.4 |
| 91 | 新建分组名称弹窗 | 首页分组 | 无 | 纯客户端能做 | 待定（6.10） | 4.7.2 |
| 92 | 分组管理菜单 | 首页分组 | 无 | 纯客户端能做 | 待定 | 4.7.2 |
| 93 | 分组删除确认 | 首页分组 | 无 | 纯客户端能做 | 待定 | 4.7.2 |
| 94 | 卡片账单地址菜单 | 卡片条目 | `VaultCardFormView` | 要后端 | 表单已做（r2/settings）；保存待定 | 4.9.7 |
| 95 | 卡片新地址 | 卡片条目 | `VaultCardFormView` | 要后端 | 表单已做（r2/settings）；保存待定 | 4.9.7 |
| 96 | 卡片完整字段 | 卡片条目 | `VaultCardFormView` | 要后端 | 表单已做（r2/settings）；保存待定 | 4.9.7 |
| 97 | 联系信息追加电话邮箱 | 联系信息条目 | `VaultContactFormView` | 要后端 | 表单已做（r2/settings）；保存待定 | 4.9.7 |
| 98 | 联系信息地址与底部 | 联系信息条目 | `VaultContactFormView` | 要后端 | 表单已做（r2/settings）；保存待定 | 4.9.7 |
| 99 | 登录信息追加网站 | 登录信息表单 | `VaultItemEditorView` + `VaultWebsitesSection` | 部分有 | 1；网站的行已做（r2/settings，不保存），存要 3 | 4.9.6 |
| 100 | 新增自动允许规则 | 自然语言权限规则 | `PermissionRuleEditorScreen`（按组换占位） | 要后端 | 版式已做（r2/settings）；保存待定 | 4.9.8 |
| 101 | 推荐插件目录入口 | 第三方目录（行版式借给 agent 目录） | `Agents/AgentCatalogScreen.swift`（借版式） | 要后端 | 3；版式 1；版式已做（r2/connections） | 4.8.4 |
| 102 | 推荐目录中段 | 第三方目录 | 无 | 要后端 | 3；版式已做（r2/connections） | 4.8.4 |
| 103 | 推荐目录底部 | 第三方目录 | 无 | 要后端 | 3；版式已做（r2/connections） | 4.8.4 |
| 104 | 精选插件完整目录 | 第三方目录 | 无 | 要后端 | 3；版式已做（r2/connections） | 4.8.4 |
| 105 | 含技能插件详情 | 连接器详情 | 无 | 要后端 | 3；版式已做（r2/connections） | 4.8.3 |
| 106 | 插件详情中等高度 | 连接器详情 | 无 | 要后端 | 3；版式已做（r2/connections） | 4.8.3 |
| 107 | 多连接器插件详情 | 连接器详情 | 无 | 要后端 | 3；版式已做（r2/connections） | 4.8.3 |
| 108 | 登录方式选择 | 登录（用户自己设计） | `Account/SignInFlow.swift` | 不适用 | 不做 | 4.1.2 |
| 109 | 开机启动页 | 启动屏 | `project.yml` 的 `UILaunchScreen: {}` | 纯客户端能做 | 0 | 4.1.1 |
| 110 | 列表左滑快捷操作 | 置顶、隐藏 | `HomeInstanceSwipeButtons`、`InstancePreferencesStore`（2026-11-05 做了） | 纯客户端能做 | 2 | 4.2.1 |
| 111 | 置顶后的首页 | 置顶区 | `Shell/Home/PinnedInstancesGrid.swift`（2026-11-05 做了） | 纯客户端能做 | 2 | 4.2.1 |
| 112 | 置顶项的管理菜单 | 实例长按菜单 | 同 32，“置顶”换成“取消置顶”（2026-11-05 做了） | 部分有 | 1；置顶隐藏 2 | 4.2.2 |
| 113 | 全部隐藏后的空状态 | 首页空状态 | `HomeAllHiddenView`、`HomePlaceholder.allHidden`（2026-11-05 做了） | 纯客户端能做 | 2 | 4.2.1 |
| 114 | 已隐藏对话管理页 | 已隐藏的 Botin | `Shell/Home/HiddenInstancesScreen.swift`（2026-11-05 做了） | 纯客户端能做 | 2 | 4.2.3 |
| 115 | 隐藏对话说明 | 隐藏说明 | `HidingHelpSheet`、`HomeText.hidingFacts`（2026-11-05 做了） | 纯客户端能做 | 2 | 4.2.3 |
| 116 | 取消隐藏后的空状态 | 已隐藏的 Botin（空） | `HiddenInstancesScreen` 的空状态（2026-11-05 做了） | 纯客户端能做 | 2 | 4.2.3 |
| 117 | 创建表单（填好） | 新建 Botin | `AdoptAgentSheet.swift` | 部分有 | 已做（2026-11-05，含头像，本机） | 4.7.1 |
| 118 | 新 Bot 欢迎与引导卡 | 对话首次状态 | `ConversationScreen`（空状态）、`Onboarding/` | 部分有 | 2 | 4.3.1 |
| 119 | 两个都没置顶的列表 | 首页列表 | `HomeInstanceRow`（2026-11-05 照参考量过；预览是缓存里的最后一条） | 部分有 | 1 | 4.2.1 |
| 120 | 置顶和普通同屏 | 首页置顶 + 列表 | `PinnedInstancesGrid` + `HomeInstanceRow`（2026-11-05 做了） | 部分有 | 2 | 4.2.1 |

## 6. 要用户拍板的事

按重要程度排。**6.1–6.6 是第 1 轮开工前必须定的**（牵涉导航和令牌，定了以后再改代价大）；其余可以边做边定，没定的先按“建议”做或先不做。

| 编号 | 事项 | 建议（一句话） | 影响 |
|---|---|---|---|
| 6.1 | 首页和导航结构 | 照参考改成“实例列表为根 + 压栈”，去掉抽屉；抽屉的 6 个入口放首页左下“工作台”菜单 | 第 0、1 轮 |
| 6.2 | 颜色、气泡、字体 | 底色和卡片改中性灰，强调色保留橙色，agent 回复加灰气泡，字体全用系统的 | 第 0 轮 |
| 6.3 | 最低系统版本 | 保持 iOS 17，iOS 26 的新接口集中包一层回退 | 第 0 轮 |
| 6.4 | “+”新建 Botin 流程 | **已定**：“+”直接弹“新建 Botin”表单，起名字、选一个引擎，许可说明放脚注 | 第 1 轮 |
| 6.5 | 设置用 sheet 还是压栈 | 照参考用 sheet | 第 0 轮 |
| 6.6 | 叫 Bot 还是实例 | **已定（2026-11-05）**：界面上叫 Botin，agent 只以“引擎”出现；代码标识符不改 | 全部 |
| 6.7 | 首页列表的预览 | 先显示状态，没有状态时显示最近一次运行的摘要或任务 | 第 1 轮 |
| 6.8 | 资料页的“电脑”行、远程画面 | 改叫“工作区”，进实例沙箱页；观看接管等后端 | 第 1、3 轮 |
| 6.9 | 头像和实例颜色 | 先做首字头像按名字取色；形状颜色等后端字段；生成、上传不做（2026-11-05：新建时挑形状颜色、先存本机，A） | 第 1–3 轮 |
| 6.10 | 置顶、隐藏、分组、未读、主实例 | 置顶、隐藏本机存，第 2 轮做；分组、未读、主实例先不做 | 第 2 轮 |
| 6.11 | 表情回应、标为未读、引用回复 | 表情和未读不做；引用拼成 Markdown 引用块，纯客户端 | 第 2 轮 |
| 6.12 | 连接应用 / 插件目录 | 先做“连接”汇总页（只放已有的接入）；第三方和“此 iPhone”单独立项 | 第 2 轮 |
| 6.13 | 附件 | 等 12.22 后端，之前输入框不放“+” | 第 3 轮 |
| 6.14 | 按实例的通知开关 | 等后端；之前资料页不放 | 第 3 轮 |
| 6.15 | 自然语言权限规则 | 先不做，设置里这行进审批中心；要做先过安全评审 | 待定 |
| 6.16 | 保险箱的卡片、联系信息、网站 | 网站字段做；卡片不做；联系信息先不做 | 第 3 轮 |
| 6.17 | 工作区重置、磁盘、时区 | 重置和磁盘等后端；时区不做 | 第 3 轮 |
| 6.18 | 新实例的欢迎卡 | 客户端画静态卡，先引导配模型，再给示例任务 | 第 2 轮 |
| 6.19 | 产出物的链接、缩略图、分页 | 不做链接；缩略图客户端做；分页先本地折叠 | 第 2 轮 |
| 6.20 | 订阅、导入记忆、反馈、设备改名、多账户 | 订阅等 1.1；导入记忆、多账户不做；反馈先用邮件；设备改名做 | 第 3 轮 |
| 6.21 | 分享（实例、模板） | 不放分享 | — |
| 6.22 | 纯黑外观、跟随实例颜色、触感 | 纯黑和触感做；跟随实例颜色不做 | 第 2 轮 |
| 6.23 | 语音（通话、音色、语速、语言） | 不做，用键盘自带的听写 | — |
| 6.24 | 搜索的筛选类型 | 全部 / 消息 / 实例 / 收件箱 / 计划 / 产出物，不要“群聊” | 第 2 轮 |

### 6.1 首页和导航结构

- **参考 App**：首页就是 Bot 列表；点一行压栈进对话；左上账号头像进设置，右上“+”新建，左下“连接应用”，底部搜索。
- **ThinkTin 现在**：根是当前实例的对话；左侧抽屉放新任务、搜索、收件箱、审批、进行中、计划、团队、产出物（后 6 个带角标）、
  实例列表、设置；标题上是实例切换菜单。
- **可选**
  - A：照参考改，实例列表为根，去掉抽屉和切换菜单。
  - B：保留抽屉，只换控件样式（和参考的布局差得最多）。
  - C：列表为根，同时保留抽屉（两套入口，乱）。
- **抽屉的 6 个入口放哪（选 A 时）**
  - A1：首页左下“工作台”菜单（总角标；菜单项带“3 条未读”这样的副标题），列表顶上在有待审批 / 未读时多一行提示。
  - A2：底部标签栏（收件箱、首页、审批……），和参考差太多。
  - A3：放进设置，常用的东西藏得太深。
- **建议**：A + A1。改动集中在 `Navigation/` 和 `Shell/`（第 0、1 轮）。深链返回栈改成“首页 → 目标页”（3.4），
  和安卓（现在是抽屉）会不一样，安卓跟不跟着改另议。

### 6.2 颜色、气泡、字体

- **参考 App**：中性深灰底、亮一档的卡片、系统蓝和白色的主按钮、agent 回复是左侧灰气泡、全用 SF 字体。
- **ThinkTin 现在**（docs/ios.md 第 4 节）：暖色纸张底（深色 `#262624`）、橙色强调色、agent 回复不带气泡、标题衬线。
- **可选**
  - A：全照参考（中性灰 + 系统蓝 + 气泡 + SF）。
  - B：保留现在的令牌，只换布局和控件。
  - C：折中：底色、卡片、文字改中性（同参考），强调色保留 ThinkTin 的橙，agent 回复加气泡，字体全用 SF
    （首页空状态的大标题可以留衬线；欢迎页属于登录，跟着用户的设计）。
- **建议**：C（2.2 的表）。品牌靠 Logo 和橙色；玻璃材质放在中性底上最干净。定了以后 docs/ios.md 第 4 节一起改写；
  交接里列的四处“和 Claude 的差别”（输入框两行卡片、回复正文衬线、新对话问候语、任务筛选标签）以本规范为准。

### 6.3 最低系统版本

- **参考 App**：iOS 26。
- **ThinkTin 现在**：iOS 17（`project.yml`、`Package.swift`）。
- **可选**
  - A：保持 iOS 17，iOS 26 的接口集中在 `Design/Glass.swift` 里回退；外观以 iOS 26 为准，旧系统能用就行。
  - B：提到 iOS 18（缩放转场之类能直接用，回退少一些）。
  - C：提到 iOS 26（不用写回退，但没升级的手机装不了）。
- **建议**：A。App 还没上架，上架前看一次用户机型分布再决定要不要提。

### 6.4 “+”新建 Botin 流程

- **参考 App**：“+”直接弹新建表单（名字、形状、颜色），建好进对话，Bot 自动打招呼。
- **ThinkTin 现在**：领养必须先选 agent（`adopt(agentID:name:harness:)`），要让用户看到许可说明；领养后还要配 main 路由和 key 才能跑。
  现在的路径是 目录 → agent 详情 → 领养 sheet → “领养好了”页。
- **可选**
  - A：“+”弹领养表单，表单里一行选 agent（默认第一个或上次用的），许可说明放脚注。
  - B：“+”先弹 agent 目录（sheet），选了再填名字。
  - C：维持现状，“+”只是进目录。
- **建议**：A。“配模型、加 key”的引导挪到新实例对话的首次卡片（6.18）。
- **已定（2026-11-05，用户）**：A，并且照 6.6 改说法：“+”弹“新建 Botin”表单，起名字、选一个引擎（agent），同一个引擎能给好几个 Botin 用
  （服务端不限每个 agent 领养几次，只限每个账号的实例数）。首次登录首页是空的，空状态的按钮“新建 Botin”也打开这张表单（4.2.1）。

### 6.5 设置用 sheet 还是压栈

- **参考 App**：首页左上头像弹 sheet，左上玻璃 × 关闭。
- **ThinkTin 现在**：从抽屉压栈。
- **可选**：A sheet；B 压栈。
- **建议**：A。设置里的子页（保险箱、设备、key）从推送或深链打开时仍然走主导航栈（`Router.show` 先关 sheet），两边进的是同一个页面。
  代价：现在的 `Router` 只有一层 sheet，`open` 会关掉 sheet，选 A 就要在第 0 轮给 sheet 加自己的导航栈和第二层 sheet（3.3），
  不然设置里点保险箱条目、加 key 都会把设置关掉。

### 6.6 叫 Bot 还是实例

- **参考 App**：Bot。
- **ThinkTin 现在**：界面、文档、安卓、推送文案都叫“实例”，领养的是 agent。
- **可选**：A 沿用“实例”；B 改叫“Bot”；C 换个更口语的词（比如“助手”）。B、C 要中英文、安卓、推送、文档一起换。
- **建议**：A，本轮不改。首页、对话、资料页上主要显示的是名字，“实例”两个字出现得不多；要改名就单独做一次全端文案替换。
- **已定（2026-11-05，用户），推翻上面的建议**：界面上叫 **Botin**（中英文同一个词，英文复数 Botins）。
  - 用户**新建** Botin，不再“领养 agent”；新建时选它用哪个 agent 当**引擎**，同一个 agent 可以给好几个 Botin 当引擎。
  - agent 在界面上只以 Botin 的“引擎”/“Engine”出现：目录叫“引擎”、详情叫“引擎详情”、资料页头部写“引擎：Claude Agent · v…”、
    引擎进程出错写“引擎出错了”。说“谁在干活、谁写的、谁要你批准”时写 Botin（“Botin 写的内容”“Botin 需要你批准时”）。
    产品名（Claude Agent、Hermes Agent）照写。
  - 第一次登录首页是空的，空状态见 4.2.1（“还没有 Botin”+ 说明 +“新建 Botin”）。
  - 团队不是 Botin：团队模板的“领养”改成“用模板新建团队”一类的说法（按钮“新建团队”）。
  - 代码标识符不改（`Instance`、`InstanceID`、`AppRoute.adopt`、`adopt(agentID:name:harness:)`、`AdoptionModel`），接口和深链
    （`thinktin://instance/{id}`）也不改；只改界面文案、读屏标签、快捷指令和 Siri 短语、App 自己发的通知和实时活动文字、文档。
  - 中文里能不加量词就不加：“新建 Botin”“删除这个 Botin”“交给哪个 Botin？”，数数时照常“2 个 Botin”。
  - 安卓和服务端推送的文案归别的会话，要跟着改，见 docs/handoff-ios.md 的“Botin 改名”一节。
  - iOS 改完的范围和没改的（登录页的两句、服务端给的 agent 介绍）记在 docs/progress/ios-ui-redesign.md。

### 6.7 首页列表的预览

- **参考 App**：每行显示最后一条消息的预览和时间。
- **ThinkTin 现在**：`Instance` 只有 `lastActiveAt`，实例列表接口不带最后一条消息。
- **可选**
  - A：用本机缓存凑：最新一次运行的摘要（agent 写的，带小号 AI 标识），没有摘要时“你：任务原文”。
  - B：先显示状态（“2 个在等你处理”“运行中”），没有状态时同 A。
  - C：只显示状态和时间。
  - D：等后端在实例列表里带上最后一条。
- **建议**：B。没缓存过的实例只显示状态。
- **已做（2026-11-05，A 线）**：B。`HomeLastMessage.latest(in:)` 取缓存里最近一次运行的摘要（带“AI 生成”标识）或你发的任务（“你：”），
  计划派的、没摘要的跳过；创建中、不认识的状态照旧说状态（见 4.2.1 的“已做”）。

### 6.8 资料页的“电脑”行、实例的远程画面

- **参考 App**：资料页“电脑”行进 Bot 云桌面的实时画面，可以接管、用剪贴板和键盘（27–31、89）；设置里“Bot 电脑”能重置、看磁盘（65）。
- **ThinkTin 现在**：每个实例一个云端沙箱；docs/browser.md 有“观看与接管”的设计但没实现，`ClientProtocol` 没有画面、会话接口；
  “手机控制电脑”（12.9）是账号级配对的用户自己的电脑。
- **可选**
  - A：这一行叫“工作区”，进实例的沙箱页（状态、版本；以后加观看接管、重置）。
  - B：这一行指向用户自己的电脑（设置 → 登录设备里的电脑）。
  - C：不要这一行。
- **建议**：A（4.6.1）。观看接管等 browser.md 的后端（网关票据、画面通道、控制租约、剪贴板）和 client-core 接口，第 3 轮做；
  在手机上看用户自己电脑的画面另外立项。

### 6.9 头像和实例颜色

- **参考 App**：每个 Bot 一个“形状 + 颜色”头像（14 种形状、11 种颜色），还能 AI 生成、上传照片；颜色还用在输入框按钮上，
  外观里能让深色底跟随 Bot 颜色。
- **ThinkTin 现在**：`AgentMonogram`（圆里放名字第一个字，统一橙色）；`Instance` 没有头像字段，也没有上传、生成接口。
- **可选**
  - A：做形状 + 颜色，只存本机（换手机、安卓上看不到）。
  - B：后端在实例上加头像字段（形状 + 颜色），多端同步。
  - C：不做选择，继续首字头像，但按名字算出不同的颜色，实例之间好区分。
  - AI 生成：平台没有图片生成服务，模型调用用的是用户自己的 key，用哪把、费用怎么算都要定。上传：要存储接口和相机权限。
- **建议**：第 1 轮先 C（纯客户端，马上能用）；同时请后端加头像字段，有了再做 B（形状素材自己设计）；生成、上传不做。
- **现在（2026-11-05）**：C 做完了（第 0 轮）；用户要新建表单照参考做形状网格和色板，所以先做了 **A**：新建时挑形状（15 种，自己设计的
  几何、有机形状）和颜色（12 种），记在这台设备上（`InstanceAppearanceStore`，`UserDefaults` 一个键，按实例 id；不上传，退出登录不清；删了 Botin、注销账号时删掉对应的记录；以后的版本加的形状、颜色这个版本认不出时当默认画，存回去时原样留着，装回旧版本不会抹掉），
  首页、搜索、对话标题、Botin 资料按它画；没挑过的还是 C 的样子。换手机、安卓上看到的是按名字取色的圆。**还要后端**在实例上加头像字段
  （形状、颜色两个字符串，取值就是 `AvatarShape` / `AvatarColor` 的原始值，认不出的当默认）做 B；颜色用在输入框按钮、外观跟随实例颜色
  （6.22）另议。

### 6.10 置顶、隐藏、分组、未读、主实例

- **参考 App**：左滑置顶 / 隐藏；置顶的变成顶上的大头像；有“已隐藏”管理页；能自建分组（可折叠、改名、排序、删除）；
  长按能“标为未读”；有“主 Bot”星标和“替换主 Bot”。
- **ThinkTin 现在**：都没有，后端也没有对应字段。
- **可选**：A 只存本机（`UserDefaults`，按账号，仿 `InstanceSelectionStore`）；B 等后端加“实例偏好”（置顶、隐藏、分组、已读位置），
  多端同步；C 不做。
- **建议**
  - 置顶、隐藏：A，第 2 轮。隐藏只是首页不显示，计划照常跑、审批和推送照常发；要不要顺带静音另议。
  - 分组：先不做。实例不多时用处不大，还容易和“团队”混；要做也是 A。
  - 未读：本机比较“最后看到的事件序号”能做个近似，但多台设备会乱，不做。
  - 主实例：不做。如果想要“默认实例”（新任务、快捷指令、小组件默认用哪个），本机存就行。
- **已做（2026-11-05，A 线）**：置顶、隐藏按 A 做了（`InstancePreferencesStore`，见 4.2.1、4.2.3 的“已做”）；隐藏不静音。

### 6.11 消息的表情回应、标为未读、引用回复

- **参考 App**：长按消息弹底部面板：两排表情 + 回复、标为未读、复制、选择文本、复制请求 ID，还能打开完整的表情选择器；
  回复时输入框带一条引用。
- **ThinkTin 现在**：系统长按菜单（复制、分享、举报；用户消息是复制、再发一次）；没有反应、未读、引用的接口。
- **可选**
  - 表情：A 不做；B 只做 👍 / 👎，当作对回复的评价（要后端存）；C 完整表情（要后端，长按改成自己做的 sheet）。
  - 引用：A 纯客户端，拼成 Markdown 引用块发出去；B 后端给运行加“回复的是哪条”的字段（时间线里显示引用、点了能跳回去）；C 不做。
- **建议**：表情 A（以后要收集反馈再做 B）；标为未读不做；引用 A（第 2 轮）。长按菜单继续用系统的，加“选择文本”“复制运行 ID”。

### 6.12 连接应用 / 插件目录（含“此 iPhone”、第三方密码管理器）

- **参考 App**：首页左下进“连接应用”：分类、推荐、精选、搜索、网页授权、已连接列表、插件详情（账户、断开）；
  “此 iPhone”能把日历、提醒、通讯录、位置、家庭、闹钟开放给 Bot；还能接第三方密码管理器。
- **ThinkTin 现在**：没有第三方连接器、插件、技能；架构上 shim 只注入平台工具和电脑工具，在线技能市场关掉、技能走白名单（15.3）。
  已有的“接入”分散在设置里：模型 key、IM 渠道、保险箱、电脑配对。
- **可选**
  - A：做一个“连接”汇总页，只放已有的四类（纯客户端，第 2 轮）。
  - B：做第三方连接器目录：目录接口、网页授权、令牌托管（凭证不进沙箱）、按实例启用、shim 把连接器当 MCP 服务注入。量很大。
  - C：不做。
  - “此 iPhone”另算：要把手机做成工具宿主，iOS 不能常驻后台，控制类（家庭、闹钟）风险高，要配审批。
- **建议**：A；B 和“此 iPhone”等产品定方向后单独立项。入口放设置里（参考的设置里也有“连接应用”），首页左下给工作台（6.1）。
- **2026-11-05**：用户要求先照参考 1:1 做出全部版式（A 的汇总 + B、“此 iPhone”的界面用本地演示数据、操作弹“即将推出”），再按真实功能删改；
  见 4.8 各节的“已做”。B 和“此 iPhone”的后端仍然没做。

### 6.13 附件

- **参考 App**：输入框“+”：照片或视频、拍照、选择文件。
- **ThinkTin 现在**：12.22 运行附件等 1.1 拍板和后端 5.6，`ClientProtocol` 没有上传接口。
- **可选**：A 等后端，之前输入框不放“+”；B 先放“+”，点了提示“还没开放”；C 不做。
- **建议**：A。

### 6.14 按实例的通知开关

- **参考 App**：资料页一个“通知”开关（完成任务或等你处理时通知你）。
- **ThinkTin 现在**：只有系统级的通知权限，没有按实例关推送的接口。
- **可选**：A 后端加实例级的推送开关（服务端发推送时按它过滤）；B 只在本机过滤（App 在后台时系统直接显示推送，其实做不到静音，不推荐）；C 不做。
- **建议**：A，第 3 轮；之前资料页不放这一行。同一个接口也能让设置根页的“通知”变成真正的开关（4.9.1），现在只能跳系统设置。
- **已做（2026-11-05，截图审查，用户要 1:1 的版式）**：资料页照参考 09 放了“通知”一组，开关显示系统的通知权限能不能送到、不能拨，
  脚注说现在跟着系统设置、按 Botin 开关即将推出（4.4.1）。接口做好（A）以后换成能拨的开关。

### 6.15 自然语言权限规则和自动审查

- **参考 App**：“自动审查”总开关，加“始终询问”“无需询问即允许”两组一句话写的规则，由模型判断一次操作有没有命中。
- **ThinkTin 现在**：审批逐条批准；计划级按工具种类预授权；电脑上的高危操作每次都要手机签名（docs/pairing.md 第 3 节）。
- **可选**
  - A：后端做规则表、增删改查、模型判定，审批卡上显示“按规则允许”。
  - B：只做“始终询问”（只会更严，风险小）。
  - C：不做。
- **建议**：先 C，设置里这一行叫“审批”，进审批中心。产品和安全评审以后再定 A 或 B；不管怎么做，电脑上的高危操作不能被
  “自动允许”覆盖，规则本身还要防提示注入。
- **2026-11-05 用户要先照参考把页面排出来**（r2/settings，4.9.8 的“已做”）：权限页和新建 / 编辑规则用本地的演示规则，开关、保存、删除弹“即将推出”；审批中心照旧。A / B / C 还是要产品和安全评审定。

### 6.16 保险箱的卡片、联系信息、网站

- **参考 App**：保险箱有三种条目：登录信息（可以有多个网站）、卡片（卡号、有效期、安全码、账单地址，可以扫卡）、
  联系信息（多个电话和邮箱、地址）；脚注说 Bot 永远看不到完整卡号和安全码。
- **ThinkTin 现在**：只有账号密码一种（名字、用途、账号、密码、能用的实例）。
- **可选**
  - 网站字段：A 后端加，agent 能按网站找到对应条目；B 不做。
  - 卡片：要“agent 看不到完整卡号”的代填机制和 PCI 合规。A 做；B 不做。
  - 联系信息：A 后端加类型和结构化字段；B 不做。
- **建议**：网站 A（改动小，第 3 轮）；卡片 B；联系信息先 B，等真有让 agent 代填表单的需求。登录信息的表单第 1 轮先照参考改版。
- **2026-11-05 用户要先照参考把页面排出来**（r2/settings，4.9.5–4.9.7 的“已做”）：“+”菜单三种都有，卡片、联系信息的表单做了、保存弹“即将推出”，登录信息多了网站的行（不保存）。后端定了哪样，就把对应的“即将推出”换成真保存。

### 6.17 工作区的重置、磁盘、时区

- **参考 App**：设置里的“Bot 电脑”能从快照重置、看磁盘空间；还有“自动设置时区”和时区。
- **ThinkTin 现在**：没有重置、磁盘、实例时区的接口（计划和用量查询自带时区）；每个实例一个沙箱，不是共用一台。
- **可选**：A 后端加重置（从快照或模板重建，工作区留不留要定）、磁盘状态、实例时区；B 不做。
- **建议**：重置和磁盘 A，放在工作区页（第 3 轮）；时区不做，等 agent 真的需要本地时间再说。
- **已做（2026-11-05，截图审查，用户要 1:1 的版式）**：工作区页照参考 65 先排出“重置工作区”（点了说即将推出）和“磁盘空间”
  （值写“即将推出”）两行（4.6.1），接口做好（A）以后接上。

### 6.18 新实例的欢迎语和引导卡

- **参考 App**：建好自动进对话，有一段欢迎语，加一张“你最想让我先帮你做什么”的 A/B/C/D 选择卡。
- **ThinkTin 现在**：没有欢迎消息；后端没有“agent 提问 + 选项”的结构化事件；新实例要先配 main 路由和 key。
- **可选**
  - A：客户端画一张静态卡：先查模型和 key，没配好就引导去配；配好了给 3–4 个示例任务，点了就发出去。
  - B：后端加结构化提问事件，让 agent 自己出题。
  - C：不做，继续用空状态。
- **建议**：A（第 2 轮），示例任务按 agent 目录里的介绍写。

### 6.19 产出物的链接、缩略图、分页

- **参考 App**：资料库分“全部 / 媒体 / 链接”，按时间分组，图片有缩略图，底部“展开”加载更多。
- **ThinkTin 现在**：产出物只有文件；`instanceArtifacts` 只有 `limit`（最多 500），没有游标；没有缩略图接口。
- **可选**
  - 链接：A 后端按实例汇总对话里出现过的网址；B 客户端扫本机缓存的事件（不全）；C 不做，筛选改成“全部 / 媒体 / 文件”。
  - 缩略图：A 后端出缩略图；B 客户端下载原图缩小后缓存（只给图片、限数量）。
  - 分页：A 后端加 `before` 游标；B 本地折叠。
- **建议**：链接 C；缩略图 B（第 2 轮），以后再 A；分页先 B，产出物多了再 A。

### 6.20 设置里的其他新项

- **订阅**（56）：12.23 App 内购买等 1.1 拍板。建议等；要做就用 StoreKit 原生的订阅页，不用网页。
- **导入记忆**（71）：没有写入记忆的接口，各 agent 的记忆机制也不一样。可选：A 纯客户端，给选中的实例发一条“把下面这些记进你的记忆”的任务；
  B 后端统一接口；C 不做。建议 C，有需求再 A。
- **发送反馈**（76、77）：没有通用反馈接口（只有举报）。可选：A 后端加反馈接口（带 App 版本、设备、可选的实例）；B 先用邮件链接；C 不做。
  建议先 B，A 排进后端。
- **设备改名**（67、68）：要后端加改设备名的接口。改动小，建议做（第 3 轮）。
- **电脑“在此设备上执行”三档**（69）：和 docs/pairing.md“高危操作不能预授权”冲突，“始终允许”只能对普通操作签能力令牌（最长 7 天），
  “从不允许”等于吊销全部令牌。建议不做三档，电脑详情里保留现有的授权列表。
- **多账户**（54 的切换 / 添加账户）：client-core 只存一个会话。建议不做。
- **2026-11-05 用户要先照参考把页面排出来**（r2/settings，4.9.4、4.9.9、4.9.10、4.9.14 的“已做”）：订阅（演示方案）、导入记忆、设备改名的弹窗都做了，要服务端的操作弹“即将推出”；反馈按 B 用邮件发（邮箱是占位，要确认）。

### 6.21 分享

- **参考 App**：资料页右上“分享”；对话菜单、长按菜单里“分享为模板”；图片查看页“转发”（25，转给另一个 Bot）。
- **ThinkTin 现在**：没有单个实例的模板和对外分享；深链 `thinktin://instance/{id}` 只对自己有用；团队模板只能自己用。
- **可选**：A 后端加“从实例生成 agent 模板 / 分享链接”；B 分享 agent 的公开介绍页（如果有网址）；C 不放分享。
- **建议**：C。图片“转发”给另一个实例也不做：`sendMessage` 只收文字，要等运行附件（6.13）；系统分享（`ShareLink`）照常有。

### 6.22 纯黑外观、跟随实例颜色、触感

- **参考 App**：外观页两排方块：跟随系统 / 浅色 / 深色，深色底色可选黑色或跟随 Bot 颜色；还有触感反馈开关。
- **ThinkTin 现在**：外观三选一（打勾列表），没有底色选项；代码里没有任何触感。
- **可选**：纯黑 A 做（Theme 加一套纯黑值，纯客户端）/ B 不做；跟随实例颜色跟着 6.9；触感 A 做（先定哪些操作带：发送、批准 / 拒绝、复制、
  左滑、长按）/ B 不做。
- **建议**：纯黑 A（第 2 轮）；跟随实例颜色不做；触感 A，设置里直接一行开关，不单开页面。

### 6.23 语音

- **参考 App**：对话里有语音模式按钮和通话记录；编辑页能选音色、语速、语言。
- **ThinkTin 现在**：没有语音通话，也没有语音合成。
- **可选**：A 做（要服务端语音、语音合成、实例上的字段）；B 只用键盘自带的听写；C 不做。
- **建议**：B。输入框不放麦克风按钮，系统键盘自带听写。
- **现在（2026-11-05）**：用户要先照参考把页面排出来，编辑页的“语音通话”组（语音、速度、语言）做成了只存本机的演示（4.4.3），
  脚注写“即将推出”；对话里还是没有语音模式。要不要留这一组由用户定。

### 6.24 搜索的筛选类型

- **参考 App**：全部 / 消息 / Bot / 群聊 / 文件 / 定时任务。
- **ThinkTin 现在**：能搜实例、运行（任务和摘要）、收件箱、计划、产出物；没有群聊（团队没有群聊，agent 交流界面 12.24 在等后端）。
- **可选**：A 全部 / 消息 / 实例 / 收件箱 / 计划 / 产出物；B 再加“团队”（联网时拉 `teams()`）。
- **建议**：A。

## 7. 实施计划

### 7.1 原则

- **先底座、再并行。** `Navigation/`、`Shell/`、`Design/`、`Components/`、uicheck 桩是大家共用的，第 0 轮一条线改完、合进来，
  之后各线只改自己的功能目录（docs/ios.md 第 9 节的分工、9.1 的接入点规矩）。
- **开工先认领。** 建 `docs/progress/ios-ui-redesign.md`（CLAUDE.md 的格式），每条线写“谁在做、几点开始”；每一步能编译就提交、推送。
- **先定再做。** 第 1 轮开工前要定 6.1–6.6；第 2 轮开工前要定 6.7–6.12、6.18、6.19、6.22。
- **每一步都验证**（7.6）：视图模型有 Linux 测试，界面过 uicheck，每轮末出截图对照。

### 7.2 第 0 轮：底座（一条线，先合）

| 做什么 | 文件 |
|---|---|
| 令牌按 6.2 改值、加 `agentBubble`；标题不再用衬线；圆角调整；加 `themedGroupedBackground()` | `Design/Theme.swift`、`Design/Typography.swift`、`Design/Metrics.swift`；测试 `Tests/ThinktinUITests/DesignTokenTests.swift` |
| iOS 26 兼容层（关闭按钮、玻璃按钮样式、玻璃胶囊背景、底部条、工具栏间隔、缩放转场，各带旧系统回退）；删掉 `solidTopScrollEdge()` | 新建 `Design/Glass.swift`；`Components/ListComponents.swift` |
| 实例头像组件（首字 + 按名字取色 + 状态角标），`AgentMonogram` 挪进来 | 新建 `Components/InstanceAvatar.swift`；`Screens/Agents/AgentMonogram.swift` 删掉（调用处一起改） |
| 筛选胶囊组件，替换 `PlansFilterChip` | 新建 `Components/FilterChipBar.swift`（调用处在第 1 轮各线改） |
| 路由改动（3.3）：`.home` 永远是根、`.conversation` 压栈、`.settings` sheet、`.search` 回首页、`.plans(instanceID:)`、新增 `.adopt(agentID:)`；去掉抽屉状态，`openFromDrawer` 改 `openTopLevel`，加 `searchRequest`；sheet 自己的导航栈（`sheetPath`）和第二层 sheet；深链返回栈（3.4） | `Navigation/AppRoute.swift`、`AppRoute+Title.swift`、`AppFeature.swift`、`Router.swift`、`DeepLink.swift`；`Tests/ThinktinKitTests/Navigation/` |
| 最小可用的首页（列表 + 左上设置 + 右上领养 + 左下工作台 + 底部搜索框），去掉抽屉和实例切换 | `Shell/AppShell.swift`、`Shell/AppDestination.swift`、`Shell/ShellDestination.swift`、新建 `Shell/Home/`；删 `Shell/ShellDrawer.swift`、`Shell/InstanceSwitcher.swift`；`ViewModels/Shell/`；`Tests/*/Shell/` |
| 各功能接入点跟上新路由（只改 `Destination` 的分派，不改页面） | `Screens/Plans/PlansDestination.swift`、`Screens/Agents/AgentsDestination.swift`、`Screens/Search/SearchDestination.swift` |
| uicheck 补桩：2.10 表里的 iOS 26 / 18 API，和现在没有的 `List`、`Form`、`Section`、`LabeledContent`、`ContentUnavailableView`、列表和工具栏的修饰符（2.10 列了清单；只有 iOS 有的放 `#if canImport(UIKit)`） | `tools/apple/uicheck/Stubs/SwiftUI/` |
| 启动屏资源 | `tools/apple/brand_assets.py`、`apps/apple/Thinktin/Resources/Assets.xcassets`（生成物）、`apps/apple/project.yml` |
| 截图脚本：去掉抽屉的两张；加一个只有 Debug 构建认的环境变量 `THINKTIN_OPEN_SCREEN`（conversation / plans / artifacts / settings / search / adopt，打开演示数据里第一个实例的对应页面）；截图清单换成 7.6 的 | `tools/apple/screenshots.sh`、`apps/apple/Thinktin/App/AppConfiguration.swift` |
| 文档：docs/ios.md 第 4 节（令牌）、6.1 节（返回栈）、9.1 第 6 条（对话页没有抽屉按钮了）；建进度文件 | `docs/ios.md`、`docs/progress/ios-ui-redesign.md` |

做完的标准：App 能跑通“首页 → 对话 → 实例资料（旧版式）→ 设置（sheet）”，Linux 测试、uicheck 三种、格式检查、macOS CI 都绿。

第 0 轮的上面几行 2026-11-05 都做完了（分支 `ios-ui-redesign`，逐行的做法和还没验的见 docs/progress/ios-ui-redesign.md），
还差 macOS CI 用真 SDK 编一遍、出一次截图对照。

### 7.3 第 1 轮：和现有功能一一对应、不用后端（五条线并行）

| 线 | 页面（规范节） | 改 / 新建的文件和目录 |
|---|---|---|
| A 首页（12.16） | 首页完整版（4.2.1，不含置顶隐藏）、长按菜单（4.2.2：实例资料、改名、新建计划、复制 ID、删除）、工作台菜单和“等你处理”提示行、首页嵌入搜索（4.2.4 第 1 轮部分）、`NewTaskSheet` 换选择器版式（4.4.5） | `Shell/Home/*`、`Shell/ShellDestination.swift`、`ViewModels/Shell/HomeListModel.swift`（新）、`AppModel.swift`（小改）、`Tests/*/Shell/` |
| B 对话（12.5） | 对话页（4.3.1，不含引导卡）、“…”菜单（4.3.2）、消息长按菜单（4.3.4）、时间分隔 | `Screens/Conversation/*`、`Components/ComposerBar.swift`（本轮归 B）、`ViewModels/Conversation/*`、`Tests/*/Conversation*/` |
| C 实例（12.3） | 实例资料（4.4.1）、“…”菜单（4.4.2）、编辑页（4.4.3）、工作区页（4.6.1）、引擎目录改列表行（新建 Botin 表单 4.7.1 已经先做了，2026-11-05） | `Screens/Agents/*`（新 `InstanceEditScreen.swift`、`InstanceWorkspaceScreen.swift`）、`ViewModels/Agents/*`、`Tests/*/Agents/` |
| D 计划、产出物、搜索（12.6、12.18、12.21） | 实例的计划和全部计划（4.5.1）、产出物版式和产出物详情（4.5.2、4.5.3 第 1 轮部分）、`SearchResultsView` 拆出来给 A 用（4.2.4） | `Screens/Plans/*`、`Screens/Artifacts/*`、`Screens/Search/*`、对应的 `ViewModels/` 和测试 |
| E 设置一带（12.12、12.2、12.4、12.13、12.14、12.9 手机这边） | 设置根页（4.9.1）、账号（4.9.2）、用量（4.9.3）、保险箱和登录信息表单（4.9.5、4.9.6）、设备列表和详情（4.9.9）、外观（4.9.11）、语言（4.9.12）、模型 key、IM 渠道换原生 | `Screens/Settings/*`、`ViewModels/Settings/SettingsModel.swift`、`Screens/Account/*`（登录相关不动）、`Screens/Models/*`、`Screens/Vault/*`、`Screens/ImChannels/*`、`Screens/Computer/ComputerLinkViews.swift` |

- A 线 2026-11-05 做完首页这一半（首页的行和预览 4.2.1、长按菜单 4.2.2，顺带做了第 2 轮的置顶、隐藏、左滑、已隐藏页和说明 4.2.1、
  4.2.3，6.7 B、6.10 A）；`NewTaskSheet` 换选择器版式（4.4.5）收尾线做了，“等你处理”提示行 2026-11-05 四条 r2 线合进来以后补了（4.2.1）。逐节的做法见各节的“已做”和
  docs/progress/ios-ui-redesign.md。
- C 线 2026-11-05 做完（Botin 资料 4.4.1、“…”菜单 4.4.2、编辑页 4.4.3、工作区页 4.6.1 和它的说明、引擎目录的列表行和引擎详情的 sheet 版式
  4.7.1 / 4.8.3，顺带做了第 2 轮的改头像 4.4.4 和删除确认页换原生列表），逐节的做法见各节的“已做”和 docs/progress/ios-ui-redesign.md。
- B 线 2026-11-05 做完（对话页 4.3.1、“…”菜单 4.3.2、长按菜单 4.3.4，顺带做了第 2 轮的引用回复 4.3.5 和首次引导卡 6.18 A；
  对话内查找 4.3.3 还没做），逐节的做法见各节的“已做”和 docs/progress/ios-ui-redesign.md。
- D 线 2026-11-05 做完（计划列表 4.5.1 和计划详情、产出物库 4.5.2、图片全屏查看和产出物详情 4.5.3、首页搜索 4.2.4，顺带做了
  第 2 轮的产出物类型筛选、按日期分组、缩略图、存相册和搜索的筛选、“谁发给谁”；`SearchResultsView` 已经嵌进首页）。计划的新建 / 编辑、
  确认页、触发器编辑器还是自画版式。逐节的做法见各节的“已做”和 docs/progress/ios-ui-redesign.md。
- E 线 2026-11-05：模型 key 列表（在用 / 停用两组，`ModelsCredentialRow` 变成纯行内容，标签换成一行灰字 `CredentialSummary.tagsLine`，
  空状态 `ContentUnavailableView`，右上玻璃“+”）、key 详情（居中头部 + 玻璃胶囊“改备注”、启用开关、换 key、信息、用量、用在哪里、红字删除，
  右上 `ellipsis` 菜单；三个小 sheet 的按钮换 `CloseButton` / `ConfirmButton`）、IM 渠道（每个群一组：开关行、发测试消息、修改、红字删除；
  编辑页换 `Form`）、模型路由（每个别名一组 `RouteSection`：用途、主 key 的系统 `Picker(.menu)`、标签在上的上游模型输入框 + 推荐菜单、
  降级链的几行、加备用 key、红字删掉别名；“更多别名”一组；保存在右上 `ConfirmButton`，页尾的大按钮去掉）、关于页（`BrandLogo` 头部 +
  分组）换成原生的。参考里没有这几页，照设置子页、Botin 资料页的写法排。添加 key 的 sheet、key 的三个小 sheet 里的字段、注销页、
  开源许可页还是旧版式。
- E 线 2026-11-05 做完（设置根页 4.9.1、账号 4.9.2、用量 4.9.3、保险箱和登录信息表单 4.9.5、4.9.6、登录设备和设备详情 4.9.9、外观 4.9.11
  第一排、语言 4.9.12，顺带做了第 2 轮的触感反馈 4.9.13；模型 key、key 详情、模型路由、IM 渠道、关于页换原生），逐节的做法见各节的“已做”
  和 docs/progress/ios-ui-redesign.md。纯黑外观（4.9.11 第二排）、添加 key 的 sheet、注销页、开源许可页还是旧版式。
- 线之间的依赖：A 的首页搜索要用 D 拆出来的 `SearchResultsView`，D 先交这一块，A 之前先嵌现有的 `SearchScreen`（2026-11-05 D 线已经嵌好）。
  A 的长按“改名”自己用 `.alert` + `InstanceNameRule`，不等 C。
- 收尾（谁先空下来谁做）：参考里没有的页（收件箱、审批中心、进行中、团队和流水线、运行详情、运行树、引导、关于、开源许可）
  按第 2 节换原生控件，各在自己的目录里改；最后删掉没人用了的 `EmptyStateView`、`PillButton`、`Card`、`GroupedSection`、`ListRow`、
  `PageHeader`、`AccountRow` 这些自画组件（`Components/`、`Screens/Account/AccountComponents.swift`、`Screens/Settings/SettingsComponents.swift`、
  `Screens/Plans/PlansComponents.swift`）。
  **2026-11-05 做完**（收尾线）：收件箱（照首页的消息列表，plain、左滑、长按）、一条通知、审批中心和详情（每个审批一张分组卡片，选项是全宽玻璃
  胶囊）、进行中、运行树（分组列表，左滑停止）、团队和团队详情、团队编辑（参考 11 的选择器版式）、流水线编辑器（`Form`，每步一组）、新任务的
  Botin 选择（4.4.5）、引导（分组列表 + 底部浮动胶囊）、开源许可和组件详情（`DisclosureGroup`）、冻结页和升级页（`ContentUnavailableView`），
  顺带把 D、E 线剩下的自画页也换了：计划的新建 / 编辑、确认页、触发器编辑器和时区页、添加 key 和 key 的三个小 sheet、注销账号、电脑配对和授权。
  对话、运行详情里系统没有的卡片画在新的 `BubbleCard` 上。删掉的：`Components/Card.swift`、`EmptyStateView.swift`、`PillButton.swift`，
  `ListComponents.swift` 里的 `SectionHeader`、`GroupedSection`、`ListRow`、`TagChip`、`ChoiceRow`、`InlineNotice`、`PageHeader`、
  `LoadingStateView`、`pageLayout()` 和大标题露没露的那套（`PageTitleVisibility`），`AccountSection`、`AccountAvatar`、`PlansTextField`、
  `PlansButtonRow`、`ModelsFootnote`、`ModelsOfflineNote`。新的共用写法：`LabeledRow`、`NoticeRow`、`AdaptiveRow`（`Components/ListStyles.swift`）、
  `FormTextField`（`Components/FormFields.swift`）。登录页（1.4）没动：它还用 `AccountRow`、`AccountScrollPage`、`AccountPageHeader`、
  `CheckboxRow` 和胶囊按钮样式（挪到 `Screens/Account/SignInButtonStyle.swift`，只给登录页用），等用户的设计。逐页的做法见
  docs/progress/ios-ui-redesign.md。
  **还原度评审修正（2026-11-05，截图 10-approval 对第 2 节；这页参考里没有）**：审批详情是 insetGrouped `List`，`List` 的行里系统会把
  `Label` 的图标挪到行首那一栏、涂成强调色——突出的“允许一次”上就是橙底橙勾（看不见），另外两个选项的图标和字隔了约 20pt。选项按钮的字
  换成自己排的 `ApprovalOptionLabel`（`HStack` 里勾 / 叉 + 名字，图标跟着按钮的前景色，读屏只念名字），和对话里的审批卡片共用。
  “还剩 23 小时”从警告色改成次要的灰，和对话里的卡片一样（剩余时间是说明，`warning` 只给状态用，2.2）。第二组“打开对话”还是按钮
  （`router.open` 回首页再进对话，不压在这一页上），样子改成和上面“查看这次运行”的 `NavigationLink` 一样：墨色的字、行尾灰箭头。
  **截图审查（2026-11-05，资料这一组：11、12、13、15、16、18；这几页参考里都没有，对第 2 节和兄弟页）**：
  - 收件箱（11）：一行和首页的行一样（`HomeLayout` 的边距和间距、44pt 图标垂直居中、两行）；未读圆点挪到图标右上角当角标（标题
    都从同一个 x 起，以前未读的标题往右错 12pt）；去掉第三行的种类（标题已经说了，比如“等你审批”），AI 标识放在正文那一行的末尾；
    右上“全部已读”从文字胶囊换成只有图标的玻璃圆（`envelope.open`，中性色，读屏念“全部已读”）。
  - 审批中心（15）：导航栏下面那段说明挪到第一个审批的脚注，列表 `compactGroupedList()`；选项胶囊 `.controlSize(.regular)`（三个
    `.large` 摞起来一条审批占半屏；对话里只有一张卡片，那里照旧 `.large`）；“详情”是这一组里系统的一行 `NavigationLink`（系统的
    分隔线和 chevron），不再在卡片里自己画分隔线和箭头。突出的选项上图标显式写白色（`ApprovalOptionLabel(prominent:)`），不怕行的 tint。
  - 进行中（12）：头像 40pt（`Metrics.Avatar.search`，以前 32 不在 2.4 的尺寸里），分组标题 `groupHeader()`，`compactGroupedList()`。
  - 运行详情（13）：从自己画的卡片（`BubbleCard`、`cardSurface`）换成 insetGrouped `List`，和计划详情、审批、进行中一套：居中的头部
    （`RunDetailHeader`：44pt 状态图标、`.title2` 粗体的状态、灰色的“用时 · token”或在等什么，等待类的跳转小胶囊，原文可以展开），
    任务一组（用户气泡的灰），来源、Botin、计划、尝试次数、token、时间是系统的 `LabeledContent` 行，摘要、失败原因各一组，
    “只看本次过程 / 运行树 / 打开对话”一组（`RowLabel` + 系统 chevron），产出物一组用产出物库的 `ArtifactRow`（以前是对话里的卡片，
    同一个文件两页长得不一样），长按举报。右上 `ellipsis`（以前是 `ellipsis.circle`，圆里套圆）放在 `ToolbarSlot.trailing`、中性色。
  - 团队（16）：说明挪到“我的团队”的脚注（只列模板的页面放在模板组），`compactGroupedList()`；模板一行前面加 32pt 的 `person.3`，
    和团队那一行的头像同宽，两组的字对齐；行里的“新建团队”从玻璃小胶囊换成强调色的文字按钮（`.borderless`，白底上玻璃的阴影是一圈灰晕）。
  - 引导（18）：sheet 左上补玻璃 ×（`SheetStack.addsCloseButton(to: .onboarding)`，2.6 每个 sheet 都有）；可选的“打开通知”不编号、
    画铃铛（标题说“四步”，以前第五行是“5”）；“选默认模型”的说明去掉反引号（纯文本里原样露出“`main`”），写成“main 别名”；
    都做完时底部按钮是“完成”（`OnboardingText.finish`），“已完成”只当每一步的读屏状态。

### 7.4 第 2 轮：纯客户端的新功能

| 线 | 页面（规范节） | 文件 |
|---|---|---|
| A 首页 | 置顶、隐藏、置顶网格、已隐藏页和说明（4.2.1、4.2.3）；分组（如果 6.10 要做，4.7.2） | `Shell/Home/*`、`ViewModels/Shell/InstancePreferencesStore.swift`（新） |
| B 对话 | 对话内查找（4.3.3）、引用回复（4.3.5）、新实例引导卡（4.3.1、6.18） | `Screens/Conversation/ConversationFindBar.swift`（新）、`ViewModels/Conversation/ConversationFind.swift`（新） |
| C 实例 | 改头像的页（4.4.4；新建时挑形状和颜色、存本机 2026-11-05 已做，6.9 A）；agent 详情借插件详情的 sheet 版式（4.8.3） | `Screens/Agents/*` |
| D 产出物、搜索 | 产出物类型筛选、按日期分组、缩略图、图片全屏查看、存相册（4.5.2、4.5.3）；搜索筛选和“谁发给谁”（4.2.4） | `Screens/Artifacts/*`、`ViewModels/Artifacts/*`、`Screens/Search/*`、`ViewModels/Search/*`；Info.plist 和隐私清单加相册“添加”权限 |
| E 设置、连接 | “连接”汇总页和已连接列表（4.8.1、4.8.2）；纯黑外观、触感（4.9.11、4.9.13） | 新建 `Screens/Connections/`、`ViewModels/Connections/`（`.connections` 路由在本轮开头由 `Navigation/` 统一加）；`ViewModels/Settings/SettingsPreferences.swift`、`Design/Theme.swift`（纯黑值） |

### 7.5 第 3 轮：要后端的（等接口）

接法照 12.x 的老办法：后端和 client-core 先出接口；`ClientProtocol` 加方法，`MockClient` 按服务端规则实现，`CoreClient` 接上，
`ObservedClient` 补转发（不补编译不过）；然后再做界面。

| 功能 | 后端要做的 | 页面 |
|---|---|---|
| 观看与接管 | docs/browser.md 的票据、画面通道、控制租约、会话状态事件；剪贴板和键盘输入（browser.md 还没写，要补设计）；新路由 `.instanceScreen` | 4.6.2、4.6.3 |
| 运行附件（12.22） | 1.1 拍板、5.6 上传 | 4.3.6 |
| 按实例通知开关 | 实例级推送开关 | 4.4.1 |
| 工作区重置、磁盘 | 重置、磁盘状态接口 | 4.6.1 |
| 设备改名 | 改设备名接口 | 4.9.9 |
| 保险箱网站字段 | 条目加网站 | 4.9.6 |
| 发送反馈 | 反馈接口 | 4.9.14 |
| 头像、置顶隐藏多端同步 | 实例偏好字段 | 4.4.4、4.2.1 |
| 产出物分页、缩略图 | `before` 游标、缩略图 | 4.5.2 |
| 订阅（12.23） | 1.1、计费包、验票 | 4.9.4 |
| 权限规则、第三方连接器（如果定了要做） | 见 6.15、6.12 | 4.9.8、4.8.* |

### 7.6 验证办法

1. **Linux（每次提交前）**
   - `cd apps/apple/ThinktinKit && swift test`：新的视图模型逻辑都要有测试，包括首页排序 / 置顶 / 隐藏 / 预览文字、时间分隔、对话内查找、
     设置分组、`AppRoute` 和 `Router`（`AppRouteTests` 逐个检查新 case 的 `feature`、`presentation`、`offlinePolicy`、`title`）。
   - `tools/apple/uicheck/run.sh`：UIKit、AppKit、`test` 三种都要过。第 0 轮补的 iOS 26 桩在这里起作用。
   - `swift format lint --strict -r apps/apple`（提交前先 `swift format -i -r apps/apple`）。
2. **macOS CI（`.github/workflows/ios.yml`，推 main、开 PR、推 `ci/**` 分支时跑）**：真实的 iOS 26 SDK 编译，模拟器上跑 `ThinktinTests`
   和 `ThinktinUITests`（`renderInBothAppearances` 深浅色都渲染）。Linux 的桩查不出真实 SwiftUI 的问题，以它为准。没开 PR 的分支要验时
   推到 `ci/<名字>`（`git push origin HEAD:ci/<名字>`），用 GitHub 免费的 macOS 机器跑。
3. **截图对照（每轮末）**
   - 跑 `.github/workflows/ios-screenshots.yml`：Actions → iOS screenshots → Run workflow，或者 `git push -f origin HEAD:ios-screenshots`；
     截图在 artifact `ios-screenshots`。用的是 Mock 演示数据，不会有个人信息。
   - 截图清单（`tools/apple/screenshots.sh`）覆盖改版的每一组页面，一共 71 张：主要页面浅色、深色各一张，其余只截浅色。
     每张对哪几张参考、规范哪一节见 [ios-ui-redesign-shots.md](ios-ui-redesign-shots.md)（还原度评审照它逐张看），截不到的
     （系统菜单、左滑、长按、要输入的状态）也列在那里。页面用启动变量打开：`THINKTIN_OPEN_URL` 是深链，`THINKTIN_OPEN_SCREEN`
     是没有深链的页面（42 个值，`AppConfiguration.OpenScreen`），`THINKTIN_MOCK_EMPTY=1` 是新账号。页面里本地打开、没有路由的子页
     （编辑 Botin、头像、工作区、引擎详情、保险箱的新建表单、设备详情、外观……）先开父页面，再由 `Router.requestSubpages(_:)` 记下、
     父页面出现后一层层打开（ThinktinUI 的 `onSubpageRequest`）。首页的置顶、隐藏只记在这台设备上，截图脚本每次启动用启动参数
     把它们清空，`homepinned` 这几张自己摆。
   - 和参考截图并排看（参考截图留在仓库外，不提交）。逐页对照：导航栏按钮的位置和形状、有没有标题、列表样式、卡片圆角和有没有描边、
     底部浮动条、空状态、深浅色。差别记进进度文件，改完再出一次截图。
   - iOS 17/18 的回退：每轮至少在一个 iOS 17 或 18 的模拟器上出一次截图。云端没有 Xcode，走 CI：Actions → iOS screenshots →
     Run workflow 填 `ios_runtime`（比如 `18.6`），或者 `git push -f origin HEAD:ios-screenshots-ios18.6`，截图在 artifact
     `ios-screenshots-ios18.6`；Codemagic 发起构建时改环境变量 `IOS_RUNTIME`。本机是 `IOS_RUNTIME=18.6 tools/apple/screenshots.sh`
     （默认选最新的运行时）。镜像里没有那个运行时的话脚本先用 `xcodebuild -downloadPlatform` 下载（要写完整的版本号）。只看能用、不乱。
4. **人工过一遍**：深色、浅色、最大的动态字体、VoiceOver（头像、状态角标、自画卡片都要有读屏标签，长按菜单里的操作读屏也能用）、
   离线（飞行模式下首页显示缓存、写操作禁用）、推送和深链跳进来的返回栈（3.4）。
