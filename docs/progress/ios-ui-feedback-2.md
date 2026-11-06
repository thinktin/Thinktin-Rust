# ios-ui-feedback-2
目标：用户看了 TestFlight 36 后的意见（2026-11-06）：首页顶上的“等你处理”提示行（待审批 / 未读的胶囊）参考里没有，去掉；
参考 App 选头像时头像是活的，Botin 的头像也要动起来（会眨眼、往四处看，换形状时平滑地变过去）。
原则（用户定的）：页面先照参考 1:1 还原；参考里没有的 ThinkTin 功能先不往页面上加，用户看了界面再说放哪里。
已完成：
- 去掉首页列表最上面的“等你处理”提示行：删了 `HomeAttentionRow`（界面）、`HomeAttentionHint`（ThinktinKit 模型）、
  `AppModel.homeAttentionHint`、`HomeLayout.hintInsets` 和两个测试；待审批、未读照旧在左下工作台菜单的角标和副标题上。
- 规范 docs/ios-ui-redesign.md 的 4.2.1、6.1 A1、第 1 轮分线表跟着改，写下上面的原则。
- Linux 检查全过；TestFlight 37（演示数据，Codemagic 打的，提交 `8d3c91b`）已上传。
- 会动的 Botin 头像（规范 4.4.4“会动的脸”，做法学的是开源项目 bloub 的思路，见下面“坑和决定”）：
  - ThinktinKit `ViewModels/Agents/BotinFaceLife.swift`：一个 Botin 一个种子（名字去首尾空白、转小写后的 FNV-1a 64 位），
    `pose(at:)` 给某一刻的看向和睁眼程度，`nextActiveWindow(after:)` 给下一个“动的窗口”。眨眼按 4.2 秒一槽、转眼按 2.8 秒一槽，每个槽的
    随机数用 SplitMix64 式的散列现算（种子、槽号、流号），时间的纯函数、常数时间、不会用完；时间不是有限数、太远时给不动的样子。
    测试 `BotinFaceLifeTests`。
  - ThinktinUI `Components/BotinFace.swift`：`AvatarRadialProfile`（每种形状从 `AvatarShapeGeometry` 的轮廓按 120 个方向算一圈半径，
    取最远的交点，存起来）、`AvatarRadii`（变形的动画数据，空数组是零）、`BotinFaceLayout`（眼睛的大小、位置、看向挪多远、15 种形状的
    脸的高度）、`BotinFaceShape`（身体 + 两只挖空的椭圆眼睛，奇偶规则填；半径和脸的高度能做动画）、`BotinFaceSchedule`（只在动的窗口里
    给时刻的 `TimelineSchedule`）、`BotinFace`（视图，`live` 时用 `TimelineView`）。测试 `BotinFaceTests`。
  - `Design/Environment.swift` 加环境值 `botinFaceMotion`（默认 true）。uicheck 桩补了真 SDK 里有的 `TimelineSchedule`、
    `TimelineScheduleMode`、`VectorArithmetic`、`Animatable`、`AnimatablePair`、`EmptyAnimatableData`、`Animation.snappy(duration:extraBounce:)`
    （`Stubs/SwiftUI/SwiftUI.swift`、`SwiftUI+BotinFace.swift`），`Shape` 改成和 SDK 一样继承 `Animatable`。
  - 调用处：`InstanceAvatar` 画 `BotinFace`（角标、尺寸缩放、读屏不变），所有 Botin 头像都会眨眼；形状网格的格子
    （`AvatarPicker` 的 `AvatarShapeCell`）画不眨眼的脸（`live: false`）；新建表单（120pt）和改头像页（80pt）的大预览画会动的脸，
    原来挂在上面的 `.animation(.snappy, value: appearance)` 去掉（`BotinFace` 自己做变形和渐变）。开源许可页引擎那一行
    （`AgentLicenseCard`）以前借了 Botin 的圆头像，换成和引擎目录一样的 `EngineIcon`（引擎不是 Botin，不画脸）。
  - 截图：`AppConfiguration.isScreenshotLaunch(environment:)`（`THINKTIN_SCREENSHOT=1`，或者设了认得的 `THINKTIN_OPEN_URL`、
    `THINKTIN_OPEN_SCREEN`），`ThinktinApp` 在 Debug 构建里按它启动时读一次，把 `botinFaceMotion` 设成 false；`tools/apple/screenshots.sh`
    每张都设 `THINKTIN_SCREENSHOT=1`。测试 `AppSmokeTests.screenshotLaunch`（只在 Xcode 里跑）。
  - 注释和文档：`AvatarShapes.swift`、`InstanceAvatar.swift`、`InstanceAppearanceStore.swift`、`InstanceAppearanceEditor.swift`、
    `AdoptAgentSheet.swift`、`InstanceEditScreen.swift`、`AvatarPicker.swift`、`LicenseDetailViews.swift` 的说明；规范
    docs/ios-ui-redesign.md 2.4 的表、4.4.4（新加“会动的脸”一条）、4.7.1、6.9；docs/ios.md 的共用组件。`InstanceAvatarTests` 的空名字
    注释跟着改，加了引擎、厂商、账号首字图标的渲染测试。
  - Linux 检查全过（ThinktinKit 测试、uicheck iOS / macOS 编译、ThinktinUITests、swift format lint）。
