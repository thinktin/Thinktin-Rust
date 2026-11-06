# ios-ui-feedback-2
目标：用户看了 TestFlight 36 后的意见（2026-11-06）：首页顶上的“等你处理”提示行（待审批 / 未读的胶囊）参考里没有，去掉。
原则（用户定的）：页面先照参考 1:1 还原；参考里没有的 ThinkTin 功能先不往页面上加，用户看了界面再说放哪里。
已完成：
- 去掉首页列表最上面的“等你处理”提示行：删了 `HomeAttentionRow`（界面）、`HomeAttentionHint`（ThinktinKit 模型）、
  `AppModel.homeAttentionHint`、`HomeLayout.hintInsets` 和两个测试；待审批、未读照旧在左下工作台菜单的角标和副标题上。
- 规范 docs/ios-ui-redesign.md 的 4.2.1、6.1 A1、第 1 轮分线表跟着改，写下上面的原则。
- Linux 检查全过；TestFlight 37（演示数据，Codemagic 打的，提交 `8d3c91b`）已上传。
进行中：等用户装 37 看。
下一步：把其他参考里没有、我们自己加上的东西列给用户，按用户的决定删或留；用户说“合并”再合进 main。
坑和决定：无。
