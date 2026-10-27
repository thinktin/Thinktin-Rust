# iOS 发版：TestFlight 与持续交付（WBS 12.19）

打 `ios-v<版本>` 标签，GitHub Actions 的 `iOS release` 工作流（`.github/workflows/ios-release.yml`）自动归档、签名、上传到
App Store Connect，进 TestFlight。上架 App Store 的材料（审核备注、隐私问卷、截图）是 12.11。

## 1. 一次性准备（要人做）

1. **Apple 开发者账号**：团队是 Siting (Shenzhen)，团队 id `5BUH46M229`（工作流里的 `TEAM_ID_DEFAULT`，团队 id 不是密钥）。
2. **App Store Connect API key**：用户和访问 → 集成 → App Store Connect API → 团队密钥 → “+”，权限选**管理（Admin）**
   （自动签名要它登记 bundle id、能力和描述文件），下载 .p8（只能下一次）。
3. **GitHub 的 `testflight` 环境**（Settings → Environments → New environment）：可以加“需要审批的人”（发版要人点一下），
   在 Environment secrets 里放三个：

   | 名字 | 内容 |
   | --- | --- |
   | `ASC_KEY_ID` | API key 的密钥 id |
   | `ASC_ISSUER_ID` | issuer id（API key 页面顶上） |
   | `ASC_KEY_P8` | 用文本编辑打开 .p8，整段复制粘贴（换行丢了也行，工作流会重排；读不出私钥会报错） |

   以前的 `ASC_KEY_P8_BASE64`（.p8 的 base64）照样认；`APPLE_TEAM_ID` 可选，配了就用它。仓库是公开的，这些只放在
   环境里，不进代码、不进日志（工作流结束时删掉解出来的 .p8）。
4. **Bundle id 和能力不用手动建**：App `cn.thinktin.Thinktin`（推送、App Groups、Time Sensitive Notifications）、小组件
   `cn.thinktin.Thinktin.Widgets`（App Groups）、App Group `group.cn.thinktin.Thinktin` 在第一次归档时由自动签名用
   API key 登记（`-allowProvisioningUpdates`）。App Group 已经在开发者网站建好了（2026-10-28）。换 bundle id 时先在
   project.yml 显式写 `PRODUCT_BUNDLE_IDENTIFIER`，App Group 名（`WidgetSnapshotFile.appGroup`）一起改。
5. **App Store Connect 里建 App 记录**（只能在网页上建，API 不支持）：App → “+” → 新建 App，iOS，名字 ThinkTin，
   简体中文，套装 ID 选 `cn.thinktin.Thinktin`（第一次归档登记之后才能选到），SKU `thinktin-ios`。App 的 Apple ID
   拿到后填进 `ShellLinks.appStore`（升级页的“去 App Store 更新”）。
6. **TestFlight 测试组**：内部测试组（团队成员，最多 100 人，不用审核）；外部测试组要过 Beta 审核（见第 4 节）。

顺序：先配好 2、3，手动触发一次只归档（Actions → iOS release → Run workflow，不勾上传），它会登记 bundle id；
再建 App 记录（5），然后勾上传再跑一次，或者打标签发版。

## 2. 发一个版本

```bash
git tag ios-v0.2.0
git push origin ios-v0.2.0
```

- **版本号**取标签（`ios-v0.2.0` → `0.2.0`，1 到 3 段数字），覆盖 project.yml 里的 `MARKETING_VERSION`。
- **构建号**是这个工作流的运行序号（`github.run_number`），只增不减，同一个版本号重新发（改了东西重打标签）也不会撞。
- 工作流：打全部 Apple 目标的 ThinktinCore（含真机 arm64，`build-apple.sh` 不带 `--ci`）→ `xcodegen generate` →
  把 `aps-environment` 改成 `production`（project.yml 里是 Xcode 直装用的 `development`；App 里 Release 构建报 `apns`
  通道，`AppConfiguration.usesAPNsSandbox`）→ `xcodebuild archive`（自动签名，用 API key 管证书和描述文件）→
  `xcodebuild -exportArchive`（`app-store-connect`，`destination: upload`，上传符号）。
- 处理完（App Store Connect 里十几分钟）内部测试组的人在 TestFlight 里就能装。
- 手动触发（Actions → iOS release → Run workflow）默认只归档不上传，用来验证工程能签名、能归档。

## 2.1 演示版（服务器上线前先看界面）

手动触发时勾上 `demo`：构建设置 `THINKTIN_CLIENT=mock` 展开进 Info.plist 的 `ThinktinClient`，App 用 ThinktinKit 的
`MockClient` 和演示数据（一打开就是登录好的，有实例、对话、计划、审批；退出后登录的验证码是 `123456`），不连服务器、
不收推送。只能手动触发，标签发版永远连服务器。版本号和正式版共用，构建号照样递增；TestFlight 的“测试内容”里写明是演示版。

## 3. 出问题时

- 归档失败：看 artifact `ios-release-logs` 里的 `archive.log`。第一次跑通前要确认真机 arm64 的 ThinktinCore 能打出来
  （`mobile.yml` 手动触发也能单独验证）。
- 签名失败：API key 的角色不够（要“App 管理”或以上），或者 App 记录、bundle id 没建。
- 上传后 App Store Connect 报 ITMS-91053（缺必需理由 API 的声明）：补隐私清单（12.11，`PrivacyInfo.xcprivacy`）。
- 出口合规：Info.plist 里 `ITSAppUsesNonExemptEncryption = false`（只用系统 TLS 和认证用的签名，属于豁免），上传后不用再答问卷。

## 4. 外部测试（Beta 审核）的材料

外部测试组第一次加构建要过 Beta 审核，要准备：

- **测试说明**：要测什么（领养 agent、发任务、审批、计划）；ThinkTin 的 agent 在云端沙箱里运行，App 不下载、不执行代码；
  模型 key 是用户自己在厂商那里的账号（BYOK）。
- **审核账号**：审核员收不到短信，要服务端支持一个固定验证码的审核账号，并预置实例、一把低额度的 key、示例计划和一次
  已完成的运行（docs/ios-packages.md 12.11 一节；**要人定**，涉及服务端）。账号和验证码填在 App Store Connect 的
  “测试信息”里，不进仓库。
- **反馈邮箱、隐私政策网址**（`https://thinktin.cn/legal/privacy`）。

## 5. 还没做的

- Rust 部分的符号：`mobile` profile 没有调试信息，崩溃报告里 Rust 栈帧没有行号（docs/ios-packages.md：发布构建加
  `debug = "line-tables-only"`，并验证一次能符号化）。
- 发版说明（What to Test）现在要在 App Store Connect 里手填；以后可以从标签的注释里取，用 App Store Connect API 写进去。
