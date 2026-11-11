# ios-ui-fidelity-3
目标：#31、#32 删了很多东西、换了头像颜色之后，没看过真机上的样子。在 main（`d0274aa`）上跑了一遍截图（GitHub iOS screenshots 第 7 次，
Xcode 26，72 张），按 docs/ios-ui-redesign-shots.md 逐页对 120 张参考稿，把还不一样的改掉。规范里写明“留着不改”的（品牌色、自己的脸、
法规要求留的、没有的功能）不算。

已完成：
- 7 组（首页和搜索、对话、Botin、任务和资料、连接、设置前半、设置后半）各自对照截图和参考，改了自己的页面（快照 `7eb9182`、`a2d6fc9`、
  `129921f`）。每一页改了什么、看了什么没改，写在 docs/ios-ui-redesign.md 各节的“还原度复查（2026-11-10，main 的截图，GitHub iOS
  screenshots 第 7 次）”里；这一轮删掉的东西补进了 1.5 的“删掉的”表。
- 2026-11-11 合起来：把各组提的、要改共用文件的地方改了：
  - 筛选胶囊（`FilterChipBar`）从系统玻璃按钮换成实心胶囊，约 34pt 高（三组都量出来矮了 4pt；深色是空心的；浅色在列表行里有一块灰底）；
    保险箱的 `.tabs` 字大一号、约 39pt 高。
  - 分组标题、脚注的灰：新的 `Theme.groupCaption`（深色和参考一样暗一档，浅色照旧），`groupHeader()` 用它，新加 `groupFooter()`；
    保险箱几页照参考保持亮的（`vaultGroupHeader()` / `vaultGroupFooter()`）。
  - 详情 sheet 的头部：`toolbarLevelHeaderList(lifted:)` 改成整个列表往上提，`toolbarLevelHeader()` 删了（截图 37 的图标被切掉一大半）；
    引擎详情也用上，sheet 小的那一档和连接详情一样（`ConnectionsLayout.detailDetent`）。
  - 观看与接管那一页浅色下状态栏看不见：根视图（`SettingsPreferencesScope`）先读页面要的配色再设 `preferredColorScheme`。
  - uicheck 的桩补了真实的 API：`lineSpacing(_:)`、`SymbolRenderingMode` / `symbolRenderingMode(_:)`、`PreferenceKey`、
    `PreferredColorSchemeKey`、`onPreferenceChange(_:perform:)`（照 iOS 18 SDK，回调是 `@Sendable`）。
  - 资料页的行图标、设备列表的图标单色画；删了没人用的 `SettingsMetrics.appearanceTileHeight`。
- Linux 上全部检查都过了（见下面“检查”）。规范、这个文件、docs/handoff-ios.md 第 5 节都更新了。

检查（2026-11-11，合起来以后）：
- `swift build --build-tests` + `swift test`（ThinktinKit）：1181 个测试全过。
- `tools/apple/uicheck/run.sh`、`run.sh appkit`、`run.sh test`：都编过，ThinktinUITests 189 个全过。
- `swift test --skip-build --filter ThinktinTests`（uicheck 里）：17 过，5 个要 App 包的（Info.plist、隐私清单、小组件扩展、缓存路径）
  在 Linux 上本来就过不了。
- `swift format lint --strict -r apps/apple`：干净。

进行中：无（等 lead 提交、推送）。

下一步：
1. Xcode 26 上编过（GitHub iOS 工作流），再跑一次 GitHub iOS screenshots，逐张看下面“要截图确认”的几处。
2. 用户回答下面“要用户定的”以后照着改。
3. 打 TestFlight 42 给用户看。

要截图确认的（Linux 上看不到，都是照系统行为推的）：
- 详情 sheet 的头部（37、34）：负的内容边距真机认不认；图标要完整、上沿和 × 的圆心一样高。sheet 上沿约 382pt（`detailDetentFraction`）。
- 观看与接管（20 浅色）：状态栏是白字；退出去那一下底下的页面会是深色的。
- 筛选胶囊（05、09、19、35、04）：约 34pt 高、没有灰底；连接目录的胶囊中线离返回圆心约 75pt。
- 资料页、设备列表的图标（03、46）：单色以后屏幕那一块是空的（要是变成实心的灰，就换 `.palette` + 透明的第二色）。
- Botin 几页（03、29、30）：`contentMargins(.horizontal, 24)` 是替换系统的 16pt 还是加上去（卡片离边应该 24pt，不是 40pt）。
- 产出物（05）：胶囊那一组的间距 4pt 起没起作用，第一组上移约 10pt。
- 输入框（02）：“+”和发送是 32pt 还是 34pt；气泡行距约 24pt。
- 设置一带：第一张卡在返回圆下面约 34pt（参考 36–37pt，对得上就把 `settingsGroupedList()` 顶上的 24 加到 26–27）。

