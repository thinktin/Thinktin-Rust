# ios-ui-feedback-3
目标：用户 2026-11-06 的三条意见：
1. 等你审批的 Botin 也要动（提醒你去处理）。
2. 参考稿里没有、我们自己加上的东西都删掉（页面先照参考 1:1，功能放哪里用户再定）；法规要求的留着并说明。
3. 头像颜色太暗，换成鲜明的颜色。
总账在规范 docs/ios-ui-redesign.md 1.5（删了什么、留了什么、哪些页没入口了），各页的细节在第 4 节对应的地方。

已完成：
- 五块分头改（首页、对话、Botin 资料和工作区、设置、头像），合起来以后补了各块交代给别处的改动，Linux 上全部编过、测过。
- 等你的 Botin 会动（规范 4.4.4）：`BotinFaceMood.waiting` 现在 `isAlive`。眼睛睁大往上看、照样眨眼，每 3.4 秒连着小跳两下
  （`BotinFaceGesture.doubleHop`，所有在等的一起跳），两次之间不动。首页的行、置顶、长按预览卡、对话标题本来就传 `waiting`，不用改。
  测试 `BotinFaceLifeTests.waitingCallsForAttention` 等。
- 头像换成鲜明的颜色（规范 4.4.4“鲜明的颜色”、4.7.1、6.9）：`AvatarColor` 换成红、橙、琥珀黄、绿、薄荷绿、天蓝 / 蓝、紫罗兰、紫、粉、
  棕、灰，色值在 `InstanceAvatar.color(of:)`（浅深一个值）。旧的 8 个原始值读的时候换成最接近的新颜色（`AvatarColor.legacyValues`），
  下次存写新的。引擎、厂商的首字图标还是原来暗一点的 8 种（`AvatarGlyph.palette`，上面有白字）。色板的选中环换成中性灰（亮色的同色环看不见）。
  测试里用旧颜色名的地方（9 个文件）改成新的。
- 删掉的（都写进了规范，“2026-11-06 用户要求删掉、参考里没有”）：
  - 首页：左下的工作台菜单和总角标（`WorkbenchMenu.swift`、`WorkbenchEntry`、`ShellBadges` 里给它用的几样、`refreshBadges` 里拉计划的
    那一次；Glass.swift 的工具栏角标帮手和测试）。左下换成参考 01 那个玻璃圆，点了进“连接”目录（`HomeConnectionsButton`）。只隐藏一部分时
    列表底下的“已隐藏 N 个 Botin”。
  - 对话页：工具调用卡片、审批卡片、每组最后的运行状态行（和上面的重试），只在运行详情的“只看本次过程”里还有
    （`ConversationItem.Content.showsInConversation`）；输入框上面的默认模型胶囊；查找栏上面的“加载更早的再找”。
  - Botin 资料：默认模型、所在团队、信息三组（`InstanceDetailModel` 不再拉 agent、路由、团队）。工作区：状态、引擎一组、升级、右上“?”和说明。
    跟着没人用的 `AgentsText.stateExplanation`、`AgentInfo.hasUpgrade(from:)` 和测试也删了。
  - 设置根页：模型 key、审批、实时活动的两个开关、“安全”一组（全部停止、下线其他设备）、上手引导。跟着删了 `StopAllRow.swift`、
    `StopAllModel` 和测试、`LiveActivityText` 里设置用的文案、`OnboardingText.settingsRow`；`LiveActivitySettingsSection.swift` 删了，
    运行页的按钮挪进 `LiveActivityRunButton.swift`。退出登录确认框里叫人去用“全部停止”的那句改成指向登录设备页和快捷指令。
- 留着的（法规、上架要求，规范 1.5）：“AI 生成”标识；举报（不在用户点名的清单里，但《生成式人工智能服务管理暂行办法》第十五条
  和 App Store 1.2 要求，删之前要用户确认）；隐私政策、用户协议（设置里参考放链接的那组）；关于 ThinkTin（备案号）、开源许可
  （接在同一组后面，参考那里是产品条款）；账号页的注销账号。
- 各处的注释、文档跟着改：路由（`isTopLevel`、`openTopLevel`、`.instance`、`.instanceScreen`、`.hiddenBotins`）、审批、模型路由、
  key、收件箱、进行中、团队、计划、产出物、实时活动、引导的说明里不再提工作台、抽屉、设置里删掉的行；`AppConfiguration.OpenScreen`
  的说明；规范 docs/ios-ui-redesign.md（新加 1.5，改了 1.2、1.3、3.1、3.2、4.2.1、4.2.3、4.3.1、4.3.3、4.4.1、4.4.4、4.6.1–4.6.3、
  4.7.1、4.8.1、4.9.1、6.1、6.9）、docs/ios-ui-redesign-shots.md、docs/ios.md。
- 检查（2026-11-06，Linux）：ThinktinKit `swift build --build-tests` + `swift test` 1179 个全过；uicheck iOS、macOS 编译过；
  uicheck ThinktinUITests 189 个全过；uicheck `ThinktinTests` 只有 5 个 Linux 上本来就过不了的 Info.plist / 包内资源的测试没过；
  `swift format lint --strict` 没有问题。

