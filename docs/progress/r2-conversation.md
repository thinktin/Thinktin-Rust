# r2/conversation

目标：第 2 轮·对话页的附加功能，照参考 04、05（对话内查找和没匹配）、08（附件菜单）、90（完整表情选择器，连带 06 的表情行）、
11（选择主 Botin 的空状态）1:1 做版式（规范 4.3.3–4.3.6、4.4.5）。从 `ios-ui-redesign` 分出来，做完由整合的人合回去。

已完成：
- 对话内查找（4.3.3，参考 04、05）：“…”菜单加“在对话中查找”，输入框换成 `ConversationFindBar`（查找框 + 计数、上下两个玻璃圆、
  “完成”），高亮所有匹配、当前这一处实心，跳过去时先滚到那一组再居中；上面还能翻时提示加载更早的。逻辑在 ThinktinKit 的
  `ConversationFind.swift`、`MarkdownInline.swift`，测试 `ConversationFindTests`（ThinktinKit）、`ConversationExtrasTests`（界面）。
  桩：`SwiftUI+ConversationExtras.swift`（`AttributedString` 的 SwiftUI 属性 `backgroundColor` / `foregroundColor`、
  `AccessibilityNotification.Announcement`、`menuIndicator`）。

进行中：
- 附件菜单（4.3.6，参考 08，点了“即将推出”）。

下一步：
- 表情回应（参考 06 的表情行 + 90 的选择器，只存这台设备）；选择主 Botin（参考 11）。
- 全部 Linux 检查、规范里的“已做”。

坑和决定：
- 查找的位置按“画出来的字”算：一个 `Text` 是一段（`MarkdownBlock.findSegments` 和 `MarkdownBlockView` 的顺序必须一致，改其中一个要
  跟着改另一个），行内 Markdown 用 `InlineText.plainText`（对话页在 `ConversationContent.init` 里塞给 `model.find.plainText`）。
  Linux 的 Foundation 没有 `AttributedString(markdown:)`，Kit 里默认用 `MarkdownInline.plainText` 近似。
- 回车 = 上一个（更早）：一开始停在最新一处（最下面），往前翻才有“下一个”。上下到头都绕回。
- 只动 `Screens/Conversation/*`、`ViewModels/Conversation/*`、`Components/ComposerBar.swift`、路由加 case、桩；不动 `ClientProtocol` / `MockClient` / `CoreClient`。
