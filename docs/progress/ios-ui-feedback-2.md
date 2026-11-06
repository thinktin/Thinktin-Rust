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
- 会动的头像：Xcode 26 上编过、测过（GitHub iOS 工作流 103 次全绿：模拟器上的 ThinktinTests/ThinktinUITests、Mac 编译、macOS 上的
  swift test），TestFlight 38（演示数据，Codemagic 打的，提交 `e6a5164`）已上传。
- 头像的动作和状态（用户看了 38 以后定的三条：“没有运行中的会话就不要眨眼或者有动作了”“在会话列表里运行中也要随机展示动作”
  “选头像的时候，选中时候要有动作展示”；规范 4.4.4“会动的脸”重写了）：
  - ThinktinKit `BotinFaceLife.swift`：`BotinFaceMood`（`resting` 不动、`active` 在跑、`waiting` 等用户睁大眼往上看、`sleeping` 暂停闭眼、
    `still` 归档删除闭眼；只有 `active` 会自己动），从运行、实例的状态推（`init(run:)`、`init(instance:)`、`init(state:activity:)`，
    `HomeRowPreview.faceMood`、`AppModel.faceMood(for:)`）。`Pose` 加了身体上下挪、横竖伸缩、歪、眼睛放大、笑眼；`active` 时每 6 秒一个槽、
    70% 的槽里随机做一个小动作（跳一下 30%、歪头 25%、笑一下 25%、点头 20%，`BotinFaceGesture`），做小动作时眼睛不自己转（那一下转眼挪到
    小动作做完）。反应 `BotinFaceReaction`（点一下 `tap`、笑一下 `happy`，记开始的时刻，什么状态都做）。都是时间的纯函数。
    测试 `BotinFaceLifeTests` 重写（16 个，审查后加了 `activeSince`，17 个）。
  - ThinktinUI `BotinFace.swift`：笑眼（“∩”，48 个点按同一个角度参数插值）、睁大、身体和眼睛一起做的仿射变换（`BotinBodyTransform`）；
    `BotinFace(mood:reactions:)`：只有 `active` 和正在做反应的有 `TimelineView`（反应做完 `.task` 让它换回不动的脸），别的画一张不动的脸；
    时间表 `BotinFaceSchedule` 带上状态和反应。去掉了 `live` 参数。
  - `InstanceAvatar(mood:reactions:)`：默认从角标推状态（`mood(for:)`）；首页的行、置顶、隐藏页、长按预览卡给 `row.preview.faceMood`；
    对话标题按这一页的当前任务（没有时按实例的状态）；资料页头部、编辑页、搜索、审批、团队、远程屏幕标题、引擎详情、选 Botin 的行给
    `AppModel.faceMood(for:)`。资料页头部的头像点一下跳一下、轻震（`appFeedback(.impact(weight: .light))`）。
  - 选头像（`AvatarPicker.swift`）：选中的那一格选中时做 `tap` 反应、选着时是 `active`，别的格子不动；新加的 `AvatarPickerPreview`
    （新建表单、改头像页共用的大预览）一直是 `active`，挑了形状、颜色 0.3 秒后笑一下，点一下跳一下。新建表单的格子和预览用同一个节奏。
  - 测试 `BotinFaceTests`：眼睛在身体里面的扫一遍（15 种形状 × 在跑时 20 秒每一帧、每个小动作和反应从头到尾、不动的表情、几次反应
    叠到头，余量 ≥ 0.03，最紧的四角星约 0.046）、笑着变形、身体变换、笑眼的几何、只有反应的时间线、状态从角标推；原来的测试改成带状态。
  - 没加桩（`onTapGesture`、`onChange`、`task(id:)`、`TimelineView` 都有）。Linux 检查全过。
  - 审查后改的四处：
    - 状态变成 `active` 时第一帧不再跳到半路：`BotinFaceLife.pose(at:mood:since:reactions:)`、`nextActiveWindow(after:mood:since:reactions:)`
      多了 `since`（这次进入这个状态的时刻，默认 -∞），那以前开始的眨眼、转眼、小动作不算，第一次转眼从正前方转过去；`BotinFace`
      活的那一支拆成 `BotinLiveFace`，出现时用 `@State` 记下 `since`，状态变了给它换 id 重新记。`BotinFaceSchedule` 带上 `since`。
      从 `active` 换成别的状态照旧直接换成不动的脸（写进了规范）。测试 `activeSince`：300 个开始时刻 × 6 个种子，那一刻正好不动、
      之后连续、窗口从那以后算、15 秒后和一直在跑的一样；`BotinFaceTests.schedule` 加了一组带 `since` 的。
    - 跳起来会冒出方框：说明以前写“身体基本还在方框里”不对（单次跳约 0.102 倍边长，叠着点能到 0.14–0.18）。画的时候头顶最多冒出
      0.10（`BotinFaceLife.Limits.lift`，`BotinFaceShape.transform` 多了往下挪回来的那一下，只跳一下时只削掉不到 0.002）；资料页头部、
      编辑页顶上的头像上面的 8pt 换成 `ProfileAvatarHeadroom`（0.10 倍头像边长，默认字号还是 8pt，跟着动态字体缩放）。测试
      `liftStaysWithinLimit`。
    - 一个运行在等用户、另一个还在跑时脸是 `active`（以前是不动的 `waiting`）：`BotinFaceMood(state:activity:)` 改了，首页的行、置顶、
      隐藏页、长按预览卡改用新加的 `HomeRow.faceMood`（`HomeRowPreview.faceMood` 只看得到角标上在等的那个）。
    - 删掉没人用的 `BotinFaceReaction.init(_:at:)`。
