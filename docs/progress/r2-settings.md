# r2/settings

目标：iOS 改版第 2 轮的设置补充页（规范 docs/ios-ui-redesign.md 4.9；参考 56 订阅、62–64 / 100 权限与规则、58 / 60 / 61 / 94–98 保险箱的
“+”菜单、卡片和联系信息、99 登录信息的网站、68 设备改名、71 导入记忆、76 / 77 发送反馈）。版式照参考 1:1 排（用户要先排出来、以后按真实功能删改），
ThinkTin 还没有后端的功能用本地演示数据，要服务端的操作弹“即将推出”或禁用加脚注。不改 `ClientProtocol` / Mock / CoreClient。

已完成：
- 路由（`Navigation/`）：设置功能新加 `.permissions`（权限）、`.subscription`（订阅）、`.importMemory`（导入记忆）、`.feedback`（发送反馈），
  都归 `.settings`、压栈（在设置 sheet 的栈里）、离线 `local`（演示数据 / 邮件，不用联网）、不是顶级页面、不经过对话。`AppRouteTests` 样本
  45 → 49，逐个查了功能、出现方式、离线策略、标题、顶级、返回栈。`SettingsDestination` 接上四个页面。
- 设置根页（`SettingsModel.sections`，参考 53、70、75 的位置）：第一组用量后面“订阅”；“Botin”组第一行“权限”（副标题“自动审查已开启 · 3 条规则”，
  按演示规则算），审批挪到它下面照旧进审批中心，登录设备后面“导入记忆”；链接组后面单独一组“发送反馈”（`SettingsSection.ID.feedback`）。
  `SettingsModelTests` 跟着改（分组、入口，加一条权限一行的副标题）。
- 视图模型（ThinktinKit，Linux 上测）：
  - `ViewModels/Settings/SettingsExtrasText.swift`：`SettingsComingSoon`（每种还不能用的操作一句原因）、`SettingsExtrasText`（即将推出、好、取消、
    可选、无、已复制、选择器里能选的 Botin）。
  - `PermissionRules.swift`：`PermissionRuleKind`（始终询问 / 无需询问即允许，标题、说明、占位）、`PermissionRule`、`PermissionsOverview`、
    `PermissionsDemoData`、`PermissionRuleDraft`（新建 / 修改、能不能保存、字数上限 500）、`PermissionsText`。
  - `SubscriptionPlans.swift`：`SubscriptionPlan`、`SubscriptionDemoData`（免费版是当前的，专业版“价格即将公布”；演示加载等 0.6 秒）、
    `SubscriptionModel`（`plans` 为 nil 时转圈，`loader` 可注入）、`SubscriptionText`。
  - `ImportMemory.swift`：`ImportMemoryDraft`（默认选第一个能用的 Botin、能不能添加、上限 2 万字）、`ImportMemoryText`（两步的标题、导出提示词
    中英文各一份，ThinkTin 自己写的）。
  - `FeedbackDraft.swift`：`FeedbackDraft`（能不能发、邮件正文带 App 版本 / 系统 / Botin、`mailtoURL` 按 RFC 6068 编码、`systemDescription`）、
    `FeedbackText`。
  - `ViewModels/Vault/VaultExtraForms.swift`：`VaultItemKind`（登录信息 / 卡 / 联系信息）、`VaultFieldList`（多值字段：加、删、设为首选）、
    `VaultWebsiteRules`、`VaultPostalAddress`、`VaultBillingAddressChoice`、`VaultCardDraft`（卡号整理和 Luhn、有效期、安全码）、
    `VaultContactDraft`、`VaultExtraText`。`VaultFilter` 照参考 57 加了 `.cards`（支付）、`.contacts`（联系信息），`.items` 改叫“登录信息”。
  - 测试：新 `SettingsExtrasTests`（权限、订阅、导入记忆、反馈、即将推出，16 条）、`VaultExtraFormsTests`（8 条），`VaultModelsTests` 的筛选加了两种。
- 界面（ThinktinUI，每页的做法写在规范 4.9.x 的“已做”）：
  - `Screens/Settings/SettingsExtrasComponents.swift`：`settingsComingSoon(_:)`（系统 alert）、`SettingsBottomActions`（底部浮着的全宽主按钮 +
    可选“取消”）、`SettingsMultilineField`、`SettingsCharacterCount`、`SettingsBotinPicker`。
  - `PermissionsScreens.swift`（参考 62、63、64、100）、`SubscriptionScreen.swift`（56）、`ImportMemoryScreen.swift`（71）、`FeedbackScreen.swift`
    （76、77，`mailto:`）。
  - `Screens/Account/DevicesView.swift`：设备详情的名称行带箭头，点了弹改名的系统弹窗（68），保存即将推出。
  - `Screens/Vault/VaultScreens.swift`：“+”换成系统菜单（58）、`navigationDestination(item:)` 按种类压表单；登录信息表单标题“新登录信息”、
    加网站一组（99）；筛到支付、联系信息时脚注说即将推出。新 `VaultExtraFormViews.swift`：`VaultCardFormView`（60、94–96）、
    `VaultContactFormView`（61、97、98）、`VaultWebsitesSection`、`VaultInlineField`、`vaultFieldInput`（iOS 的自动填充和键盘）。
  - 界面测试：新 `ThinktinUITests/Settings/SettingsExtrasScreensTests.swift`（4 条：四个接入点、规则表单、保险箱表单、共用组件，深浅色各布局）。
