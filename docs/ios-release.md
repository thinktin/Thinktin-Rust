# iOS 发版：TestFlight 与持续交付（WBS 12.19）

打 `ios-v<版本>` 标签，GitHub Actions 的 `iOS release` 工作流（`.github/workflows/ios-release.yml`）自动归档、签名、上传到
App Store Connect，进 TestFlight。上架 App Store 的材料（审核备注、隐私问卷、截图）是 12.11。

## 1. 一次性准备（要人做）

1. **Apple 开发者账号**（公司账号）和团队 id（10 位）。
2. **App Store Connect 里建 App 记录**：bundle id `cn.thinktin.Thinktin`（`apps/apple/project.yml` 的 `bundleIdPrefix` 生成；
   要换的话先在 project.yml 显式写 `PRODUCT_BUNDLE_IDENTIFIER`），开 Push Notifications、App Groups 能力。小组件扩展
   （12.20）的 bundle id 是 `cn.thinktin.Thinktin.Widgets`，也开 App Groups；两个都加进 App Group `group.cn.thinktin.Thinktin`
   （自动签名一般会自己登记，第一次归档失败时到开发者网站手动建）。换 bundle id 时 App Group 名（`WidgetSnapshotFile.appGroup`）一起改。App 的 Apple ID 拿到后填进
   `ShellLinks.appStore`（升级页的“去 App Store 更新”）。
3. **App Store Connect API key**：用户和访问 → 集成 → App Store Connect API，新建一个“App 管理”角色的 key，下载 .p8（只能下一次）。
4. **GitHub 的 `testflight` 环境**（Settings → Environments）：加上“需要审批的人”（发版要人点一下），放四个密钥：

   | 名字 | 内容 |
   | --- | --- |
   | `APPLE_TEAM_ID` | 团队 id |
   | `ASC_KEY_ID` | API key 的 id |
   | `ASC_ISSUER_ID` | issuer id（API key 页面顶上） |
   | `ASC_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` 的输出 |

   仓库是公开的，这些只放在环境里，不进代码、不进日志（工作流结束时删掉解出来的 .p8）。
5. **TestFlight 测试组**：内部测试组（团队成员，最多 100 人，不用审核）；外部测试组要过 Beta 审核（见第 4 节）。

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
