# iOS 上架 App Store（WBS 12.11）

提交审核前要准备的东西。打包上传见 [docs/ios-release.md](ios-release.md)（12.19），安卓的商店材料见
[docs/android-release.md](android-release.md)。标“要人定”的不是代码能做的。

## 1. 首发地区与备案（要人定）

- 在中国大陆 App Store 上架要在 App Store Connect 填 **ICP 备案号**；App 备案按 bundle id 办，bundle id
  （`cn.thinktin.Thinktin`）要先定下来。备案号拿到后填进 `AppInfo.icpFilingNumber`（关于页显示，能点开去工信部查），
  安卓填 `ICP_FILING_NUMBER`，两边和商店后台一致。
- 生成式 AI 类 App，苹果还会要网信办的备案或登记编号（WBS 16.1、16.2）。
- 部分 agent 上游的地区政策不支持中国大陆（docs/progress.md）。建议：16.1 / 16.2 办下来之前首发地区先不选中国大陆，
  或者大陆区版本隐藏不合规的 agent。

## 2. 审核备注（App Review Information → Notes）

中英文各一份，附 1–2 分钟的操作录屏（领养 agent → 配 key → 发任务 → 审批 → 看结果）。要点：

- ThinkTin 是远程 agent 的控制台：agent 在我们的云端沙箱里运行，App 不下载、不执行代码（2.5.2）。
- 模型 key 是用户在模型厂商那里自己的账号（BYOK）。App 不卖 key，也不靠 key 解锁 App 的功能（不属于 3.1.1 的许可证密钥），
  平台不经手模型费用。
- 把用户的消息、文件发给第三方 AI 之前会说明并取得同意（5.1.2(i)）：添加 key 时要勾选同意（`AddCredentialModel`），
  给实例配模型路由时提示消息和文件会发给 key 所属的厂商。
- agent 要用敏感工具（发消息、改文件、跑命令）、要用保险箱里的密码时，先发审批，用户在 App 里批准（批准前过 Face ID）。
- agent 写的内容都标了“AI 生成”（docs/compliance.md）；可以举报（5.5）。
- **审核账号**（要人定，见 docs/ios-release.md 第 4 节）：固定验证码的手机号、预置的实例和低额度 key。

英文版示例：

> ThinkTin is a remote console for AI agents. Agents run in our cloud sandboxes; the app never downloads or executes code.
> Model access uses the user's own API keys from the model providers (bring your own key); the app does not sell keys or
> unlock features with them. Before messages or files are sent to a model provider, the app tells the user which provider
> will process them and asks for consent. Sensitive agent actions require the user's approval in the app (with Face ID).
> AI-generated content is labeled and can be reported. Demo account: <phone> / code <code> (preloaded with an instance
> and a key).

## 3. 隐私

### 3.1 隐私清单（`apps/apple/Thinktin/Resources/PrivacyInfo.xcprivacy`）

- 不跟踪、没有跟踪域名、没有第三方 SDK。
- 收集的数据类型（都和账号关联、只用于 App 功能）：手机号、名字（昵称）、设备 ID、其他用户内容（任务、消息、文件、
  产出物）、其他数据（模型 key、保险箱，加密保存）、其他使用数据（token 用量）。
- 需要声明理由的 API：UserDefaults CA92.1、文件时间戳 C617.1、开机时间 35F9.1、磁盘空间 E174.1（SQLite 在 Apple 平台上
  调 statfs / fstatfs）。iOS 的 CI 用 `tools/apple/privacy/scan.py` 对 Rust 核心和 App 二进制跑 `nm`，用到了没声明的类别就失败。
  新加依赖、升级 SQLite 后看一眼 CI。

### 3.2 App Store Connect 的隐私问卷

照清单填：“数据用于追踪你”选否；每种数据类型选“与用户身份关联”、用途“App 功能”。隐私政策网址
`https://thinktin.cn/legal/privacy`，内容和清单、App 里的说明（登录页的同意、设置）一致。

### 3.3 Info.plist 的权限说明

现在只用 Face ID（`NSFaceIDUsageDescription`：“用面容 ID 确认审批、签名等高风险操作”）和通知（运行时申请，不用写说明）。
说明现在只有中文，上架前在 `InfoPlist.xcstrings` 里补英文。
以后加的：相机（扫码配对电脑，12.9）、相册（保存产出物）、麦克风和语音识别（语音输入），用到时再写说明，中英文都要。

## 4. 年龄分级

按 2025 年的新问卷填。agent 能联网、生成的内容不受限，用户自己能让 agent 访问任意网站：预计 16+ 或 18+。
“无限制的网页访问”选是；“用户生成内容”选是（有举报入口，5.5）。

## 5. 出口合规

Info.plist 里 `ITSAppUsesNonExemptEncryption = false`：只用系统和 rustls 的标准 TLS、认证用的签名，属于豁免，上传后不用再答问卷。

## 6. 截图与元数据

- 6.9 英寸 iPhone 截图，简体中文和英文各一套（演示模式的数据，不出现真实手机号、key）。
- 名称、副标题、关键词、截图里不出现 Claude、Codex 等第三方商标（2.3.7、5.2.1，docs/licenses.md 第 6 节）。
- 支持网址、营销网址、隐私政策网址。

## 7. 纯 IPv6 网络实测（2.5.5）

在 Mac 上开 NAT64 网络共享（系统设置 → 共享 → 互联网共享，按住 Option 勾“创建 NAT64 网络”），iPhone 连上后实测：
登录、事件流、推送、上传附件、下载产出物。服务端不能下发 IPv4 字面量地址（client-core 走 getaddrinfo）。

## 8. 提交前对一遍

- [ ] TestFlight 上的版本内部测试过一轮（docs/ios-release.md）。
- [ ] 审核账号能登录、能跑一次任务。
- [ ] 隐私清单、隐私问卷、隐私政策三者一致；CI 的隐私扫描通过。
- [ ] 截图、元数据没有第三方商标。
- [ ] 纯 IPv6 下实测通过。
- [ ] 中国大陆区：备案号、生成式 AI 材料（要人定）。
- [ ] 升级页的 App Store 链接（`ShellLinks.appStore`）填上了 App 的 Apple ID。