要用户定的（各组提的，合在一起；括号里是现在的样子）：
1. 搜索行离边 22pt（照参考 78）还是跟首页的 16pt？现在点搜索同两个 Botin 横着挪 6pt。（现在 22pt）
2. 对话气泡上下内边距 12 → 10：规范以前写“气泡的几何留着不改”，量出来参考的字离气泡边近 2pt。（已改成 10，要回去改一个常量）
3. 对话页右上“…”：参考是白的，规范 2.2 说图标按钮都中性色，4.3.1 以前写橙色留着。（已改成中性色）
4. 筛选胶囊：系统玻璃按钮还是参考那样的实心胶囊？玻璃在浅色列表里去不掉那块灰底。（已改成实心，选中的照旧是橙色）
5. 分组标题、脚注的颜色：深色已照参考暗一档；浅色要不要也暗一档（`inkTertiary` 的浅色在浅灰底上不到 2:1，整句看不清，参考没有浅色）。（浅色没变）
6. Botin 头像页顶上的三个选项：系统分段控件，还是参考那样三个字、选中的垫一块胶囊？（系统分段控件）
7. 引擎详情名字下面的出处（“基于 Anthropic 的 Claude Agent SDK”）：参考没有，注明是商标要求的写法。留着、挪到许可证那组，还是删？（留着）
8. 不是主 Botin 时资料页头像上的状态角标：参考只有主 Bot 的星标，首页等地方 11-06 已经删了。（留着）
9. 新建 Botin、选主 Botin、新任务这几张 sheet：参考是浮起来、短一点、四角都圆的；改短的话新建表单的颜色那几行要滚。（照旧是 large sheet）
10. 资料页“编辑”胶囊、编辑页头像上的铅笔：换成了卡片色的实心（参考是平的，玻璃的阴影被行切出一道横边），和“次按钮用玻璃”的规矩不一样。（已改成实心）
11. 连接目录、已连接列表最底下的说明删了（参考没有）；现在哪些能连只在点了以后的“即将推出”里说。可以吗？（已删）
12. 连接详情“账户”组每行的状态（在线 / 离线 / 打码的 key / 已停用）和箭头删了，只剩灰字和读屏。可以吗？哪个要回来？（已删）
13. 连接行的图标 42pt（参考），引擎目录、模型 key 的厂商图标还是 40pt（规范 2.4）：要不要跟着？（没跟）
14. 账号页“手机号”“退出登录”下面的两条脚注：参考 54 只有删除那一行下面有。（留着）
15. 模型 key 列表里厂商名太长时截在中间（“Anthropic (Cl… · ••••Q7mA”）：要不要这一行干脆不写括号里的（“Anthropic · ••••Q7mA”）？（截在中间）
16. 本机的设备详情页的红色“下线本机”：参考 67 两行卡片下面什么都没有；删了就少一个入口（设置根页、账号页还有退出登录）。（留着）
17. 设备详情状态后面的登录日期（“正在使用 · 10月2日登录”）：参考没有，同名的设备靠它分。（留着）

坑和决定：
- 筛选胶囊换实心：首页、资料、连接三组都量出来胶囊比参考矮约 4pt，两组建议换实心；玻璃按钮放在列表行里，阴影连成一块灰底、在行的下沿
  切一道横边，2026-11-05 以为去掉 `GlassGroup` 就好了，截图证明没好。保险箱的 `.tabs` 本来就是实心的写法。
- 分组标题、脚注的颜色不做成新的设计令牌（令牌表和 docs/ios.md 第 4 节一一对应、有测试），`Theme.groupCaption` 是两个令牌拼的。
- 根视图读页面的配色：`onPreferenceChange` 的回调在 iOS 18 SDK 起是 `@Sendable`，Swift 6 下不能直接改 `@State`，所以放进一个
  `@MainActor` 的小类、回调里 `Task { @MainActor in }` 再改。没有页面要配色时和以前完全一样（`preferredColorScheme(设置里选的)`）。
- 没改的（各组列了、我判断不该现在改）：所有分组列表的分隔线伸到卡片右边（改 `themedRow()` 动全部列表，chevron 行没验证过）；
  `RowLabel` 的图标从 13pt 放到 17pt（只有资料页报了，用了页面自己的 `ProfileRowLabel`）；保险箱卡片、联系信息表单告诉底部按钮键盘开没开
  （要给十几个输入框接 `@FocusState`，按钮现在比参考高约 12pt）。
- 截图是 main 上的（这些改动之前），所以 09 等截图里还是旧样子；所有数字都要等下一次截图确认。
