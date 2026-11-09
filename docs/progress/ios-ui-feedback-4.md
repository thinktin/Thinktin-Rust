# ios-ui-feedback-4
目标：用户 2026-11-09 装了 TestFlight 40 后的两条：
1. 没有入口的几页“先待定”：这次不动，放哪里等用户再说（规范 1.5 的表）。
2. “还不错，但不运行中的会话不用动”：只有有任务在跑的 Botin 会动；等你审批（等电脑、等额度）的也不动了，只保留睁大眼、往上看的
   静止表情（演示数据里的“写作助手”就是这种，40 里它在连跳）。

已完成：
- 等你的 Botin 不动了（规范 1.5“等你的 Botin”、4.4.4 的 `waiting`）：`BotinFaceMood.isAlive` 只剩 `active`，`waiting` 没有时间线
  （`BotinFace` 不给它 `TimelineView`），`BotinFaceLife.pose(at:)` 给的一直是 `restPose(for: .waiting)`（眼睛睁大 1.12 倍、往上看 -0.35），
  `nextActiveWindow` 除了反应没有窗口。用户点出来的反应（资料页点头像、选头像时选中、挑形状颜色）在哪个状态都照样做。
- 删掉连跳：`BotinFaceGesture.doubleHop`、`Timing` 里的 `waitingSlot`、`doubleHop*`，`doubleHopStart`、`nextDoubleHopWindow`、
  在等时动的那段，`hopBody` 给连跳用的缩小参数。`waitingEyeScale`、`waitingGazeY` 留着。`BotinFaceLife.swift` 基本回到 2026-11-06
  加连跳以前的样子，只是说明改成现在的说法；在等的优先（`BotinFaceMood(state:activity:)`）照旧。
- 说“在等的会动”的注释都改了：`BotinFaceLife`、`BotinFace`、`InstanceAvatar`、`AvatarShapes`、`InstanceAppearanceStore`、
  `HomeRow` / `HomeRowPreview.faceMood`、`AppModel.faceMood`、`HomeInstanceRow`、对话页标题（`ConversationScreen`）、`HomeListTests`。
- 测试：`BotinFaceLifeTests` 回到只有 `active` 会动的写法，`waiting` 放回不动的状态里（一直是这张脸、没有窗口，反应照样做），
  新加 `waitingStaysStill`（60 秒每 1/240 秒一帧、刚变成在等的也一样、只有反应的窗口）；删了连跳的测试。`BotinFaceTests`：
  时间线只测在跑的，“只有反应”的那条把 `waiting` 加回去；眼睛在身体里面的样子里去掉在等时 20 秒的帧和连跳，反应照样叠在
  睁大眼睛往上看的脸上测。
- 规范 docs/ios-ui-redesign.md：1.5（开头一句、表格、“等你的 Botin”一段）、4.2.1、4.3.1、4.4.4（`waiting`、状态变了、从哪儿知道在跑、
  只在动的时候重画，加了“已做（2026-11-09）”一条）都写了 11-09 改回来。4.4.4“从哪儿知道在跑”里还写着 11-06 以前“一个在等、一个在跑
  算 `active`”，顺手改成现在的“在等的优先”。
- Linux 上全部检查都过了：ThinktinKit 的 swift build / test（1181 个测试）、uicheck 的 UIKit 版、AppKit 版、test（ThinktinUITests 189 个）、
  swift format lint --strict。

- Xcode 26 上编过、测过（GitHub iOS 工作流 111 次全绿），TestFlight 41（演示数据，Codemagic 打的，提交 `4acee18`）已上传。
进行中：等用户装 41 看。

下一步：
- 提交、推送（这一步由主会话做）。
- Xcode 上编过，打 TestFlight 41 给用户看。
- 第 1 条“先待定”的几页（工作区设置、团队等，规范 1.5 的表）等用户定放哪。

坑和决定：
- 在等的优先没改：一个运行在等审批、旁边还有没结束的（多半是在它后面排队的）时，脸还是 `waiting`（静止、睁大眼睛），不算在跑。
  首页的行上没有状态字，在等你全靠这张脸；要是用户觉得这种时候也该动，改 `BotinFaceMood(state:activity:)` 就行。
- 在等的不眨眼：用户说的是“不用动”，眨眼也算动，所以和暂停、平时一样整张脸不动；它和平时不一样的只有睁大、往上看。