进行中：会动的头像等审查、提交；真 SDK（Xcode 26）上的编译和真机效果还没验证。
下一步：Xcode 上编一遍（重点看 `nonisolated var animatableData`、自定义 `TimelineSchedule` 的 `Entries`、`TimelineView` 外面挂两个
`.animation(_:value:)`），模拟器上看眨眼、变形和截图是不是不动；打 TestFlight 给用户看。把其他参考里没有、我们自己加上的东西列给用户，
按用户的决定删或留；用户说“合并”再合进 main。
坑和决定：
- 会动的头像学的是 bloub（GitHub `jeremy-prt/bloub`，MIT，仿 x.ai 机器人头像）的做法：身体用从中心出发的一圈半径表示，按半径插值就是
  变形；眼睛是挖出来的洞；只在动的时候重画。没有拷它的代码、常数、量出来的轮廓和配色，也不照搬 x.ai 的样子：眼睛是正对前方、不歪的
  椭圆（不是胶囊），大小、位置、每种形状的脸的高度、眨眼和转眼的节奏都是我们自己定的；15 种形状、12 种颜色没变。
- 只有 Botin 有脸；引擎、模型厂商、账号还是首字（`EngineIcon`、`CredentialVendorIcon`、`AccountAvatar`、`AvatarGlyph`）。
- 减弱动态效果：不眨眼、不转眼，换形状、颜色不做动画。环境里 `botinFaceMotion` 为 false 时一样（截图用）。
- 重画：`TimelineView` 的时间表只在眨眼、转眼的窗口里逐帧给时刻（小于 60pt 每秒 30 帧，大的 60 帧），窗口之间不给；低频模式只给一个。
- 变形的动画挂在 `.animation(_:value: shape)` 上（`.snappy(duration: 0.42, extraBounce: 0.12)`），半路再换形状时 SwiftUI 从屏幕上
  现在的样子接着变，不像 bloub 那样跳回去重来。设计稿原定 0.45 秒，审查发现和 bloub 换形状的时长一样，改成 0.42（眼睛的余量只和
  回弹有关，不受时长影响）。射线和轮廓求交点用的是课本上的叉积解法（和 bloub 的同一个公式），代码按我们自己的写法重写了一遍。
- 颜色只在挑颜色时渐变（`.animation(_:value: appearance.color)`）：没挑颜色时按名字取的颜色跟着名字变，打名字时直接换，不然每敲
  一个字，新建表单的预览和十五个格子都闪一下。
- 新建表单的预览用固定的节奏（`BotinFace(life:)`，打开表单时的名字定的）：以前按正在打的名字算种子，每敲一个字（中文输入法拼字时
  还不止一次）眼睛跳到另一个种子停着的方向。
- 节奏按名字定，所以同一个 Botin 在一屏上出现两次（团队页顶上和成员行、几个都叫“已删除的 Botin”的成员）时一起眨；不同 Botin
  的节奏互不相关。规范 4.4.4 以前写的“同一屏的头像不会一起眨”不对，改了。
- 截图：首页那两张（`00-home-empty`、`01-home`）既不设深链也不设页面，单看 `THINKTIN_OPEN_URL` / `THINKTIN_OPEN_SCREEN` 认不出是截图，
  所以加了 `THINKTIN_SCREENSHOT`，脚本每张都设。
- 弹簧冲过头最多的时候（t≈1.12，比如圆角方形变四角星）眼睛离边只有 0.0285，测试按 0.025 查（别的时刻按 0.03）；要更宽得改设计的数。
- 形状网格的格子不眨眼：一屏十五个一起动太闹，上面的大预览会动。
