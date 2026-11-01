# 紧急交接：iOS（TestFlight 发版、界面对比）2026-10-29

2026-10-31 已从自动保存快照恢复开发，修复范围与验证见 [iOS 恢复记录](progress/ios-app.md#2026-10-31-ios-恢复记录)。下面保留当时的发版背景。

上一个会话（session_01GuCp3KRgqaK6Kzynw6udRn）的周额度快用完了，下一个 agent 从这里接着做 iOS。阿里云部署的交接在
[handoff.md](handoff.md)，那是另一条线，别混。

## 0. 和用户打交道的规矩（先读）

- **用中文、说人话、步骤一条一条写**。用户不是做底层技术的，英文回复会直接说“看不懂”。苹果网站上的按钮名字中英文都写上。
- 用户累、怕麻烦：能自动做的自己做，要用户点的地方压到最少，**每一步写清楚在哪个网站、点哪个按钮**，看不懂就让他截图。
- **不让用户把密钥、密码、.p8 内容贴进聊天**。苹果的密钥只放在 GitHub 的 `Test flight` 环境里。
- **合并要等用户说“合并”**。删分支、强推这类改动 GitHub 的操作会被自动模式拦下，拦了就别绕，告诉用户由他决定。
- 用户要求过“反编译 Claude 的 IPA 看前端怎么实现”：**不做**（破解 App Store 加密、反编译别人的 App 违反苹果条款和版权，而且看不出界面代码）。
  替代办法：用户发 Claude App 的**真实截图或录屏**，我们照着把效果做出来。
- 不在 `main` 上直接改：开分支、小步提交、马上推送（`CLAUDE.md`）。

## 1. 现在的状态

- `main` 在 `7877f1f`（PR #16 合并）。iOS 12.x 的代码基本都做完了（另一个会话 10-25～26 做了第三轮和 W2，见
  [progress/ios-app.md](progress/ios-app.md)）。
- **TestFlight**：演示版 **0.1.0（构建号 16）** 已上传、苹果处理完（`VALID`），在内部测试组「内部测试」里，**用户已经在手机上装上了**。
  - 演示版 = 用 App 里的演示数据，不连服务器（服务器 `api.thinktin.cn` 还没上线，域名都解析不到）。一打开就是登录好的；退出后验证码 `123456`。收不到推送。
- 发版流程的来龙去脉在 [progress/ios-testflight.md](progress/ios-testflight.md)，怎么用在 [ios-release.md](ios-release.md)。

## 2. 苹果和 GitHub 上的配置（不含任何密钥）

| 东西 | 值 / 位置 |
|---|---|
| 开发者团队 | Siting (Shenzhen) Intelligent Industry Co., Ltd，团队 id `5BUH46M229`（不是密钥，工作流里是 `TEAM_ID_DEFAULT`） |
| App Store Connect 的 App | 名字 ThinkTin，套装 id `cn.thinktin.Thinktin`，SKU `thinktin-ios`。那边写的是“iOS App 版本 1.0 准备提交”，工程里是 0.1.0，**提审前要统一** |
| App ID | `cn.thinktin.Thinktin`（推送、App Groups、Time Sensitive）、`cn.thinktin.Thinktin.Widgets`（App Groups，第一次自动签名时登记的） |
| App Group | `group.cn.thinktin.Thinktin`，**已经在开发者网站上手动关联了两个 App ID**（这一步自动签名和 API 都做不了） |
| API 密钥 | App Store Connect → 用户和访问 → 集成 → 团队密钥里名叫 **Github** 的那把（密钥 id 末 4 位 `6GWM`，权限“管理”）。同一页还有一把旧的 **Clodex**（末 4 位 `7D73`），CI 不用，别填错——第一次就是填成了它才一直 401 |
| Issuer ID | 团队密钥页面顶上那串，开头 `a364d881` |
| GitHub 的密钥 | 仓库 Settings → Environments → **`Test flight`**（带空格、T 大写，工作流里写的就是这个名字）→ Environment secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8`（.p8 文件的文本）。保护规则都没勾 |
| TestFlight | 内部测试组「内部测试」（能看到所有构建，新构建处理完自动出现）；组里只有账号持有人（团队唯一的用户，用户知道是哪个 Apple ID） |
| 云端会话的环境变量 | 只有阿里云的 Key，**没有苹果的**；苹果的东西都在 GitHub 上跑，不需要放到会话里 |

## 3. 怎么发一个新版本（照做就行）

GitHub → Actions → **iOS release** → Run workflow（分支选 `main`）：

| 选项 | 意思 | 这次怎么填 |
|---|---|---|
| `upload` | 勾上才传到 TestFlight，不勾只打包、验证签名 | 勾 |
| `demo` | 演示版（演示数据、不连服务器） | 服务器上线前勾 |
| `runner` | 用哪种 Mac | **`macos-15-intel`**（苹果芯片的 `macos-26` 这几天经常排队 15 分钟后被 GitHub 取消） |
| `invite_testers` | 只做测试组：建内部测试组、把团队用户加进去、发邀请（Linux 上跑，一两分钟，不打包） | 发版时不勾 |

- 一次大约 25 分钟（Rust 有缓存时）。构建号 = 这个工作流的运行序号，只增不减；版本号手动触发时取 `project.yml` 的
  `MARKETING_VERSION`（现在 0.1.0），打 `ios-v0.2.0` 这种标签时取标签（标签发版**永远连服务器**、用 `macos-26`）。
- 流程：装密钥 → **先问苹果密钥能不能用**（`tools/apple/asc_key_check.py`，一分钟内出结果）→ 编 Rust → **现建一张分发证书 + 两个 App Store
  描述文件**（`tools/apple/asc_signing.py`）→ 手动签名归档 → 导出上传 → **撤销证书、删描述文件**（失败也撤销）。
- 传完苹果还要处理 10～30 分钟；内部测试组能看到所有构建，用户手机上 TestFlight 里点“更新”就行。
- 查状态不用 Mac：勾 `invite_testers` 跑一次，日志里会打印每个构建的处理状态、内部测试状态、测试员状态。

查运行结果（公开仓库，不用登录）：`https://api.github.com/repos/thinktin/Thinktin-Rust/actions/runs/<id>/jobs`，日志 zip：`.../runs/<id>/logs`。

## 4. 这次踩过的坑（都修了，别再踩）

1. macOS 的 `/bin/bash` 是 3.2：**变量后面紧跟中文标点会被当成变量名**（`$version，` → unbound variable）。写 `${version}`。
   也别在 `set -u` 下用空数组。
2. `ASC_ISSUER_ID` 填成了密钥 id；后来 `ASC_KEY_ID` 填成了旧密钥 Clodex 的。现在密钥检查会查格式、打印密钥 id 末 4 位和 Issuer ID 前 8 位，对照团队密钥页面就知道。
3. 环境名：工作流原来写 `testflight`，用户建的是 `Test flight`，三个密钥全读不到。已改成 `Test flight`。
4. GitHub 的苹果芯片 Mac 容量不够：排队 15 分钟后被取消（日志注解 “The job was not acquired by Runner”）。手动发版选 Intel；PR 上的“iOS app on the simulator”检查被取消时重跑一次（这次 PR #16 重跑就过了）。
5. **签名**：Xcode 自动签名在 CI 上会申请“这台机器”的开发证书，上一次的私钥不在 → “already has an Apple Development signing certificate for this machine”；
   iOS 26 SDK 不许临时签名（`CODE_SIGN_IDENTITY=-`）。所以改成每次现建 Apple Distribution 证书、手动签名（`signing.xcconfig` 按 target 名选描述文件，导出选项由脚本生成）。
   **分发证书有数量上限**：申请时 409 就去开发者网站 Certificates 里撤销不用的（CI 每次都会撤销自己建的那张）。
6. App Group 没关联到 App ID → 描述文件和 entitlements 对不上。要在开发者网站上每个 App ID 的 App Groups → Configure 里勾上。
7. 编完 Rust 后第一次连苹果遇到 DNS 失败，整次白跑：脚本现在都会退避重试。
8. 本地验证：Linux 上 `tools/apple/uicheck/run.sh test` **只编不跑** App 的 `ThinktinTests`，单独跑 `cd tools/apple/uicheck && swift test --skip-build --filter 'ThinktinTests.*clientKind'`（要 App 包的那些测试在 Linux 上本来就过不了）。
   Linux 版 ThinktinCore 绑定过期时先 `tools/client-core/build-linux-swift.sh target/linux`。

## 5. 没做完的（按优先级）

1. **界面对照 Claude**（用户最关心）：用户说会发 Claude App 的真实截图 / 录屏。我们 App 的真实截图用 `ios-screenshots.yml` 生成
   （现在已在 main 上，Actions → iOS screenshots → Run workflow；结果在 artifact `ios-screenshots`，12 张）。
   上次只拿 App Store 的宣传图比过，发现 4 处明显不同，**用户还没拍板改不改**：
   - 输入框：Claude 是两行的圆角卡片（上面打字，下面“+”、模型名、麦克风、橙色发送键），我们是一行胶囊；
   - Claude 的回复正文是衬线字，我们是无衬线；
   - Claude 新对话页中间一句大号衬线问候语，我们直接是对话记录；
   - Claude 的任务列表顶上有“全部 / 卡住 / 进行中 / 完成”筛选标签，我们是分段列出。
   我们的实例切换（顶部“写作助手 ▾”）是特有功能，建议保留。改之前先给用户看对比、等他同意。
2. **要用户决定的清理**：GitHub 上 `ios-testflight`、`ios-screenshots`、`autosave/ios-testflight` 三个分支已经没用了（PR #16 已合并），删分支被自动模式拦了，等用户自己删或授权。
3. **服务器上线后**发连服务器的版本：打 `ios-v0.1.x` 标签（或手动触发不勾 `demo`）。到时要确认推送（APNs 生产环境）、登录短信、审核账号。
4. **提审前**：统一版本号（App Store Connect 的 1.0 和工程的 0.1.0）；审核账号（固定验证码、预置实例和 key，要服务端支持，`ios-release.md` 第 4 节）；隐私问卷、截图（截图工作流可以出底稿）。
5. iOS 第三轮（12.7、12.8、12.15、12.17、12.18）和 W2 的包**没跑过多人对抗式审查**（进度文件里写着），有空补。
6. 标签发版仍然用 `macos-26`；苹果芯片 Mac 一直排不上的话，把标签发版也改成可选或默认 Intel。

## 6. 会话和定时任务

- 本会话的定时任务：定期续跑检查 `trig_01Wt6oEwQkA7pisCjcDZQZJB` 已停用；PR 兜底检查都已经触发完，**没有挂着的定时任务**。PR #16 已合并、已取消订阅。
- 其他会话：后端 backend-core（session_016LgPcdynywrhrjCq8VVFLt）、安卓（session_01T2zubC6hDr9ZZR3ihhPP5b）、阿里云部署（session_01JYVuTJTo78Zrenhct8Bkw5，见 handoff.md）。
