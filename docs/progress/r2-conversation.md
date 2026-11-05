# r2/conversation

目标：第 2 轮·对话页的附加功能，照参考 04、05（对话内查找和没匹配）、08（附件菜单）、90（完整表情选择器，连带 06 的表情行）、
11（选择主 Botin 的空状态）1:1 做版式（规范 4.3.3–4.3.6、4.4.5）。从 `ios-ui-redesign` 分出来，做完由整合的人合回去。

已完成：
- 对话内查找（4.3.3，参考 04、05）：“…”菜单加“在对话中查找”，输入框换成 `ConversationFindBar`（查找框 + 计数、上下两个玻璃圆、
  “完成”），高亮所有匹配、当前这一处实心，跳过去时先滚到那一组再居中；上面还能翻时提示加载更早的。逻辑在 ThinktinKit 的
  `ConversationFind.swift`、`MarkdownInline.swift`，测试 `ConversationFindTests`（ThinktinKit）、`ConversationExtrasTests`（界面）。
  桩：`SwiftUI+ConversationExtras.swift`（`AttributedString` 的 SwiftUI 属性 `backgroundColor` / `foregroundColor`、
  `AccessibilityNotification.Announcement`、`menuIndicator`、`onLongPressGesture`）。
- 附件菜单（4.3.6，参考 08）：输入框左边玻璃圆“+”，系统菜单三项（照片或视频、拍照、选择文件；Mac 没有拍照），点了弹“即将推出”。
  ThinktinKit 的 `ConversationAttachments.swift`（`ComposerAttachmentSource`、`canAttach`），测试 `ConversationAttachmentTests`。
- 表情回应（参考 06、90）：iPhone 长按消息改成参考 06 的面板（两排表情 + 分组操作，“标为未读”即将推出），“更多表情”是参考 90 的
  选择器，回应画在气泡下面，只存这台设备。ThinktinKit 的 `MessageReactions.swift`（`MessageReactionStore`、`EmojiCategory`、
  `EmojiCatalog`），界面 `MessageReactionViews.swift`、`MessageMenus.swift`；测试 `MessageReactionsTests`、`ConversationExtrasTests`。
- 选择主 Botin（参考 10、11）：新路由 `AppRoute.primaryBotin`（sheet），页面 `PrimaryBotinPickerScreen`（×、确认、单选列表、
  底部搜索、“暂无其他可选的 Botin”），入口是 Botin 资料“…”菜单的“替换主 Botin…”；只存这台设备（ThinktinKit `PrimaryBotin.swift`）。
  测试 `PrimaryBotinTests`、`AppRouteTests`、`InstanceProfileTests`、`ConversationExtrasTests`。
- Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift test` 1095 个全过；uicheck UIKit、AppKit 都编过；`run.sh test`
  152 个全过；`swift format lint --strict` 零条。macOS CI 还没看（真 SDK 上 `AccessibilityNotification` 要不要单独
  `import Accessibility`、`AttributedString` 的 `backgroundColor` 在 `Text` 里画不画，都在 CI 上看）。

进行中：
- 无（这条线的四件事都做完了，等整合）。

下一步：
- 交给整合的人：新任务（`NewTaskSheet`）、快捷指令、小组件默认选 `PrimaryBotinStore.shared.primaryID`；资料页头像加主 Botin 的星标
  （参考 10）；注销账号时清掉 `MessageReactionStore` / `PrimaryBotinStore`。
- 要在模拟器上看的（Linux 桩看不出来）：查找栏在 375pt 宽的机器上挤不挤、计数文字会不会截断；高亮的底色在深浅色下的可读性；
  `onLongPressGesture` 在滚动的时间线里会不会误触、和链接的点按冲不冲突；长按面板中号时两排表情加列表放不放得下；
  `Picker(.inline)` 在 iOS 26 sheet 里的打勾样式；`Menu` 套 `glassButtonStyle` + `.circle` 的“+”是不是圆的。

坑和决定：
- 查找的位置按“画出来的字”算：一个 `Text` 是一段（`MarkdownBlock.findSegments` 和 `MarkdownBlockView` 的顺序必须一致，改其中一个要
  跟着改另一个），行内 Markdown 用 `InlineText.plainText`（对话页在 `ConversationContent.init` 里塞给 `model.find.plainText`）。
  Linux 的 Foundation 没有 `AttributedString(markdown:)`，Kit 里默认用 `MarkdownInline.plainText` 近似。
- 回车 = 上一个（更早）：一开始停在最新一处（最下面），往前翻才有“下一个”。上下到头都绕回。
- 长按：iPhone 上 `messageMenu` 不再是 `.contextMenu`，是 `onLongPressGesture` 弹 `MessageActionSheet`（系统长按菜单放不下表情，
  规范 4.3.4 早就写了“真要做表情时改成 sheet”）。面板里点的操作记在 `pending`，面板关掉（`sheet(item:onDismiss:)`）以后再做；
  一个视图上只挂一个 `.sheet(item:)`（`MessageSheet`：面板、选择文本、Mac 的表情选择器），别再加第二个。`previewShape` 参数现在
  没用了，留着是为了运行详情（别的线在改）的调用处不用改。
- 回应的键是时间线里那一项的 id（事件序号），事件流重置后对不上，旧回应就看不到了。删了 Botin 时 `InstanceDetailModel.delete()`
  顺带 `MessageReactionStore.shared.forget(instanceID:)`、`PrimaryBotinStore.shared.forget(instanceID:)`；注销账号时没删
  （`DeleteAccountView` 只删了头像外观）。
- Botin 资料“…”菜单（`InstanceProfileMenu`，ThinktinKit `ViewModels/Agents/InstanceProfile.swift`）第一组加了“替换主 Botin…”：
  r2/botin 也在改 Botin 资料那一块，合并时这一组以“替换主 Botin…、复制 ID”为准（参考 10），别加出两个。
- 长按面板里“标为未读”、附件“+”的三项都是“即将推出”：`MessageMenuAction.isComingSoon`、`ComposerAttachmentSource.isAvailable`，
  后端有了以后改这两处。
- `AppRoute.primaryBotin` 归 `.conversation`（`ConversationDestination` 接），这样不用动别的线的接入点；r2/connections 也在加路由，
  合并时 `AppRoute.swift`、`AppRoute+Title.swift`、`AppRouteTests.swift`（`RouteSamples` 的下标和 `caseCount`）会冲突，两边的 case 都留、
  下标顺着排。
- 只动 `Screens/Conversation/*`、`ViewModels/Conversation/*`、`Components/ComposerBar.swift`、路由加 case、桩；不动 `ClientProtocol` / `MockClient` / `CoreClient`。

已合进 ios-ui-redesign（7de7dd0）