- uicheck 桩：`Stubs/SwiftUI/SwiftUI+SettingsExtras.swift`（`Font.callout`、`OpenURLAction.callAsFunction(_:completion:)`）、
  `Stubs/UIKit/UIKit+SettingsExtras.swift`（信用卡、邮箱、网址、地址的 `UITextContentType`）。
- 文档：规范 3.2 页面清单（订阅、新建条目、权限、导入记忆、发送反馈的路由）、4.9.1 / 4.9.4–4.9.10 / 4.9.14 的“已做”、第 5 节 56、58、60–64、
  68、71、76、77、94–100 行、6.15 / 6.16 / 6.20 记用户“先照参考排出来”的要求。

进行中：
- （无）

下一步：
- macOS CI 用真 SDK 编一遍（Linux 桩看不出来的：`navigationDestination(item:)` 在设置 sheet 的栈里、规则组标题里的玻璃小胶囊、`Picker(.menu)`
  的“新地址”带 `plus` 图标、`floatingBar` 的底部按钮和“取消”、改名弹窗里的 `TextField`、反馈的 `openURL` 回调、iOS 17 的信用卡自动填充类型）。
- 出截图和参考 56、58、60–64、68、71、76、77、94–100 并排对（`THINKTIN_OPEN_SCREEN` 还没加这几页，加的话改 App 的 `OpenScreen.swift`）。
- 用户按真实功能删改：订阅方案（`SubscriptionDemoData`）、演示规则（`PermissionsDemoData`）、导出提示词；后端有了接口再把对应的
  `SettingsComingSoon` 换成真操作（规则 6.15、卡片 / 联系信息 / 网站 6.16、订阅 12.23、写记忆和设备改名 6.20）。
- 反馈邮箱 `FeedbackDraft.address`（`feedback@thinktin.cn`）是占位，上线前和运营确认。

坑和决定：
- 参考 53、70 的“自动设置时区 / 时区 / Bot 电脑”没加：不在这一组，6.17 时区不做，工作区是每个 Botin 一个（在 Botin 资料里）。
- 权限页照参考放在“Botin”组第一行，审批（ThinkTin 现在真正在用的逐条批准）留在它下面，权限页里也有一行进审批中心。规则行没有箭头（参考 62），
  是按钮，点了用页面本地的 `navigationDestination(item:)` 压进修改页。
- 订阅的“转圈”是演示加载等 0.6 秒做出来的（参考 56 停在转圈）；测试注入马上返回的 `loader`。方案和价格不编：专业版写“价格即将公布”。
- 导入记忆比参考多一行“添加到”选 Botin（ThinkTin 有好几个 Botin，记忆分开）；反馈用 `mailto:` 而不是 `MFMailComposeViewController`
  （Linux 上能查类型、Mac 上也能用）。
- 保险箱胶囊照参考 57 改成“全部 / 登录信息 / 支付 / 联系信息 / 等你填写 / 处理过的”（E 线原来是“条目 / 等你填写 / 处理过的”），支付和联系信息的数
  总是 0；“+”菜单里登录信息在离线、没拉到、满了时灰，卡和联系信息总能进（本地表单）。
- 卡片表单的账单地址用 `Picker(.menu)`（不填 / 新地址），参考 94 是只有“新地址”的菜单；网站填了不保存，脚注写清楚。
- 新名字避开了 r2/connections 的 `ComingSoonAlert` / `comingSoonAlert`（那边是文件私有的），这边叫 `settingsComingSoon`、`SettingsComingSoon`。
- 合并时会冲突的：`AppRoute.swift`、`AppRoute+Title.swift`、`AppRouteTests.swift`（各线都加 case，`caseCount` 和 `index(of:)` 要合起来重排）、
  `SettingsModel.swift` 和 `SettingsModelTests.swift`（r2/connections 把第二组的 IM 渠道换成了“连接”，这边改了第一、三组和加了反馈组，行 id 的
  期望要合起来）、`docs/ios-ui-redesign.md` 的 3.2 和第 5 节（只改了自己的几行）。
- 只在 worktree 里改；没碰 `Shell/Home/*`、`ViewModels/Shell/*` 和别的线的页面（收件箱、审批、进行中、团队、运行、引导、关于、开源许可、新任务）。

Linux 检查（2026-11-05，最后一次提交上）：ThinktinKit `swift build --build-tests` + `swift test` 1114 个全过；uicheck UIKit、AppKit 都编过（这几页没有
警告）；`run.sh test` 的 ThinktinUITests 151 个全过（新加“设置补充页的界面”4 条）；`swift format -i -r apps/apple` 后
`swift format lint --strict -r apps/apple` 零条。macOS CI 和截图还没跑。