- 审查后补删、补改（2026-11-06 同一天，规范 1.5 的表已更新）：
  - 首页长按菜单照参考 32、33：置顶 / 取消置顶、替换主 Botin…（以前漏了）、隐藏，“更多”里只有复制 ID；Botin 资料、新建计划、改名…、
    删除删了（`HomeRenameAlert`、`AppModel.renameInstance`、`HomeDeletion` 一起删）。资料页“…”照参考 10：替换主 Botin…、复制 ID；
    模型路由、新建计划、删除删了。对话“…”照参考 03：Botin 资料、在对话中查找；计划 / 新建计划 / 产出物 / 模型路由 / 停止删了
    （停止用输入框的停止按钮）。资料页“计划”行值去掉“· N 个待确认”。
  - 首页的行、置顶、长按预览卡、已隐藏页：状态字、“你：”、警告色、状态角标、预览卡的状态行都删了；第二行总是最后一条
    （`HomeRow.previewText`），只有主 Botin 有星标；读屏照样念状态（`HomeRowPreview.spokenStatus`）。
  - 在等你的优先：旁边还有排队的运行时脸也是 `waiting`（以前算在跑，首页不跳）。
  - 资料页“工作区”行直接进观看与接管（参考 27），工作区设置页去掉“观看与接管”一行，只剩参考 65 的两组，现在没有入口。
  - 首页左下的“连接”照参考 36 弹 sheet（`Router.presentFromHome`，`SheetStack` 补 ×）；`openTopLevel` 删了。
  - 对话页上失败、取消的那一组最后加一行居中小灰字“任务没完成 · 再发一次”（`RunEndNotice`），不然失败了什么都看不出来。
  - 实时活动：以前存的两个开关的选择不再读、启动时删掉；以前打开过计划运行的，下次回到前台清掉服务端的推送开启令牌。
  - 检查（Linux）：ThinktinKit 1181 个全过；uicheck iOS、macOS 编译过，ThinktinUITests 189 个全过；`ThinktinTests` 只有 5 个
    Info.plist / 包内资源 / 缓存路径的测试没过（Linux 上本来就过不了）；`swift format lint --strict` 没有问题。

进行中：无（等负责人提交、推送）。

下一步：
- Xcode 26 上编一遍、跑模拟器测试，打 TestFlight 给用户看。
- 用户定下面这些没入口的东西放哪（页面和路由都留着，深链、推送、以后的入口还能用）：
  - 收件箱 `.inbox`：只能从推送、深链 `thinktin://inbox`、状态小组件进。
  - 进行中 `.activeRuns`：只能从深链 `thinktin://active`、小组件进。
  - 团队 `.teams`（和团队详情、团队模板、流水线编辑）：哪儿都进不去（没有深链）。
  - 全部 Botin 的产出物 `.artifacts(instanceID: nil)`：哪儿都进不去（没有深链）。
  - 全部计划 `.plans(instanceID: nil)`：只剩计划确认页、计划详情里的“看全部计划”。
  - 已隐藏的 Botin `.hiddenBotins`：只有都隐藏了时的空状态能进；只隐藏一部分时进不去（藏了一个就找不回来，除非全藏）。
  - 审批中心 `.approvals`：权限页的一行、运行详情、推送、深链 `thinktin://approvals`。
  - 上手引导 `.onboarding`：只自动弹一次，没有深链。
  - 实时活动的两个开关、换引擎版本（升级、回滚）：没有界面。
  - ~~删除 Botin~~：2026-11-07 用户定先放在对话页右上“…”的最后一组（红字“删除这个 Botin”，参考 03 没有这一项），点了弹
    `InstanceDeleteSheet`，删成了回首页。
  - **工作区设置**（重置工作区、磁盘空间，参考 65）：参考从设置的“Bot 电脑”进，那台电脑是所有 Bot 共用的；我们每个 Botin 一个沙箱，
    放设置里得先选 Botin。两行都是“即将推出”，暂时没入口不少功能。
- 用户还没点名、参考里也没有、这次也没删的（规范 4.3.1、4.9.1 各有一条“没删、要用户定的”）：对话页里产出物、子运行、计划确认、
  保险箱填写的卡片，“再发一次”“分享”；权限页里进审批中心的一行；观看页“…”里的“交还给 Botin”和说明页的脚注。

坑和决定：
- 对话页和“只看本次过程”共用一条时间线，所以卡片、状态行不删视图，只在对话页不放（一个纯函数，测试查）；运行详情的“去审批”找不到
  卡片时以前去对话里找，现在去审批中心。对话页加载时还会拉审批记录（给不再显示的卡片用），多几次请求，不影响，以后可以只在
  “只看本次过程”里拉。
- 审批现在只能从推送、审批中心（权限页、运行详情、深链）批；对话页上“它在等你”只靠标题上的头像会动和推送。
- 对话页失败、取消的“没做完”一行不算参考里的元素，是错误状态（不然失败了只剩用户的气泡），用参考 02 的小灰字样式。
- 首页行上不写状态以后，读屏照样念（看得见的人看脸）：无障碍不是加在页面上的元素。
- 已隐藏页的头像照参考 114 连主 Botin 的星标也不画。
- 首页左下的图标用 `square.grid.2x2`：参考是三个方块加一个“+”，Linux 上找不到能确认存在的更像的 SF Symbol，Mac 上有的话换
  `HomeConnectionsButton.systemImage`。
- 新颜色浅深一个值：深色底上最暗的棕也有 3.15:1；浅色底上琥珀黄、薄荷绿的亮度对比不到 2:1，但色差都在 ΔE 36 以上，测试按色差查。
  按名字取的 8 种下标照旧，0–5 只是变亮，6、7 从石板灰、棕变成橙、绿，这两种名字的 Botin 会换颜色。
- 在等的 Botin 一起跳（开始时刻不按 Botin 随机），首页好几个在等时是整齐的一下，用户觉得怪可以改成按种子错开。
- 账号行的中性灰头像（`AccountAvatar`）照参考 53、54，没换鲜明的颜色。
- uicheck 的 Gen 目录每次 run.sh 都重新生成，不用手改；这次没加桩。
