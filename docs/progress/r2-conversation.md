# r2/conversation

目标：第 2 轮·对话页的附加功能，照参考 04、05（对话内查找和没匹配）、08（附件菜单）、90（完整表情选择器，连带 06 的表情行）、
11（选择主 Botin 的空状态）1:1 做版式（规范 4.3.3–4.3.6、4.4.5）。从 `ios-ui-redesign` 分出来，做完由整合的人合回去。

已完成：
- （开工，2026-11-05）

进行中：
- 对话内查找（4.3.3，参考 04、05）。

下一步：
- 附件菜单（4.3.6，参考 08，点了“即将推出”）；表情回应（参考 06 的表情行 + 90 的选择器，只存这台设备）；选择主 Botin（参考 11）。
- 全部 Linux 检查、规范里的“已做”。

坑和决定：
- 只动 `Screens/Conversation/*`、`ViewModels/Conversation/*`、`Components/ComposerBar.swift`、路由加 case、桩；不动 `ClientProtocol` / `MockClient` / `CoreClient`。