进行中：等提交、打 TestFlight 39 给用户看动作。
下一步：按用户对头像的意见调（眼睛大小、位置在 `BotinFaceLayout`，眨眼、转眼、小动作的节奏和幅度在 `BotinFaceLife.Timing`；
`waiting` 要不要动、要的话怎么动等用户说）；把其他参考里没有、我们自己
加上的东西列给用户（已列了 7 处，等回复），按用户的决定删或留；用户说“合并”再合进 main。
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
- 形状网格的格子只有选中的那一个动：一屏十五个一起动太闹，上面的大预览也会动。
- 只有在跑的（`active`）会自己动，等用户（`waiting`）也不动（用户的第一条），以后要它动再加。暂停、归档不再“呼吸”，闭着眼不动。
- 动作、时长、幅度、概率都是我们自己定的，没照 x.ai 的编排（没有轨道环、彗星、爆开、感叹号、三个点、通知小圆点、漩涡）。
- 睡着的眼睛是“缝 0.12、放大 1.12 倍”（`Pose` 里没有只放宽的项，闭着的眼睛只剩一条缝，看着就是宽了一点，比只放宽高 0.002）。
- 反应改的是 `reactions`，`TimelineView` 跟着新的时间表重新取时刻；没给它按反应换 id：换了会打断正在做的变形（预览挑了形状以后是一边
  变形一边等着笑）。不在跑的头像做反应时临时换成有 `TimelineView` 的那一支，做完由 `.task(id:)` 睡到结尾再换回不动的（不在每个头像
  上常驻时间线）。
- 几次反应叠在一起时身体的挪动相加、伸缩相乘，最后夹在范围里（上下最多 0.08，伸缩 0.88 到 1.10）；测试按“横竖都压到 0.88、笑眼、
  看到最远”这个最坏的情况查眼睛的余量。
- 笑着变形、又赶上动画半路被打断冲过头 12% 时（圆角方形 → 四角星），眼睛离边约 0.02（48pt 上约 1pt），这一档按 0.02 查；
  平常的回弹（约 4%）照样按 0.03。
- 变成 `active` 的那一刻记在 `BotinLiveFace` 的 `@State`（建这个视图时的时刻），状态变了靠 `.id(mood)` 重建来重新记：不用
  `.onChange` 记，因为改 `@State` 要等到下一次更新，换状态的第一帧还是旧的时刻，正好就是要修的那一跳。按状态换 id 会打断正在做的
  变形，但状态很少和形状一起变（从不动的那一支换过来本来就是新建的）。
- 从 `active` 换成别的状态（运行结束、选头像时换到别的格子）直接换成不动的脸，不让正在做的小动作做完：那样还得让眼睛转回来、
  眨眼睁开，要再加一段动画；用户定的是“不在跑就不动”。反应（用户点出来的）照样做完。
- 头顶冒出方框的上限 0.10 是按“一次跳一下正好够得着”定的，没改跳的曲线（起跳拉长 1.06 是设计稿的数）；叠着点、歪着头被点时往下挪回来。
  首页的行、置顶、新建表单和改头像页的大预览上面本来就留够了，只改了资料页头部和编辑页顶上这两处贴边的行。
- 一个在等用户、一个在跑：按用户的第二条（有在跑的就动）算 `active`，角标照旧画在等的那个（警告色，提醒去处理）。要是用户觉得这时该
  睁大眼睛等着，改 `BotinFaceMood(state:activity:)` 一处就行。
