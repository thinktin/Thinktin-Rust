# r2/botin

目标：iOS 改版第 2 轮的“Botin 附加页”一组（规范 docs/ios-ui-redesign.md 4.4.3、4.4.4、4.6.2、4.6.3；参考 12–20、27–31、85–89）：
编辑页的“语音通话”组（语音、速度、语言三个 `Picker(.menu)`，本机按 Botin 存）、头像页的“形状 / 生成 / 上传”分段、
工作区画面的观看与接管（全屏黑底、工具栏、菜单、使用说明）。版式照参考 1:1 排；ThinkTin 没有后端的（语音通话、生成头像、
上传头像、画面和控制）用本地演示数据，要服务端的操作弹“即将推出”。不改 `ClientProtocol` / Mock / CoreClient。

已完成：
- 认领（2026-11-05）。
- 编辑页的“语音通话”组（参考 12、13–17、85–88，提交 “Edit Botin: voice, speed and language pickers…”）：
  - ThinktinKit `ViewModels/Agents/BotinVoice.swift`：`BotinVoice` / `BotinVoiceSpeed`（0.5x–2x 六档）/ `BotinVoiceLanguage`、
    `BotinVoiceDemoData`（28 个自己起的音色名、30 种语言，中文在前）、`BotinVoiceSettings`（宽松解码：认不出的音色、语言当没选，
    认不出的语速当 1x）、`BotinVoiceStore`（`UserDefaults` 一个键 `cn.thinktin.agents.botinVoice`，按 Botin 的 id，默认的不存，
    `shared` 给 App 用）、`BotinVoiceEditor`（草稿，“完成”才记）、`BotinVoiceText`。`InstanceDetailModel` 加 `voices:`，删 Botin 时
    一起删记录。测试 `BotinVoiceTests` 6 条。
  - 界面：`InstanceEditScreen` 最下面 `BotinVoiceSection`（三个 `Picker(.menu)`，脚注“即将推出”），“完成”先记语音设置再改名；
    资料页建 `InstanceDetailModel` 时传 `voices: .shared`。
- 头像页的分段（参考 18、19、20，提交 “Avatar page: shape / generate / upload tabs…”）：
  - ThinktinKit `ViewModels/Agents/AvatarSources.swift`：`AvatarSourceTab`、`AvatarUploadSource`、`AvatarGenerationPrompt`（最多 300 字）、
    `AvatarSourceText`。测试 `AvatarSourcesTests` 3 条。
  - 界面：`InstanceAvatarScreen` 换成 insetGrouped 的 `List`：顶上 `Picker(.segmented)` + 80pt 预览；形状（原来的卡片）、
    生成（多行输入 + 整宽玻璃胶囊“生成”）、上传（从相册选择、拍照两行 + 25 MB 脚注），生成、上传点了弹“即将推出”。
- 观看与接管（参考 27、29、30、31、89）和使用说明（28），提交 “Watch and take over…”：
  - 路由 `.instanceScreen(InstanceID)`（`.agents`、压栈、离线 `unavailable`、经过对话、标题“观看与接管”），`AppRouteTests` 样本 45 → 46。
  - ThinktinKit `ViewModels/Agents/InstanceScreen.swift`：`InstanceScreenModel`（连接中 → 只看 → 控制中，演示）、`InstanceScreenAction`、
    `InstanceScreenDemoData`、`InstanceScreenText`、`InstanceScreenHelp`。测试 `InstanceScreenTests` 5 条。
  - 界面 `Screens/Agents/InstanceScreenView.swift`：黑底深色、标题头像 + 名字、“?”、控制时“…”（触控板模式、交还给 Botin）、
    占位画面（16:10、“画面即将推出”）、iOS 底部工具栏（接管控制 / 剪贴板菜单 + 键盘），`InstanceScreenHelpSheet`；
    工作区页最上面加“观看与接管”一行；`WorkspaceHelpSheet` 和新的使用说明共用 `GroupedHelpSheet`；`AgentsDestination` 接新路由。
  - uicheck 新桩 `Stubs/SwiftUI/SwiftUI+BotinExtras.swift`：`toolbarColorScheme(_:for:)`、`UnitPoint.topLeading / bottomTrailing`。
- 界面测试 `Tests/ThinktinUITests/Agents/BotinExtrasScreensTests.swift`（语音组、三个分段、画面页各阶段和说明，浅色中文、深色英文、大字号）。
- 文档：规范 4.4.3、4.4.4、4.6.2、4.6.3 的“已做”，6.23 的“现在”，对照表 13–17、19、20、27–31、85–89 行。
- 合进最新的 `ios-ui-redesign`（收尾线删组件那一批，没冲突）后的 Linux 检查（2026-11-05）：ThinktinKit `swift test` 1103 个全过；
  uicheck UIKit、AppKit 都编过；`run.sh test` 的 ThinktinUITests 150 个全过；`swift format lint --strict` 零条。macOS CI 还没看（推送后跑）。

进行中：
- 无（这一组做完了，等合并）。

下一步：
- 合并后：首页长按删 Botin（`Shell/Home/HomeScreen.swift` 建 `InstanceDetailModel` 的地方）补 `voices: .shared`（首页归别的线，这次没改）。
- 后端有了以后：语音通话的选项和设置从服务端来、存到 Botin 上（删掉 `BotinVoiceStore`）；生成、上传头像接图片生成和存储接口；
  画面页接 docs/browser.md 的票据、画面通道、控制租约，剪贴板用 `PasteButton`、键盘用隐藏输入框；对话里“等你接管”接 `.instanceScreen`。

坑和决定：
- 只改 `Screens/Agents/*`、`ViewModels/Agents/*`、对应测试、`Navigation/` 里加一个路由；首页、`ViewModels/Shell/*` 不动（别的线在改）。
- 音色名、使用说明的文案都是自己写的，不照搬参考的名字和句子；剪贴板菜单写“本机”不写“手机”（iPad、Mac 上也对）。
- 上传头像没做成真的选图存本机：照片要画在首页、搜索、对话标题这些地方，得改共用的 `InstanceAvatar` 和 `ViewModels/Shell` 的外观存储，
  超出这一组的范围，先弹“即将推出”。
- 画面页只这一页按深色画：用 `.environment(\.colorScheme, .dark)` 和 iOS 的 `toolbarColorScheme`，不能用 `preferredColorScheme`
  （压栈的页面用它会把整个窗口变成深色）。
- 工作区页是本地 `NavigationLink` 压进来的，画面页也用本地 `NavigationLink` 压（混用路由值会把本地压的页退掉），路由留给对话等别处用。
- worktree 里的检查用 scratchpad 里的脚本跑（沙箱不让在一条命令里同时 cd 和跑 git 之外的复杂管道）。

已合进 ios-ui-redesign（a897e14）
