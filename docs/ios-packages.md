# iOS 工作包实现要点（WBS 12.x）

> 2026-10-22 由 WBS 细化工作流生成：四个视角（接口覆盖、和 Claude iOS App 的界面对照、平台与上架、开发顺序）逐条对照仓库，
> 再由完整性审查者核实依据、裁决矛盾。工作包列表以 `docs/gen_wbs.py` / `docs/wbs.md` 为准，本文件记每个包做的时候要注意什么。
> 工程约定见 [docs/ios.md](ios.md)，进度见 [docs/progress/ios-app.md](progress/ios-app.md)。

**注意**：各视角写的时候 11.7（client-core 补齐 App 接口）还没合进 `ios-app`，所以下文里“FFI 没有 X”“接口缺口”一类的说法，凡是属于 11.7 范围的（设备、注销、改计划与触发器、结构化策略、换 key、运行翻页、产出物、收件箱单条操作、团队与模板、设备消息）**都已作废**，以审查结论第一条为准。11.7 之后还缺的接口归 11.8、10.7。

## 1. 审查结论（依据核实与矛盾裁决）

一、和仓库现状不符的依据（已核实，去掉或改写）
1. 11.7 已经做完。origin/backend-core 上的 819a8a7、d0c0458、b2333f6、7c28efe、9e6a394、4be4411 把设备、注销、改计划和触发器、PlanPolicy、换 key、运行翻页、产出物、收件箱单条操作、团队和模板、设备消息都导出了（progress.md:57），e50db78 修好了 CI。所以下面这些都作废：接口视角“新增 11.7 +4 天”，UX 视角“新增 11.7 +3 天”，UX 视角说的“DELETE /v1/devices/{id} 连 api.rs 都没有”“api.rs 和 ffi.rs 都没有团队”“runs 没有 before”，平台视角“send_device_message 没进 ffi.rs（Rust +0.5 天）”，排序视角“NewPlan 没有 policy”和“11.7 每落一组合一次，CoreClient 先抛 unsupported”。现在要做的是：ios-app（基于 82b60b5）合一次 backend-core。11.7 之后还缺的接口挪到新增的 11.8 和 10.7：cached_events 往前读、runs 按 plan_id 过滤、AgentInfo 的介绍 / upstream / license_note / protocols、推送 tt 里的保险箱请求 id、Accept-Language、事件流 TLS、426 状态。
2. 排序视角说“App target 直接 import ThinktinCore，project.yml 却没列这个依赖”，不成立。AppEnvironment.swift:3-4 只 import ThinktinCoreAdapter 和 ThinktinKit，KeychainSessionStore.swift:4 import 的是 ThinktinKit。单独拆一个 ThinktinPlatform 的理由只剩一条：14.5 / 14.8 的 macOS 要复用 Keychain 和 Secure Enclave，等到 14.5 再拆也来得及。
3. 接口视角说“删除实例时实例忙会返回 conflict（error.rs:129）”，不对。Busy 只会从 control::rebuild 抛出。DELETE /v1/instances/{id}（instances.rs:125-145）会直接取消运行、吊销授权、删除实例，外键还会级联删掉别的计划里的流水线步骤和团队成员（0002_collaboration.sql:24、56-67）。set_instance_version 只是记下目标版本（instances.rs:89-112），也不会返回 conflict。
4. 接口视角说“reason 是服务端按用户语言写的”，只对 waiting_quota 成立（waits.rs:75）。waiting_approval 的 reason 是 agent 写的审批标题（executor.rs:1799），流水线的是英文“running N steps”（pipeline.rs:105），失败原因是英文诊断信息（i18n.md 第 3 节）。
5. 接口视角说“ai_generated 的事件旁边显示标识”就够了，不够。labels.rs:37-39 只标了 message、thought、plan 三种，其他 agent 写的字段要 App 按规则表补标（见“遗漏”）。
6. UX 视角说“artifact_content 要改成流式写文件”，不需要：产出物上限 20 MiB（orchestrator/src/artifacts.rs:15）。接口视角说“做下载进度”，做不了：接口一次返回 Vec<u8>，只能显示转圈。要注意的是 timeout_secs 管的是整个请求（api.rs:326-330），超时要设得够长。
7. 平台视角和排序视角把 12.9 放在 P2，不对。wbs.md 的阶段定义里“签名审批”属于 P3，电脑端 App 从 14.5 才开始做，P2 没法端到端验收，所以定 P3，接口视角是对的。12.9 和 14.8 的交付物重叠（14.8 的“扫码配对、手机签名、电脑验签”是 iOS / macOS 角色），划分为：12.9 做手机侧（密钥、扫码、签名、能力令牌签发和吊销），14.8 做 Mac 侧（显示二维码、验签、发确认）。
8. 平台视角和排序视角都提到 UIBackgroundModes 里的 remote-notification：服务端载荷从来不带 content-available（apns.rs:114-145），架构 8.4 也不靠后台刷新。裁决：12.8 去掉这个后台模式，不加静默推送。
9. UX 视角引用的外部链接（cryptobriefing、pasqualepillitteri、matthewcassinelli、beginnersinai）在仓库里核实不了，只当界面参考，不作为估算依据。

二、视角之间的矛盾和裁决
1. 新包编号。接口视角 12.12=IM；UX 视角 12.12 到 12.19 依次排；平台视角 12.12=设置、12.15=快捷指令、12.16=TestFlight；排序视角 12.12=设置、12.13=保险箱、12.14=IM、12.15=联调测试。裁决：12.12、12.13、12.14 和安卓已定的 13.13、13.14、13.15 同号同义（origin/android-app:docs/gen_wbs.py:158-160），分别是设置多语言开源许可、保险箱、IM，其余新包从 12.15 往后排。
2. 云端审批放哪。接口视角放 12.5，UX 视角新建 12.15，平台视角放 12.8（只挪 Face ID），排序视角放 12.5。裁决：新建 12.15（P1，2.5 天）。12.5 已经 13 天，再塞进去会变成最长的一条线。12.15 交付审批卡组件，12.5 把它嵌进对话，12.8 复用它的拒绝逻辑。12.9 的人日不减：拿走了审批界面，但加了配对、能力令牌、重新配对。
3. 保险箱放哪个阶段。接口视角 P2；UX 视角 P1，并入 12.4 加 3 天；排序视角放 12.13（P2），却又说“表单归 12.13、12.5 经 Route 打开”，自相矛盾。裁决：发送前拦截、保险箱表单、agent 填写请求卡片放 12.5（P1）。理由有两条：send_message 在 P1 就会返回 ContainsSecrets（client.rs:224-240）；服务端默认就给 agent 保险箱工具和委派工具（server/config.rs:128-134），P1 用户一定会碰到。条目管理和“待填写”列表放 12.13（P2，2 天）。建议安卓 13.5、13.14 按同样的方式划分。
4. 产出物放哪。接口视角放 12.5，UX 视角新建包，排序视角放 12.7。裁决：新建 12.18（P1，2 天），四个入口共用一套预览和分享组件。
5. 设置放哪。UX 视角是 12.14，平台视角和排序视角是 12.12。裁决：设置中心是 12.12；设备、下线其他设备、全部停止、注销这几个动作在 12.2 实现，设置中心只放入口。
6. 多语言。接口视角和 UX 视角放 12.1；平台视角放 12.12，语言项跳系统设置；安卓是在 App 里切换；wbs.md 的 1.6 是 P2。裁决：String Catalog 按功能分表、错误码文案表放 12.1。iOS 用系统的“按 App 设语言”，切换后 App 会重启。每次启动比较 me().locale 和界面语言，不一致就调 set_locale。英文翻译可以跟 1.6 延到 P2，但整套流程在 P1 跑通。
7. 联调测试。排序视角新建 12.15（1.5 天）。裁决：不单列。UniFFI 的记录类型在编译期就做了检查，而且 ThinktinCoreAdapterTests 已经经过真实的 .so 运行。真正没有类型保护的是 payload_json，用 crates/e2e 导出的事件夹具覆盖（计在 12.5 里，0.5 天，和安卓共用）。
8. 规模。12.1：排序视角 7.5 天，UX 视角 +2，平台视角 +7，裁决 9 天。12.5：接口视角 +7.5，UX 视角 +8，排序视角 +3.5，裁决 13 天，不含审批、产出物、保险箱管理。
9. 演示账号。平台视角放 12.11，排序视角放后端 4.7。裁决：两边都做。4.7 做固定验证码的配置；12.11 准备演示数据和审核备注。
10. 推送的服务端补齐。平台视角计入 12.8（服务端 2 天），UX 视角放 5.1。裁决：新建 10.7（后端 1.5 天），12.8 只算 App 的工作量。
11. 搜索。UX 视角 3 天，含 FTS5。裁决：P2，先在本机缓存的列表里搜，2 天，不加全文索引。
12. 附件和内购属于产品决定。裁决：列为 12.22 和 12.23，标“待 1.1 拍板”，后端另起包。
13. agent.usage。ios.md 第 5 节写“不显示”，UX 视角要求在对话里显示。裁决：显示在运行详情里，不进时间线。
14. 开发顺序（排序视角）。11.7 已经做完，D 线（12.6→12.7）不用再等 Mock。W0：先合 backend-core，再冻结 12.1。W1 分四条线并行：A 线 12.16→12.2→12.12→12.17，B 线 12.3→12.4→12.8，C 线 12.5→12.18，D 线 12.6→12.7，12.15 由先空下来的人做。12.11、12.19 放到最后，12.11 还要等 16.1、16.2。
15. 总量。四个视角的估计分别是：接口 +31、UX +58.5、平台 +37、排序合计 78.5。裁决后 12.x 合计 109 人日：P1 85、P2 13、P3 5、P4 6，其中 12.22、12.23 共 5.5 天待拍板。另有后端前置工作：P1 6 天（11.8、10.7、4.7、5.5），P2 6.5 天（10.6、5.6）。

## 2. 最终工作包

| 编号 | 工作包 | 前置 | 人日（未取整） | 阶段 |
|---|---|---|---|---|
| 12.1 | 工程与 ThinktinKit | 11.1, 11.7 | 9 | P1 |
| 12.2 | 注册登录与设备管理 | 12.1, 4.2, 11.7 | 6 | P1 |
| 12.3 | Agent 目录与领养 | 12.1, 5.1 | 6 | P1 |
| 12.4 | 模型 key 配置 | 12.1, 9.8, 11.7, 11.8 | 6.5 | P1 |
| 12.5 | 对话与运行过程 | 12.1, 11.3, 11.6 | 13 | P1 |
| 12.6 | 计划管理 | 12.1, 7.1, 11.7 | 8.5 | P1 |
| 12.7 | 团队与流水线 | 12.6, 8.3, 11.7 | 8.5 | P1 |
| 12.8 | 推送与收件箱 | 12.1, 10.1, 10.7, 11.7 | 6 | P1 |
| 12.9 | 审批与签名（电脑高危操作） | 12.15, 11.5, 11.7, 14.2 | 5 | P3 |
| 12.10 | 实时活动 | 12.5, 10.6 | 4.5 | P2 |
| 12.11 | 上架 | 12.2, 12.8, 4.7, 16.1, 16.2, 16.4 | 5.5 | P1 |
| 12.12 | 设置、多语言与开源许可 | 12.2 | 3.5 | P1 |
| 12.13 | 密码保险箱界面 | 12.5, 9.11, 11.6 | 2 | P2 |
| 12.14 | IM 渠道设置 | 12.12, 10.5 | 2 | P4 |
| 12.15 | 云端审批（审批卡与审批中心） | 12.1, 6.13 | 2.5 | P1 |
| 12.16 | 应用框架与导航 | 12.1 | 3.5 | P1 |
| 12.17 | 首次启动、引导与空状态 | 12.2, 12.3, 12.4 | 2.5 | P1 |
| 12.18 | 产出物 | 12.5, 8.4, 11.7 | 2 | P1 |
| 12.19 | TestFlight 与持续交付 | 12.1 | 2 | P1 |
| 12.20 | 小组件与快捷指令 | 12.8, 12.6 | 3 | P2 |
| 12.21 | 搜索 | 12.16 | 2 | P2 |
| 12.22 | 运行附件（待 1.1 拍板） | 12.5, 5.6 | 1.5 | P2 |
| 12.23 | App 内购买（待 1.1 拍板） | 12.12、后端计费包（未编号，待定） | 4 | P4 |
| 11.8 | （后端前置）client-core 补漏 | 11.7 | 2.5 | P1 |
| 10.7 | （后端前置）APNs 推送补齐 | 10.1, 10.4 | 1.5 | P1 |
| 4.7 | （后端前置）审核与演示账号 | 4.1 | 1 | P1 |
| 5.5 | （后端前置）内容举报与反馈 | 5.1 | 1 | P1 |
| 10.6 | （后端前置）实时活动推送 | 10.1, 11.7 | 3 | P2 |
| 5.6 | （后端前置）运行附件上传（待 1.1 拍板） | 5.1, 8.4 | 3.5 | P2 |

`gen_wbs.py` 里半天向上取整。后端前置包（4.7、5.5、5.6、10.6、10.7、11.8）归 backend-core 会话；10.6 已被认领。

## 3. 各工作包的实现要点

来源标注：**审查** = 完整性审查者补的遗漏（已核实）；**界面** = 和 Claude iOS App 的对照；**平台** = 平台与上架要求。

### 总览 信息架构总表

- **信息架构映射总表（Claude iOS → ThinkTin）**（界面，P1，+0 人日）
  Claude iOS 和 ThinkTin 的对应关系如下。
  - 侧边抽屉（搜索、新对话、Chats、Projects、Artifacts、Code、底部头像进设置）→ 抽屉（搜索、新任务、收件箱、审批、进行中、计划、团队、产出物、实例列表、底部头像进设置）。
  - 一个对话 → 一个实例的时间线。一个实例只有一条连续的 ACP 会话，用户气泡取自 Run.prompt，agent 内容取自事件流。
  - 发一条消息 → 起一个运行。
  - “新对话” → 在当前实例上下新任务，上下文是延续的。平台没有“开新会话”的接口，要干净的上下文只能另领养一个实例，这一点要在 1.2 拍板。
  - 输入框里的模型选择 → 实例的 main 别名。create_run 不带别名，不能逐条消息换模型。
  - Projects → 团队加团队模板。
  - Artifacts → 产出物。
  - Code 标签里的后台会话列表（带状态）→ “进行中”（跨实例的运行和等待态）。
  - 长任务完成的通知 → RUN_FINISHED 推送。
  - 对话里的用量按钮 → 用量看板。
  - 设置 → 设置中心。
  下面各条按这张表给出页面清单和缺口。
  依据：Claude iOS App 的侧边栏、输入框、设置页。2026-09 的 Liquid Glass 改版和导航调整见 https://cryptobriefing.com/claude-liquid-glass-ios-redesign/；对话内用量按钮和 Code 标签见 https://pasqualepillitteri.it/en/news/15037/claude-ios-usage-button-claude-code-settings 。代码依据：crates/client-core/src/ffi.rs:1235 create_run(instance_id, prompt)、:1197 set_model_routes（注释“叫 main 的是默认模型”）；docs/architecture-v3.md 4.5（session/load 接回原会话）

### 12.1 工程与 ThinktinKit

- **11.7 已经做完，先合进 ios-app，再冻结适配层**（审查，P1，+0.5 人日）
  四个视角都把 11.7 当成没做（接口 +4、UX +3、排序视角写“每落一组合一次、CoreClient 先抛 unsupported”、平台视角在 12.2 和 12.9 各记 0.5 天 Rust）。实际上 origin/backend-core 已经全部导出：devices、revoke_device、update_profile、send_self_code、delete_account；update_plan(PlanChange)、add_trigger、delete_trigger、PlanPolicy 记录，Plan 加了 policy、catch_up，NewPlan 加了 policy、catch_up（uniffi 默认 nil）；update_credential、replace_credential_secret；older_runs、instance；instance_artifacts、delete_artifact；inbox_item、mark_inbox_unread、delete_inbox_item；团队和模板的 10 个方法；send_device_message、device_messages、ack_device_messages。12.1 要做的是：合 backend-core（只 merge 不 rebase），重跑 build-linux-swift.sh 生成绑定，Conversions.swift 补上新字段，ClientProtocol、Mock、CoreClient 加这约 30 个方法，删掉 ios-app.md 里“CoreClient 抛 unsupported”的约定（Swift 的 ClientError 本来也没有这个 case）。四个视角为 11.7 估的人日都不算了；还缺的接口另记到新增的 11.8。
  依据：git log origin/backend-core：819a8a7、d0c0458、b2333f6、7c28efe、9e6a394、4be4411、e50db78；origin/backend-core:docs/progress.md:57（11.7 行）；origin/backend-core 的 crates/client-core/src/ffi.rs 有 2328 行，ios-app 上只有 1754 行；apps/apple/ThinktinKit/Sources/ThinktinKit/Client/ClientError.swift:7-31（没有 unsupported）

- **设计系统与多语言基建（并入 12.1）**（界面，P1，+2 人日）
  在 ThinktinKit 里做设计令牌（颜色、字号、间距，浅色和深色）和基础组件：消息气泡、卡片、状态徽标、“AI 生成”标识、空状态视图、横幅和 Toast。
  品牌约束：参照 Claude 的布局和交互，但不能用 Anthropic 的商标、Claude 标志和 Anthropic 授权的字体，App 里只能叫“Claude Agent”。
  系统版本：iOS 26 用系统的 Liquid Glass 材质，旧系统降级显示。最低系统版本要拍板（实时活动的推送启动要 iOS 17.2）。
  多语言：从第一天起用 String Catalog（zh-Hans、en）；做一张 ClientError 错误码 → 本地化文案的映射表，因为接口错误由客户端按错误码翻译；App 换语言时调 set_locale。
  12.1 原交付物只写了工程和 ThinktinKit。
  依据：docs/i18n.md §1（PATCH /v1/me、set_locale）、§3（接口错误由客户端按错误码翻译）；ffi.rs:1080 set_locale；docs/licenses.md:161（命名和商标）；docs/progress/ios-app.md 下一步 1；cryptobriefing 的 Liquid Glass 报道

- **最低版本定为 iOS 17 / macOS 14，ThinktinCore 包和 Rust 部署目标跟上**（平台，P1，+0.5 人日）
  结论：从 iOS 16 提到 17，不必到 18。理由一：docs/ios.md 第 3 节的视图模型用 @Observable，它要 iOS 17 / macOS 14 起。理由二：iOS 17 和 18 支持的机型相同（XS/XR 起），提到 17 不会多丢设备。iOS 17 还带来：defaultScrollAnchor / scrollPosition（对话页贴底）、交互式小组件、17.2 的实时活动 push-to-start（12.10 里 App 没打开时计划开始也能起活动）。macOS 14 和 14.3 截图要用的 SCScreenshotManager 一致。现状：ThinktinKit/Package.swift 和 project.yml 已是 iOS 17 / macOS 14，但 build-apple.sh 生成的 ThinktinCore Package.swift 仍是 .iOS(.v16)、.macOS(.v13)。Rust 交叉编译也没设 IPHONEOS_DEPLOYMENT_TARGET / MACOSX_DEPLOYMENT_TARGET（rustc 和 aws-lc-sys 的 cmake/cc 都读），会和 App 的部署目标不一致。12.1 交付物要写明：iOS 17.0+ / macOS 14.0+；只做 iPhone，但审核也会在 iPad 上用兼容模式跑，要过一遍；在 App Store Connect 关掉“在 Apple 芯片 Mac 上提供”（macOS 是 14.x 的独立 App）。
  依据：tools/client-core/build-apple.sh 生成的 Package.swift `platforms: [.iOS(.v16), .macOS(.v13)]`；apps/apple/ThinktinKit/Package.swift `.iOS(.v17), .macOS(.v14)`；apps/apple/project.yml deploymentTarget iOS 17.0、TARGETED_DEVICE_FAMILY 1；docs/ios.md 第 3 节“@Observable 类”

- **Xcode 26 / iOS 26 SDK 带来的 Liquid Glass 外观**（平台，P1，+1 人日）
  App Store Connect 从 2026 年 4 月起只收 Xcode 26（iOS 26 SDK）构建的包。用 26 SDK 编译后，系统导航栏、工具栏、TabBar、Sheet 自动变成 Liquid Glass；UIDesignRequiresCompatibility 只是过渡开关。docs/ios.md 第 4 节的 paper 底色、自定义卡片和输入框，要在 iOS 17/18（旧外观）和 26（玻璃）两种外观下都验收，设计令牌里给导航栏和输入框留玻璃材质的变体。快照测试至少跑 iOS 26 模拟器。最低版本的模拟器 macos-26 镜像不一定自带，发版前或每周单独跑一次（xcodebuild -downloadPlatform）。现在 12.1 的估算没含这部分。
  依据：.github/workflows/ios.yml（工作区新文件）runs-on: macos-26、Xcode_26.6；docs/ios.md 第 4 节设计令牌

- **XcodeGen 工程：定 Bundle ID，补能力和 Info.plist 项**（平台，P1，+0.5 人日）
  project.yml 已有，还差几项。(a) Bundle ID 没定：现在由 bundleIdPrefix 生成 cn.thinktin.Thinktin，而服务端示例配置的 push.apns.topic 是 app.thinktin，apns.rs 测试里是 com.thinktin.app。APNs topic、App 备案、Keychain 服务名都依赖它，要在 12.1 定死，写进 PRODUCT_BUNDLE_IDENTIFIER。(b) 审批推送带 interruption-level: time-sensitive，App 要有 com.apple.developer.usernotifications.time-sensitive 能力，否则专注模式下不出。(c) 声明了 UIBackgroundModes: remote-notification，注释说“推送带 content-available 时后台拉收件箱”，但服务端载荷从不带 content-available。这个后台模式实际没用上，审核会问用途：要么去掉，要么 10.x 加静默推送。(d) NSFaceIDUsageDescription 只有中文，权限文案要放进 InfoPlist.xcstrings（zh-Hans / en）。(e) CI 里 brew install xcodegen 不锁版本，应改装固定的 2.46.x，和 minimumXcodeGenVersion 一致。(f) 12.10 的 Widget 扩展、深链要的 Associated Domains 以后也在这里加。
  依据：apps/apple/project.yml（bundleIdPrefix cn.thinktin、UIBackgroundModes、entitlements 只有 aps-environment）；crates/server/src/config.rs:1206 topic = "app.thinktin"；crates/notify/src/apns.rs:129 time-sensitive、:308 com.thinktin.app；全仓库搜不到 content-available

- **ThinktinCore 打包：LTO 实际没生效，CI 编译时间与缓存**（平台，P1，+1.5 人日）
  实测（Linux 4 核，client-core，mobile profile）：build-apple.sh 用 `cargo build -p client-core --lib`，crate-type 是 lib+staticlib+cdylib。混有 rlib 时 Cargo 不做 LTO，[profile.mobile] 的 lto=true 实际没生效，产出的 libclient_core.a 是 115.6MB。改用 `cargo rustc -p client-core --lib --profile mobile --crate-type staticlib` 才真做 fat LTO，.a 是 25.8MB；代价是只改 client-core 后的重编从 49 秒涨到 138 秒（全部依赖冷编译 129 秒）。建议：发布构建用 cargo rustc --crate-type staticlib，Apple 不需要 cdylib；build-android.sh 同理只要 cdylib，要同步告诉安卓会话。CI 的 --ci 本来就不该做 LTO，但应换一个更轻的 profile（lto=false、codegen-units=16）。GitHub 的 macOS arm64 runner 只有 3 核 / 7GB。用 actions/cache 按 hashFiles(crates/client-core/**, crates/proto/**, Cargo.lock, tools/client-core/**) 缓存整个 target/apple/ThinktinCore，没改 Rust 时整步跳过。全量 5 个目标（含真机 aarch64-apple-ios）至今没在 macOS 上跑过：mobile.yml 只能在 main 上手动触发，没有运行记录。要在 TestFlight 流水线（新增 12.16）之前先跑通一次。仓库是公开的，macOS 分钟不计费，但同时最多 5 个 macOS 任务。
  依据：tools/client-core/build-apple.sh `cargo build -p client-core --lib --profile "$profile"`；crates/client-core/Cargo.toml crate-type = ["lib","staticlib","cdylib"]；Cargo.toml:61-66 [profile.mobile] lto=true；.github/workflows/mobile.yml（workflow_dispatch，Actions 里 0 次运行）；本次实测：deps/libclient_core.a 115565958 字节（混编）对 25848810 字节（只编 staticlib）

- **崩溃与日志：不接第三方 SDK，补系统级方案**（平台，P1，+1 人日）
  建议 P1 不接任何崩溃或埋点 SDK：国内外都能用，隐私标签最简单，也不触发 ATT。用 App Store Connect / TestFlight 自带的崩溃报告和 Xcode Organizer，再加 MetricKit（MXMetricManager）收诊断，先只存本地，在“关于”里可导出给客服。要补三件事。(a) client-core 用 tracing 打日志，但没有任何 subscriber，App 里什么也看不到。加一个把 tracing 转到 os_log（subsystem cn.thinktin.core）的初始化函数，经 UniFFI 导出（Rust 0.5 天），TestFlight 用户的问题才能从 sysdiagnose 里查。(b) mobile profile 继承 release，没有调试信息，Rust 栈帧在崩溃报告里没有行号。发布构建加 debug = "line-tables-only"，并验证一次故意的 Rust 崩溃能在 Organizer 里符号化。(c) 以后要把诊断上传到自己的服务端时，再加接口（gateway 现在没有），并在隐私清单里声明 Crash Data / Performance Data。
  依据：crates/client-core/src/lib.rs（没有日志初始化）；crates/client-core/Cargo.toml 依赖 tracing；Cargo.toml [profile.mobile] inherits release、strip=true；crates/gateway/src/routes/mod.rs 没有诊断上报接口

- **参考 Claude App 的界面，但不照搬品牌（审核 4.1 仿冒、5.2 知识产权）**（平台，P1，+0.5 人日）
  docs/ios.md 第 4 节说“不用其品牌资产”，但令牌里的 #141413、#FAF9F5、#D97757 就是 Anthropic 公开品牌色板里的颜色，#C96442 是 claude.ai 的强调色。再加上衬线标题、同样的抽屉和胶囊输入框，审核可能按 4.1（仿冒）拒，也有商业外观的风险。建议：信息架构和交互照着参考；强调色和底色换成自有色相，用自有图标和启动画面；App 名称和截图里不出现 Claude 字样和标志。agent 目录里 Claude、Codex、OpenClaw、Hermes 的名字和图标按 licenses.md 6.2 的结论用：文字写“Claude Agent”，没有授权不用对方标志。
  依据：docs/ios.md 第 4 节设计令牌表（accent #C96442/#D97757、paper #FAF9F5、ink #141413）；docs/licenses.md 第 6 节第 2 条

- **无障碍、动态字体、深色模式的验收基础设施**（平台，P1，+2 人日）
  ios.md 把这几项列为每个页面的验收项，但 WBS 没给时间。要做的：ThinktinUITests 用快照测试覆盖“浅色 / 深色 × 默认字号 / AX3”（快照库只进测试 target，不进 App，不影响开源许可页）；UI 测试里调 XCUIApplication.performAccessibilityAudit()（iOS 17 起），接进 CI；运行状态不能只靠颜色区分，加图标和 VoiceOver 文本；流式输出节流后再用 announcement 播报，不逐 token 读；打开“减弱动态效果”时关掉打字动画。上架时在 App Store Connect 填“辅助功能营养标签”（2025 年起，声明支持的 VoiceOver、更大字体、深色界面、不靠颜色区分等），声明的每一项都要实测过。和安卓 13.13 的无障碍要求对齐。
  依据：docs/ios.md 第 4 节“深色模式、动态字体、VoiceOver 标签是每个页面的验收项”；docs/wbs.md 12.x 交付物里没有这一项；origin/android-app:docs/wbs.md 13.13

### 12.2 注册登录与设备管理

- **换手机号：服务端只定义了验证码用途，没有对应接口**（审查，P2，+0 人日）
  send_self_code 认 change_phone 这个用途，auth 里也定义了 CodePurpose::ChangePhone，但路由里没有换手机号的接口。手机号是唯一的登录方式，用户换号后就没法迁移账号，只能注销后重新注册。App 侧暂时不做；设置页的手机号一栏只读。请后端在 4.1 补上接口之后，再在 12.2 里加这个流程（约 0.5 天）。
  依据：crates/gateway/src/routes/account.rs:221-227；crates/auth/src/sms.rs:14、22；crates/gateway/src/routes/mod.rs:29-43（没有换号路由）

- **欢迎页、手机号登录、账号与设备管理补全**（界面，P1，+1.5 人日）
  页面清单（都在 12.2）：
  1. 欢迎页：品牌、简介、“手机号登录”按钮、用户协议和隐私政策的同意。收集个人信息前必须先同意（16.4）。
  2. 登录页：国家/地区区号选择（4.1 已接国际和港澳台短信模板）、发验证码倒计时、429 Retry-After 提示、验证码用 oneTimeCode 自动填充、login 时带上 apns 推送令牌。
  3. 账号页：昵称、打码的手机号、退出登录。
  4. 注销账号：App Store 审核指南 5.1.1(v) 要求 App 内能注销。
  5. 设备管理：设备列表（标出当前设备、电脑是否在线 DeviceView.online）、远程下线。
  接口缺口：
  - 注销：后端有 POST /v1/me/code{purpose:delete_account} 和 POST /v1/me/delete，FFI 没有。
  - 设备列表：api.rs 有 devices()，FFI 没导出。
  - 远程下线：DELETE /v1/devices/{id} 连 api.rs 都没有。
  - 改昵称：PATCH /v1/me 支持 display_name，FFI 只有 set_locale。
  12.2 原交付物只写了“登录、设备列表、远程下线”。
  依据：crates/gateway/src/routes/mod.rs:33-43；crates/gateway/src/routes/account.rs:182-246（update_me 的 display_name、send_self_code、delete_account）；crates/client-core/src/api.rs:614 devices() 和 :79 DeviceView；ffi.rs 里没有 devices、delete_account、display_name 相关方法；docs/progress.md:74（4.1 国际 / 港澳台短信）

- **Keychain 会话存储：处理重装，限定每个进程一个客户端**（平台，P1，+1 人日）
  KeychainSessionStore 已按 AfterFirstUnlockThisDeviceOnly、不同步到 iCloud 实现，还差四点。(a) iOS 卸载 App 不清 Keychain：重装后会带着旧会话直接显示已登录，但 SQLite 缓存已经没了，推送令牌也换了。首次启动（UserDefaults 里没有标记）时先 logout；每次启动拿到 APNs 令牌都调一次 set_push_token。(b) Api::new 只在构造时 load() 一次会话，之后只写不读；而服务端的刷新令牌每次轮换，旧令牌被重用就吊销整个会话。所以每个进程只能有一个 ThinktinClient：App 扩展（小组件、通知扩展、Intents 扩展）一律不建客户端、不联网；App Intents 放主 App target 里跑。这条规则写进 docs/ios.md。(c) 缓存库（ClientConfig.cache_path）放在 Application Support，文件保护设为 completeUntilFirstUserAuthentication（锁屏时点通知上的“拒绝”也要能打开库），并排除 iCloud 备份。(d) macOS（14.5）复用这个实现时要加 kSecUseDataProtectionKeychain。
  依据：crates/client-core/src/api.rs:331 `let session = store.load();`（只在 Api::new 里）；docs/progress.md 已完成表 4.1、4.2“旧令牌重用即吊销整个会话”；apps/apple/Thinktin/Platform/KeychainSessionStore.swift

- **iOS 16 起拿不到用户起的设备名**（平台，P1，+0.5 人日）
  ClientConfig.device_name 的注释示例是“张三的 iPhone”。但从 iOS 16 起，没有 com.apple.developer.device-information.user-assigned-device-name 能力时，UIDevice.current.name 只返回“iPhone”，设备管理里每台都叫 iPhone，用户分不清该下线哪台。两种做法：申请这个能力（理由是在设备管理里展示），或者用机型名（把 utsname 的 machine 映射成“iPhone 15 Pro”）加上登录时间。服务端没有改设备名的接口，所以不能让用户改名。
  依据：crates/client-core/src/ffi.rs ClientConfig.device_name 注释；crates/gateway/src/routes/mod.rs /v1/devices 只有 GET 和 DELETE

- **账号注销（审核 5.1.1(v)）：client-core 没接**（平台，P1，+1 人日）
  App Store 要求能注册账号的 App 在 App 里提供注销。服务端已有 POST /v1/me/code（purpose=delete_account，发专用验证码）和 POST /v1/me/delete，但 api.rs、ffi.rs 都没有对应方法，12.2 的交付物也没写注销。要补两部分：client-core 加 send_self_code(purpose) 和 delete_account(code)（Rust 0.5 天，安卓 13.2 也要用）；设置页加“注销账号”：先说明会删掉什么（实例、计划、key、保险箱、IM 渠道，DEK 销毁后不可恢复），再输验证码，完成后回登录页。同一组接口里，devices() 在 api.rs 里有、ffi.rs 没导出；远程下线的 DELETE /v1/devices/{id} 在 api.rs 里也没有。所以 12.2 的“设备列表、远程下线”现在做不了，要一起补。
  依据：crates/gateway/src/routes/mod.rs `/v1/me/code`、`/v1/me/delete`、`/v1/devices/{id}`；crates/gateway/src/routes/account.rs:216-246；crates/client-core/src/api.rs:614 devices()；ffi.rs 里没有 delete_account、devices

### 12.3 Agent 目录与领养

- **删除实例会连带删掉其他计划里的流水线步骤和团队成员**（审查，P1，+0.5 人日）
  DELETE /v1/instances/{id} 不返回 conflict，它会直接做三件事：取消实例上正在跑的运行、吊销授权、删除。外键是 ON DELETE CASCADE，所以下面这些也会被删：别的计划里指定这个实例的流水线步骤（plan_steps）、这个实例的团队成员身份、它自己的计划和产出物。剩下的步骤如果 depends_on 被删掉的那一步，下次触发时 order_steps 会失败，整条流水线判失败。四个视角只写了“二次确认”。12.3 的删除确认要做到：先列出会受影响的计划（plans() 加 get_plan 看 steps）和团队（teams()），写明“会停掉正在跑的任务、会从这些流水线和团队里移除”；删完刷新计划列表和团队列表。
  依据：crates/gateway/src/routes/instances.rs:125-145；crates/store/migrations/0002_collaboration.sql:16-24（team_members）、56-67（plan_steps 的外键级联）；crates/store/migrations/0001_init.sql:178-192（plans）；crates/gateway/src/routes/plans.rs:69-88（order_steps）

- **Agent 目录、领养与实例详情页**（界面，P1，+1 人日）
  页面清单（都在 12.3）：
  1. Agent 目录。入口：抽屉的“+ 领养”、空状态。卡片显示 name、version、license、接入方式 harnesses。
  2. 领养表单：起名字；接入方式多于一个时让用户选（比如 Claude 有两种接入）。
  3. 实例详情（缺）。入口：对话页的标题。控件：
  - 改名（rename_instance）；
  - 版本：versions 的第一个是当前版本，实例不是它时提示升级，也可以回滚（set_instance_version，下次唤醒生效，工作区保留）；
  - 状态说明（provisioning、running、paused、archived 各是什么意思）；
  - 模型路由入口；
  - 本实例的计划和产出物；
  - 删除（delete_instance，二次确认）。
  命名按许可证说明的商标要求。12.3 只写了“浏览、详情、领养、实例列表”，没有实例设置、升级回滚和删除。
  依据：ffi.rs:119 AgentInfo（versions、license）、:1149 rename_instance、:1156 set_instance_version、:1227 delete_instance；crates/proto/src/domain.rs:136 InstanceState；docs/licenses.md:161

### 12.4 模型 key 配置

- **接口不返回 agent 用的模型协议，App 没法按协议过滤 key**（审查，P1，+0.5 人日）
  每个 agent 的清单里都写了 [llm] protocols（claude 是 anthropic-messages，codex 是 openai-responses），但 /v1/agents 只返回 id、name、version、license、sites、harnesses、default_harness、versions，FFI 的 AgentInfo 也没有这个字段。VendorInfo.protocols 用的又是另一套名字（anthropic、chat、responses）。set_routes 不检查协议，配错了不报错；到了运行时，模型网关直接跳过协议不支持的 key（9.9），运行就进了 waiting_quota。接口视角和 UX 视角都写了“按 agent 协议过滤”，但没发现 App 拿不到这个数据，只能写死“Claude 走 anthropic、Codex 走 responses”。建议：11.8 给 AgentInfo 加 protocols，名字统一成 VendorInfo 那套；12.4 选 key 时按它过滤，选了不兼容的 key 在本地拦下并说明原因。
  依据：crates/catalog/manifests/claude.toml:33-34、codex.toml:29；crates/gateway/src/routes/agents.rs:10-19；crates/client-core/src/ffi.rs:119-129、544-550；crates/gateway/src/routes/instances.rs:164-197（set_routes 只校验长度和备用 key 个数）；docs/progress.md 已完成表 9.9 行（不支持协议的 key 直接跳过）

- **模型别名的规则：main 优先、fast 的用途、16 个上限、保存后会唤醒运行**（审查，P1，+0.25 人日）
  默认模型的规则：执行器有 main 就用 main，没有就用第一个。gateway 注释写的是“第一个是默认模型”，FFI 注释写的是“叫 main 的是默认模型”，两处说法不一致，App 按执行器的实际行为来：main 必须有，并放在第一个。fast 是给轻量任务用的别名，对 Claude 来说对应 Haiku 那个槽位。每个实例最多 16 个别名，每个别名最多 3 个备用 key，上游模型名 1 到 128 个字符。保存路由会唤醒所有卡在等 key 上的运行，所以保存后要刷新当前运行的状态。路由编辑器给两个预设：main（必填）、fast（可选，附说明）。
  依据：crates/orchestrator/src/executor.rs:666-670；crates/agent-shim/src/config.rs:82、420-421；crates/gateway/src/routes/instances.rs:164、172-181、196（wake_waiting_runs）；crates/client-core/src/ffi.rs:1196

- **模型 key、路由与用量页面补全**（界面，P1，+1.5 人日）
  页面清单（都在 12.4）：
  1. key 列表。入口：设置 → 模型 key。显示厂商、名字、后 4 位、是否停用、每日上限。
  2. 添加 key：从 vendors() 选厂商，显示它支持的协议、推荐模型和说明；选“自定义”时要填 https 的 anthropic、openai、responses 地址；订阅类 key 被拒时显示原因。
  3. 编辑 key（缺）：改名、启用或停用、换 key。启用 key、换 key 会唤醒等 key 的运行（7.11）。后端有 PATCH /v1/credentials/{id} 和 PUT /v1/credentials/{id}/secret，FFI 没有。
  4. 实例模型路由。入口：实例详情、输入框的模型标签。
  - main 别名必须有；
  - 可选的 key 按“agent 接入方式的协议”和“厂商协议”的交集过滤（架构 5.3）；
  - 上游模型可以选推荐的，也可以手填；
  - 降级链最多 3 个备用。
  5. 用量看板。入口：设置、对话页的用量按钮（对应 Claude 对话里的用量按钮）。按天、实例、模型、key 分组，用 Swift Charts 画，标出估算和失败次数。
  依据：ffi.rs:544 VendorInfo.protocols、:1516 vendors、:1535 add_credential、:175-189 ModelRoute / RouteFallback、:1481 usage；routes/mod.rs:116-127；docs/architecture-v3.md 5.3；docs/progress.md:61（7.11 启用、换 key 时唤醒）

- **密码保险箱界面（并入 12.4，原估算没算）**（界面，P1，+3 人日）
  页面清单：
  1. 保险箱列表。入口：设置 → 保险箱。显示名字、用途、有没有账号、能用它的实例、最近使用时间。
  2. 新建和编辑：
  - 名字规则：小写字母或数字开头，只含 [a-z0-9_-]，最长 64；密码至少 4 个字符；
  - 重名时用 unique_vault_name 推荐一个新名字；
  - 实例范围可以多选；
  - 详情只显示账号，密码永不显示、只能替换。
  3. 删除。
  4. agent 填写请求。入口：对话里的 vault.requested 卡片、推送、收件箱、保险箱页的“待填写”分区。用户可以填写提交（fulfill）或拒绝（decline）；用途是 agent 写的，要带 AI 生成标识；7 天没处理显示已过期。
  progress 里的 9.11 和 11.6 都写了“界面并入 12.4”，但 12.4 的 4 人日只够 key 和别名。
  依据：ffi.rs:1659-1749（vault_items…decline_vault_request）、:912 unique_vault_name、:796 VaultRequest.purpose 的注释；docs/vault.md §1 §2；docs/wbs.md:245（11.6：界面并入 12.4 / 13.4）；docs/progress.md:55-56

- **发给第三方 AI 之前的明示同意（审核 5.1.2(i)）**（平台，P1，+0.5 人日）
  2025 年 11 月修订后的审核指南 5.1.2(i) 明确：把个人数据分享给第三方（包括第三方 AI）之前，要清楚告知并取得明确同意。我们的情况是：用户的消息、文件、产出物经模型网关转发给用户自己配的厂商。做法：添加 key 或给实例配模型路由时显示“这个实例里的对话和文件会发给 {厂商} 处理，受其条款约束”，用户确认后才保存；还没确认过的，首次在实例里发消息前再拦一次。隐私政策（16.4）同步写明，审核备注里附截图。
  依据：docs/architecture-v3.md 5.2 请求链路、5.5 模型路由；crates/client-core/src/ffi.rs add_credential、set_model_routes

### 12.5 对话与运行过程

- **运行状态文案按 state 在本地生成，state_reason 按来源分别处理**（审查，P1，+0.25 人日）
  state_reason 的来源和语言并不统一：(1) waiting_quota 的 reason 是服务端按用户语言写的（KeyProblem::describe）；(2) waiting_approval 的 reason 是 agent 写的审批标题，要带 AI 生成标识，当作不可信文本显示；(3) 流水线根运行的 reason 是英文 "running N steps"，这种 run.state 事件只有 {state, steps}，没有 reason；(4) 失败原因（Run.error、预算超限等）是英文诊断信息。所以界面上的主文案（等你审批、等补 key、等电脑上线、等子任务、第 N 次重试、成功、失败、已取消）按 state 本地化生成。reason 只在 waiting_quota 时当正文显示，其他情况放进“详情”。失败时显示“任务失败”，英文原因折叠起来。另外：waiting_device 只有登录着电脑的用户才会遇到（14.x），P1 只要准备好文案。抽屉里每个实例的等待红点需要每个实例最近一次运行的状态，现在只能逐个实例调 runs()。
  依据：crates/orchestrator/src/waits.rs:75-90；crates/orchestrator/src/executor.rs:1799（transition(WaitingApproval, title)）、1517（"step budget exceeded"）、988-989；crates/orchestrator/src/pipeline.rs:105、111-114；docs/i18n.md 第 3 节（失败原因是英文诊断）

- **AI 生成标识要有一张规则表，ai_generated 只覆盖三种事件**（审查，P1，+0.5 人日）
  InstanceEvent.ai_generated 只对 agent.message、agent.thought、agent.plan 为真。但界面上还会显示很多 agent 写的文字，这些地方标识位都是 false 或者根本没有标识位：工具调用和平台工具调用的标题、Approval.title（收件箱里审批条目的 ai_generated 是 title.is_some()）、VaultRequest.purpose、created_by=agent 的计划标题、plan.needs_confirmation 和 delegate.started 里的 title、Run.summary、委派子运行的 Run.prompt（是负责人 agent 写的，不能显示成“用户说”）、流水线步骤 prompt 里交接说明附带的上游摘要、产出物名、电脑审批的说明。在 12.1 的 AI 标识组件旁边配一张“字段 → 要不要标”的规则表，12.5、12.6、12.15、12.18 统一用。复制和分享时追加的标识文字要和 proto::labels 的中英文一致。
  依据：crates/proto/src/labels.rs:37-39；crates/orchestrator/src/executor.rs:1782、1903；crates/orchestrator/src/vault.rs:161；crates/orchestrator/src/tools.rs:184；crates/orchestrator/src/delegate.rs:164；crates/orchestrator/src/computer.rs:59；docs/compliance.md:13

- **on_reset 之后要重新拉运行列表；超过 30 天保留期的运行只剩摘要**（审查，P1，+0.25 人日）
  收到 reset 时，client-core 会删掉这个实例在缓存里的全部事件，把续传位置设到 oldest_seq，然后服务端把保留期内的事件全部补发一遍。App 要做的：(1) 清空归并状态，但运行记录要留着，并且重新调 runs() / older_runs()，用户气泡来自 Run.prompt；(2) 补发时事件会一下子涌进来，视图模型要按批提交；(3) 比 oldest_seq 更早的运行已经没有事件了（事件默认保留 30 天），这类运行只显示 prompt、summary、error，标注“过程记录已超过保留期”；(4) cached_events 只能按 after_seq 往后读，打开页面时想先显示最后一屏，需要 11.8 加“某个 seq 之前的 N 条”。四个视角只写了“整体重载”。
  依据：crates/client-core/src/cache.rs:229-241（reset_events）；crates/client-core/src/events.rs:339-349；crates/client-core/src/ffi.rs:1329-1344（cached_events(after_seq)）；docs/architecture-v3.md 4.8（保留 30 天）

- **Swift 的事件模型里漏了 instance.state**（审查，P1，+0 人日）
  control 在实例状态变化（领养、唤醒、暂停、归档）时会写 instance.state 事件。这个事件没有 run_id，载荷是 {state}。12.1 已经写好的 Swift EventKind 里没有它，现在会被当成未知事件丢掉。要补上，用在对话页页头和抽屉里显示实例状态，比如“正在唤醒（已归档的实例要从模板重建，会慢一些）”。另外 ios.md 第 5 节和安卓设计规范 8.2 的“事件 → 界面”对照表里也要加上这一行。
  依据：apps/apple/ThinktinKit/Sources/ThinktinKit/Models/Events.swift:97-125；crates/control/src/lib.rs:184-185、546、567；crates/proto/src/domain.rs:136-145

- **对话时间线与 Markdown 渲染**（界面，P1，+2 人日）
  对话页的时间线怎么拼：事件流里没有用户消息（创建运行时不写事件），所以用户气泡要用 runs() / cached_runs 里的 prompt，按 run_id 和事件合并。来源是计划、流水线或委派的运行，显示“计划触发：标题”这样的分隔头。
  消息渲染：agent.message 的分片按运行拼起来，流式渲染 Markdown（标题、列表、表格、代码块高亮和复制、链接）。ai_generated 为真时显示标识。
  消息操作（对照 Claude 的操作栏）：
  - 复制：复制 agent 的输出时要带上 AI 生成标识（合规说明里写明由 App 实现）；
  - 分享；
  - 重试：用同一个 prompt 再调一次 create_run；
  - 编辑已发的消息：没有接口，隐藏。
  接口缺口：FFI 的 runs 没有 before 参数（api.rs 有），更早的运行翻不了页。
  依据：crates/gateway/src/routes/runs.rs:20-44（create 不写事件）；ffi.rs:1241 runs(instance_id, limit)、:491 InstanceEvent.ai_generated；crates/client-core/src/api.rs:777（runs 支持 before）；docs/compliance.md:13（复制、导出带标识，App 端实现）

- **运行过程的事件卡片**（界面，P1，+2.5 人日）
  按事件种类做卡片：
  - agent.thought：折叠的“思考过程”。
  - agent.plan：待办清单，显示每项状态。
  - agent.tool_call、agent.tool_call_update：工具调用条，显示标题、种类、状态，展开看原始内容。
  - agent.platform_tool_call：平台工具调用（建计划、委派、发布产出物等）。
  - agent.permission_requested / permission_resolved：内联审批卡，可以跳审批中心或直接选选项；按预授权自动批准的显示“已按预授权批准”。
  - vault.requested：内联的保险箱表单卡。
  - plan.needs_confirmation：计划待确认卡。
  - artifact.published：产出物卡，点开预览。
  - delegate.started、pipeline.step_started：子任务卡，点开跳运行树。
  - run.state：状态分隔条；第 2 次及以后的尝试显示“第 N 次尝试 / 已从断点续跑”。
  - agent.session_lost、agent.exited（会重启时）、run.log_truncated、agent.error：对应的提示条。
  - agent.usage：本轮用了多少 token。
  另外，on_reset 回调时整页重新加载。12.5 只写了“工具调用展示”。
  依据：crates/orchestrator/src/shim.rs:119-139 event_kind；crates/orchestrator/src/tools.rs:191（plan.needs_confirmation）；vault.rs:168（vault.requested）；artifacts.rs:258（artifact.published）；pipeline.rs:251（pipeline.step_started）；delegate.rs:163（delegate.started）；ffi.rs:920 EventListener.on_reset

- **输入框（停止、排队、语音、模型标签、密码拦截）**（界面，P1，+1.5 人日）
  对照 Claude 的输入框：
  - 多行输入和发送。运行中发送键变成“停止”（cancel_run(run, false)）。
  - 同一实例一次只跑一个运行，有运行时新消息进排队，显示“排队中”。
  - 语音听写：用系统 Speech 框架，需要麦克风和语音识别的权限说明。
  - 模型标签：显示 main 路由的上游模型，点开去路由页（不能逐条换模型）。
  - 长度上限 32000 字。
  密码拦截流程（11.6）：
  1. 发送前调 detect_secrets，命中就拦下。
  2. 弹保险箱表单，预填命中的值和建议名。私钥这类存不进保险箱的，只提示别发。
  3. 命中的是模型厂商的 key 时，提示“添加为模型 key”。
  4. 用户确认后调 save_secret_from_message，把换成引用的消息放回输入框。
  5. 用户坚持要发时带 allow_secrets 发送；服务端返回 ContainsSecrets 时也走这个流程兜底。
  附件和拍照后端没有接口，单独列一条。
  依据：ffi.rs:1629 send_message、:888 detect_secrets、:833 DetectedSecret（storable、service）、:1642 save_secret_from_message；docs/vault.md §7；routes/runs.rs:27（prompt 最长 32000）；docs/architecture-v3.md 4.3（同一实例同时只执行一个运行）

- **运行详情页（对应 Claude Code 的会话详情）**（界面，P1，+1 人日）
  入口：时间线里的运行分隔条、收件箱条目、推送（tt.run）、计划的运行历史。
  控件：
  - 状态和状态说明、来源、所属计划链接、尝试次数、已用 token、开始和结束时间；
  - 摘要（带 AI 生成标识）、错误信息；
  - 本次的产出物（run_artifacts）；
  - “只看本次过程”（按 run_id 过滤事件）；
  - 停止，或者停止整棵树（cancel_run 的 whole_tree）；
  - 有子运行时进运行树。
  委派（8.7 已完成）也会产生运行树，不只是流水线，所以运行树组件在 12.5 就要能用，12.7 复用它。WBS 里只有 12.7 写了“运行树视图”，没有单个运行的详情页。
  依据：ffi.rs:191 Run 的字段、:1263 get_run、:1270 cancel_run、:1276 run_tree、:1289 run_artifacts；docs/progress.md:64（8.7 委派会建子运行）；crates/notify/src/apns.rs:133-142（推送的 tt.run）

- **等 key、等审批等状态的提示与跳转**（界面，P1，+1 人日）
  对话页顶部和抽屉里的实例行都要显示等待状态，并能一键跳去处理：
  - 等待审批 → 横幅“等你审批”，点开审批卡或审批中心。
  - 等待额度 / key → 显示状态说明（服务端已按用户语言写好），“去处理”跳到这个实例的模型路由或添加 key 页面。
  - 等待电脑上线 → 提示“等电脑上线”。P3 之前不会出现，先备好文案。
  - 等待子任务 → 跳运行树。
  - 重试等待 → 显示“重试中”。
  两处依据不足：
  - run.state 事件和 Run 里只有文字说明，没有结构化的原因码，App 分不清“key 无效、要用户换”和“被限流、会自己重试”（见后端补齐那条）。
  - 抽屉的“进行中”分区要跨实例的运行列表，现在只能对每个实例调一次 runs()。
  依据：crates/proto/src/domain.rs:199 RunState（三种等待 + 等待子任务）；crates/orchestrator/src/waits.rs KeyProblem（describe、transient）；crates/orchestrator/src/executor.rs:985-991（run.state 的内容只有 state、reason、attempt）；ffi.rs:1241 runs 按实例

- **AI 内容举报入口（审核 1.2、4.7 对聊天机器人的要求）**（平台，P1，+1.5 人日）
  审核对 AI 聊天类 App 通常要求有过滤和举报机制，并能及时处理。10-14 拍板不接第三方内容审核（问题 7），所以至少要有“举报 / 反馈这条回复”：长按 agent 消息或产出物，选原因，提交到服务端记录（运行 id、事件 seq、原因，进审计，由运营处理）。gateway 现在没有这类接口，要新增（Rust 1 天），App 端 0.5 天。审核备注里说明处理流程和时限。
  依据：crates/gateway/src/routes/mod.rs（没有举报或反馈接口）；docs/progress.md 已拍板问题 7

- **复制、分享 agent 输出时带“AI 生成”标识**（平台，P1，+0.5 人日）
  docs/compliance.md 第 1 节把“复制、导出时带上标识”留给了 App 端实现。SwiftUI 的 .textSelection(.enabled) 走系统复制，加不上标识。对 agent 消息改用自己的“复制”“分享”菜单：UIPasteboard 和 ShareLink 的内容末尾加上和 proto::labels 相同的文字，按界面语言选。另一个办法是保留系统选择复制，但要法务确认能接受这个缺口。收件箱和推送里的标识服务端已经加了。
  依据：docs/compliance.md:13“复制、导出：客户端在复制 agent 输出时带上标识（App 端实现，WBS 12.x / 13.x）”；crates/client-core/src/ffi.rs InstanceEvent.ai_generated

### 12.6 计划管理

- **触发规则失效被停用后，用户不会知道**（审查，P1，+0.25 人日）
  调度器发现触发规则解析不了时，会把触发器停掉（不再有下次触发时间），但只写一条审计，不通知用户。计划列表接口里 triggers 是空的，所以只有打开详情页才能看到 Trigger.enabled=false。用户会以为计划还在照常跑。要做的：(1) 12.6 详情页显示“规则已失效，已停用”，并给出“修改规则”入口（delete_trigger 加 add_trigger）；(2) 请 10.7 在停用时发一条 INFO 通知（带 plan_id），并在计划列表里带上触发器摘要（是否有已停用的、下次触发时间）。
  依据：crates/orchestrator/src/scheduler.rs:102-117（只有 advance_trigger 和 audit，没有 notify）；crates/client-core/src/ffi.rs:340-346（Trigger.enabled）、393（列表接口里为空）

- **agent 建的计划待确认流程**（界面，P1，+1 人日）
  规则（已拍板问题 3）：agent 通过 thinktin.schedule 新建或修改的计划先暂停，等用户在 App 里确认才生效。
  入口：对话里的 plan.needs_confirmation 卡片、推送（info 类，带 tt.plan）、收件箱、计划列表的“待确认”分区和角标。
  确认页显示：标题（agent 起的，带 AI 生成标识）、目标、用大白话描述的触发规则、策略、流水线步骤。
  按钮：
  - “确认生效”：confirm_plan(plan_id, revision)。返回冲突时提示“计划又被改过”，重新拉取后再给用户看。
  - “修改后确认”。
  - “删除”。
  待确认的计划不能用 set_plan_paused 直接恢复。12.6 没写这个流程。
  依据：ffi.rs:380 Plan（awaiting_confirmation、revision）、:1414 confirm_plan 的注释；docs/progress.md:126（已拍板问题 3）；crates/orchestrator/src/tools.rs:180-192

- **计划编辑器（触发规则、策略），依赖补接口**（界面，P1，+2 人日）
  新建和编辑计划包括：
  1. 触发规则编辑器：每天、每周、每月、一次性，以及高级 cron；时区默认用设备时区；生成 cron 或 RRULE；显示下次触发时间。
  2. 策略：
  - 预授权的工具种类；
  - 审批超时和超时后的动作（跳过、暂停计划、失败）；
  - 单次运行预算：最大 token、最长时长、最多步数；
  - 每日 token 上限；
  - 等电脑 / 等 key 的超时；
  - 补跑策略（只补一次、全部补跑、跳过）。
  3. 运行历史：按 plan_id 过滤实例的运行。
  接口缺口：
  - FFI 的 NewPlan 没有 policy 和 catch_up 两个字段，新建时设不了策略。
  - FFI 没有 update_plan、add_trigger、delete_trigger，“编辑”做不了。后端的 PATCH /v1/plans/{id}、POST /v1/plans/{id}/triggers、DELETE /v1/triggers/{id} 都有。
  - 计划列表接口不带触发器，列表上要显示下次运行时间就得逐个拉详情。
  依据：ffi.rs:440 NewPlan（没有 policy）、:380 Plan.triggers 的注释“列表接口里为空，详情里有”；crates/proto/src/domain.rs:353 PlanPolicy、:287 CatchUp；routes/plans.rs:101-113、:210-217；routes/mod.rs:78-87

### 12.7 团队与流水线

- **团队模板一键领养出来的实例都没有模型路由**（审查，P1，+0.5 人日）
  adopt_template 只为每个成员领养实例、签发授权，不配模型别名。每个 agent 用的是自己实例上配的 key（架构 4.11），所以新实例在配好 main 之前，一跑就进 waiting_quota（Unavailable：没有能用的 key）。如果新实例是流水线的某一步，这一步会卡住，根运行停在 waiting_children。执行器对“等 key”照样推送，但推送里的 run 是子运行的 id。要做的：(1) 12.7 领养完成后弹出“逐个配置模型”的列表，复用 12.4 的路由编辑，没配好的成员标红；(2) 运行树里，卡在等 key 的子步骤要冒泡到根节点上显示；(3) 推送和深链指向子运行时，能落到运行树里对应的节点。
  依据：crates/gateway/src/routes/teams.rs:182-210；crates/orchestrator/src/waits.rs:26-27（Unavailable）；crates/orchestrator/src/executor.rs:992-994（流水线步骤不单独通知，等 key 照样通知）；docs/architecture-v3.md 4.11（每个 agent 用它自己实例配置的模型别名和 key）

- **团队与流水线页面（工作量已含，接口被卡）**（界面，P1，+0 人日）
  页面清单：
  1. 团队列表。入口：抽屉的“团队”（对应 Claude 的 Projects）。
  2. 团队详情和编辑：成员、负责人、顺序。
  3. 存为模板。
  4. 模板列表和一键领养。
  5. 流水线编辑器：每一步的 key、实例、提示词、依赖，做环检测。
  6. 运行树视图。
  工作量在 12.7 的 8 人日里已经算了。但 client-core 里没有团队和模板的任何方法（api.rs 和 ffi.rs 都没有），后端的 /v1/teams 和 /v1/team-templates 已经有了，所以要先补接口（见 11.7）。
  依据：routes/mod.rs:129-139（teams、team-templates）；crates/client-core/src/api.rs 和 ffi.rs 里都没有 team 方法；crates/proto/src/domain.rs:691-735（Team、TeamTemplate、PlanStep）

### 12.8 推送与收件箱

- **推送路由的几种边角情况：换账号、电脑审批、收件箱条目不在缓存**（审查，P1，+0.25 人日）
  (1) 推送的 tt 里只有 kind 和几个 id，没有用户 id。退出登录或换账号之后，通知中心里还留着上一个账号的通知，点开会遇到 not_found。所以退出登录时要清掉已送达的通知（removeAllDeliveredNotifications）、把角标设为 0、结束所有实时活动；点通知遇到 not_found 时给轻提示。(2) COMPUTER_APPROVAL 推送里没有设备消息 id，也没有 instance 和 run，App 打开后要先调 device_messages() 去取（12.9）。(3) tt.inbox 指向的条目可能不在缓存的那一页里，要用 inbox_item(id)（11.7）补取，再 mark_inbox_read。
  依据：crates/notify/src/apns.rs:131-142；crates/orchestrator/src/computer.rs:52-63；docs/progress.md 已完成表“评审”行（推送只发给登录着的设备）；origin/backend-core 的 ffi.rs:1886（inbox_item）

- **推送类别、锁屏拒绝审批与收件箱补全**（界面，P1，+1.5 人日）
  推送：
  - 注册 5 个通知类别：RUN_FINISHED、RUN_FAILED、APPROVAL、COMPUTER_APPROVAL、INFO。
  - APPROVAL 只放“拒绝”按钮，批准必须进 App 做生物识别。点“拒绝”时 App 在后台调 approvals() 找到拒绝选项，再调 decide_approval。
  - 锁屏时也要能拒绝：SessionStore 存进 Keychain 时要用“首次解锁后可读”的属性，否则锁屏状态下拿不到会话。
  - 审批推送是 time-sensitive，要开 Time Sensitive Notifications 能力。
  - 用 thread-id 分组；tt 里的各种 id 交给统一的深链路由；应用图标角标用 cached_unread；推送令牌变了调 set_push_token。
  收件箱：按天分组、种类图标、AI 生成标识、左滑标已读 / 未读 / 删除、“全部已读”、翻更早的页、离线时读缓存。
  接口缺口：
  - FFI 没有标未读和删除，后端的 /v1/inbox/{id}/unread 和 DELETE /v1/inbox/{id} 都有。
  - agent 请用户填账号密码的推送是 info 类，推送里没有请求 id，App 只能按 run 去 vault_requests() 里找。
  依据：crates/notify/src/lib.rs:47-55（category）、:102 PushTarget；crates/notify/src/apns.rs:113-145（payload、time-sensitive、tt）；docs/architecture-v3.md 8.3（拒绝可以在通知上点）；ffi.rs:44 SessionStore、:1467 mark_inbox_read；routes/mod.rs:151-154；crates/orchestrator/src/vault.rs:153-161

- **通知类别与可操作通知（拒绝直接处理，批准进 App）**（平台，P1，+1 人日）
  服务端已定的类别：RUN_FINISHED、RUN_FAILED、APPROVAL、COMPUTER_APPROVAL、INFO。App 启动时在 App 代理里注册同名的 UNNotificationCategory。APPROVAL 的“拒绝”是后台操作，标 .destructive 和 .authenticationRequired（锁屏时要先解锁，防路人点）。推送载荷的 tt 里只有审批 id、没有选项 id，所以后台处理要先调 approvals() 找 kind=reject_once 的选项，再 decide_approval。没有拒绝选项或调用失败时，发一条本地通知“请在 App 里处理”。系统只给大约 30 秒，所以 didFinishLaunching 里就要能建好客户端。APPROVAL 的“查看并批准”是 .foreground：进审批页，过本机验证后才批准。COMPUTER_APPROVAL 只给“查看”（批准要签名，P3）。RUN_FINISHED / RUN_FAILED 可以加“标为已读”（mark_inbox_read）。另外三点：通知权限在有上下文时再要（第一次建计划或领养之后），不在冷启动时弹（4.5.4：推送不能是使用前提）；锁屏隐私用 hiddenPreviewsBodyPlaceholder（威胁模型提到摘要可能敏感）；thread-id 已按运行分组，不用改。
  依据：crates/notify/src/lib.rs:48 category()；crates/notify/src/apns.rs:114-142 payload（tt 只有 id）；crates/client-core/src/ffi.rs ApprovalOption.kind；docs/architecture-v3.md 8.3；docs/threat-model.md:99

- **批准前的本机验证提前到 P1**（平台，P1，+0.5 人日）
  decide_approval 的注释要求“批准前原生端要先做生物识别确认”。云端审批服务端不验签，P1 只能靠 App 里的 LocalAuthentication：evaluatePolicy(.deviceOwnerAuthentication)，没有面容或指纹时退到锁屏密码。但 WBS 把 Face ID 放在了 P2 的 12.9，P1 阶段批准就没有任何验证。把这一步挪到 P1（12.8 或 12.5 的审批卡片），12.9 只留 Secure Enclave 签名（电脑审批用）。
  依据：crates/client-core/src/ffi.rs decide_approval 的注释；crates/gateway/src/routes/approvals.rs:24-49（不验签）；docs/wbs.md 12.9

- **推送过期时间是 0：手机离线时系统通知会丢**（平台，P1，+0.25 人日）
  apns.rs 把 apns-expiration 设成 ttl，没有 ttl 时为 0。只有审批（executor.rs:1779）和电脑审批设了 ttl。运行完成、运行失败、保险箱请求、计划待确认、账号通知的 ttl 都是 None，于是 apns-expiration 为 0，APNs 的含义是“只投一次、不保存”。手机关机、飞行模式或没信号时，这些通知直接丢掉（收件箱里还在，但锁屏上不会出现），和 17.3“断网一夜后事件不丢”的验收冲突。改法：默认给一个过期时间（比如 24 小时或 7 天）。安卓的厂商通道也检查一下同样的默认值。
  依据：crates/notify/src/apns.rs:187-190 `message.ttl.map_or(0, ...)`；crates/orchestrator/src/outbox.rs:124 `ttl: None`；crates/orchestrator/src/executor.rs:1779、computer.rs:57（只有这两处设了 ttl）；docs/wbs.md 17.3

- **推送的服务端补齐：沙盒 / 生产环境、保险箱请求的跳转目标、角标**（平台，P1，+2 人日）
  (a) [push.apns] 只配一个 endpoint，PushChannelKind 也只有 apns。Xcode 直装的包拿到的是 sandbox 令牌，TestFlight 和 App Store 是 production 令牌，连同一个服务端时总有一种收不到；而且 apns.rs 把 BadDeviceToken 当成失效令牌删掉。改法：上报令牌时带上环境（新增 apns_sandbox 通道，或在设备上加环境字段），服务端两个端点都配上。(b) PushTarget 只有 instance、run、approval、plan、inbox 几个字段，没有保险箱请求 id，而 ios.md 6.1 和安卓设计规范都已定了 thinktin://vault/request/{id}。保险箱请求、计划待确认、账号冻结都发 PushKind::Info（类别 INFO、优先级 5），App 分不清是哪种，保险箱请求还可能被系统延后送达。改法：载荷加 tt.vault_request，新增 VAULT_REQUEST、PLAN_CONFIRM 两个类别，优先级 10。(c) 载荷不带 badge，App 不在前台时图标角标不会变；带上收件箱未读数（安卓 13.8 的未读角标也要）。(d) macOS App（P3）的 bundle id 不同，topic 也要按平台分别配。
  依据：crates/server/src/config.rs:484-498 Apns 只有一个 endpoint；crates/proto/src/domain.rs:127 PushChannelKind；crates/notify/src/apns.rs:171-176 优先级、:227 BadDeviceToken；crates/notify/src/lib.rs:101 PushTarget；crates/orchestrator/src/vault.rs:155-162、tools.rs:185 都是 PushKind::Info；docs/ios.md 6.1

- **前后台切换、冷启动路由与深链**（平台，P1，+1 人日）
  iOS 进后台几秒后 App 会被挂起。client-core 的事件流要靠 80 秒空闲超时加最长 30 秒退避才发现连接已断。所以 scenePhase 进 background 时 stop() 所有 EventSubscription，回到 active 时从最后的 seq 重新订阅，并调 sync_inbox；正在进行的 decide 和 send_message 用 beginBackgroundTask 包住。按架构 8.4 不用 BGAppRefreshTask，数据新鲜度只靠推送和回前台同步，这一点写进文档。冷启动点通知：UNUserNotificationCenter.delegate 必须在 App 代理的 willFinishLaunching 里设好（SwiftUI 用 UIApplicationDelegateAdaptor），否则这次点击会丢。路由先排队，等会话恢复或登录完成再跳转；进审批页时先刷新状态，它可能已超时或已在别的设备处理。thinktin:// 已在 project.yml 注册。Universal Links 需要域名上的 apple-app-site-association 文件和 Associated Domains 能力，跟 IM 渠道一起在 P4 做（IM 消息里放“打开 App”的链接），另计 0.5 天。
  依据：crates/client-core/src/events.rs:58-71（idle_timeout 80s、max_backoff 30s）；docs/architecture-v3.md 8.4；docs/ios.md 6.1；apps/apple/project.yml CFBundleURLTypes

### 12.9 审批与签名（电脑高危操作）

- **手机侧配对、电脑高危审批与能力令牌界面**（界面，P3，+2 人日）
  P3 的三个页面：
  1. 扫码配对：相机扫 thinktin-pair:v1 二维码 → parse_pairing_offer → 用 Secure Enclave 签 pairing_response_message → 经平台发给电脑 → 收到电脑的确认后验签。
  2. 电脑高危审批：COMPUTER_APPROVAL 推送上没有按钮，要进 App 看工具名、参数、说明；Face ID 解锁私钥后签 approval_message，批准和拒绝都要签。
  3. 能力令牌管理（缺）：给电脑签发 CapabilityGrant（能碰的目录、能操作的应用、有效期）、令牌列表、吊销。
  缺口：
  - 14.8 的交付物只写了“扫码配对、手机签名、电脑验签”，没有能力令牌的签发和吊销界面。
  - 设备消息的 FFI（send_device_message、device_messages、ack）还没导出。
  依据：docs/pairing.md §2-§4、§6；docs/relay.md:97-99、:134；crates/client-core/src/pairing.rs:245-543（导出的签名和验签函数）；crates/notify/src/lib.rs:30 ComputerApproval；docs/wbs.md:291

- **12.9 审批与签名：补平台细节和 FFI 缺口**（平台，P2，+2 人日）
  交付物和安卓 13.9 对齐，补上“扫码配对电脑、审批消息签名、能力令牌签发与吊销”。平台细节：SecKeyCreateRandomKey 用 kSecAttrTokenIDSecureEnclave。访问控制二选一，由产品定：.privateKeyUsage + .biometryCurrentSet（录入新的面容或指纹后密钥失效，要有“重新配对”流程），或 .userPresence（允许用密码，安全性低一档）。公钥用 SecKeyCopyExternalRepresentation 导出（65 字节 SEC1，pairing.rs 认得）。模拟器没有 Secure Enclave，所以签名器做成协议，模拟器和 CI 用软件密钥。扫码用 VisionKit 的 DataScannerViewController，加中英文的 NSCameraUsageDescription。FFI 缺口：api.rs 有 send_device_message、device_messages、ack_device_messages，ffi.rs 没导出，手机收不到电脑发来的审批请求，也发不出签名结果，要补（Rust 0.5 天）。
  依据：crates/client-core/src/api.rs:628-672；crates/client-core/src/ffi.rs（没有设备消息的方法）；docs/pairing.md 第 1 节、第 5 节；origin/android-app:docs/wbs.md 13.9

### 12.10 实时活动

- **实时活动需要后端的 liveactivity 推送**（界面，P2，+2 人日）
  要在灵动岛和锁屏上更新运行进度，需要 APNs 的 liveactivity 推送类型，以及单独的 activity 令牌和 push-to-start 令牌。notify 现在只发 alert 类型。
  要补的工作：
  - 后端（扩展 10.1）：加 liveactivity 推送和令牌上报接口，约 1.5 人日 Rust。
  - App：上报令牌，约 0.5 人日。
  WBS 的 12.10 只写了 App 一侧。
  依据：crates/notify/src/apns.rs:185（apns-push-type 固定是 "alert"）；docs/wbs.md:260

- **12.10 实时活动：App 端还缺的部分**（平台，P2，+1.5 人日）
  现有 3 天只够做界面，还要：XcodeGen 加 Widget Extension target；ActivityAttributes 和 ContentState 放进一个不依赖 Rust 核心的小模块，扩展不链 libclient_core；Info.plist 加 NSSupportsLiveActivities，需要时再加 NSSupportsLiveActivitiesFrequentUpdates；做灵动岛的紧凑、最小、展开三种布局和锁屏布局；用 Activity.pushTokenUpdates 拿到每个活动的令牌并上报。iOS 17.2 起用 pushToStartTokenUpdates，App 没打开时计划开始也能自动起活动；低于 17.2 只给在 App 前台开始的运行起活动。活动最长 8 小时，运行预算默认 6 小时，够用；结束时设 dismissal-date。活动里只放状态、步骤和耗时，不放 agent 正文（锁屏隐私，也免去 AI 标识）。App 在前台时用事件流本地更新，后台靠推送。
  依据：docs/wbs.md 12.10“运行进度显示在灵动岛与锁屏”；docs/architecture-v3.md 4.7（默认最长 6 小时）、8.4

### 12.11 上架

- **上架补充：开源许可页、备案号、权限说明**（界面，P1，+1 人日）
  1. 开源许可页。入口：设置 → 关于 → 开源许可。读 ThinktinCore 包里的 Licenses/inventory.json 和 NOTICES.md；App 自己用的 Swift 依赖也要加进清单。progress 16.5 指定这个页面在 12.x 做。
  2. 关于页：显示 App 备案号（16.1，工信部要求在显著位置标明）、隐私政策、用户协议、AI 生成内容说明。
  3. Info.plist 权限说明和隐私清单：Face ID、麦克风、语音识别、相机（P3 扫码配对用）、相册（保存产出物用），以及隐私清单里的必需理由 API。
  依据：docs/licenses.md:15、:23、:179；docs/progress.md:94（App 的开源许可页由 12.x、13.x 做）；docs/wbs.md:309（16.1 ICP 备案）

- **隐私清单补全，CI 扫描 required-reason API**（平台，P1，+1 人日）
  PrivacyInfo.xcprivacy 已声明 UserDefaults、文件时间戳、开机时间三类 API，以及手机号、设备 ID 两种数据。还缺四项。(a) 磁盘空间类 API：rusqlite 打包的 SQLite 在 __APPLE__ 下默认开 SQLITE_ENABLE_LOCKING_STYLE，会调 statfs / fstatfs（苹果列在 Disk space API 里），要声明 E174.1。(b) 收集的数据类型：用户内容（对话、提示词、产出物，归 Other User Content）、名字（display_name）、模型 key 和保险箱密码（Other Data）、用量（Other Usage Data），用途都是 App 功能、和账号关联。以后上传诊断再加 Crash / Performance Data。(c) 上传时 App Store Connect 按二进制里的符号检查（ITMS-91053），Rust 代码也算在内。CI 加一步：对 libclient_core.a 和 App 二进制跑 `nm -u`，对照苹果的 required-reason 符号表，有新符号没声明就失败。(d) App Store Connect 的隐私问卷、这份清单、隐私政策（16.4）三者保持一致。
  依据：apps/apple/Thinktin/Resources/PrivacyInfo.xcprivacy；~/.cargo/registry/src/*/libsqlite3-sys-0.37.0/sqlite3/sqlite3.c:39265-39269（Apple 上 LOCKING_STYLE=1）、:45195 statfs、:45960 fstatfs、:39641 和 :39654 stat / fstat；crates/client-core/Cargo.toml rusqlite features=["bundled"]

- **审核材料清单：BYOK 说明、年龄分级、截图、IPv6**（平台，P1，+2 人日）
  现在 12.11 只写了“审核材料、隐私清单”，3 天。按下面的清单补齐。(a) 审核备注：agent 在云端沙箱里运行，App 不下载、不执行代码（2.5.2）；模型 key 是用户在厂商那里自己的账号，App 不卖它，也不靠它解锁 App 功能（不属于 3.1.1 说的许可证密钥），平台不经手模型费用；说明保险箱、审批、AI 标识；附 1–2 分钟的操作录屏。(b) 年龄分级：按 2025 年新版问卷（13+ / 16+ / 18+）填。agent 能联网，生成内容不受限，预计 16+ 以上。(c) 出口合规：project.yml 已设 ITSAppUsesNonExemptEncryption=false，把依据记下来：只用标准 TLS 和用于认证的 ECDSA 签名，属于豁免。(d) 截图：6.9 英寸 iPhone，zh-Hans 和 en 两套；元数据两种语言；名称、副标题、关键词里不出现 Claude、Codex 等第三方商标（2.3.7、5.2.1）。(e) 隐私政策网址、支持网址。(f) 2.5.5 要求在纯 IPv6 网络下可用：在 Mac 的 NAT64 网络共享下实测登录、事件流、推送。reqwest 和 tokio-tungstenite 走 getaddrinfo 没问题，但服务端不能下发 IPv4 字面量地址。(g) “请升级”页面要放 App Store 链接，需要 App 的 Apple ID，建好 App 记录后再填。
  依据：docs/wbs.md 12.11；apps/apple/project.yml ITSAppUsesNonExemptEncryption: false；docs/licenses.md 第 6 节第 2 条；docs/ios.md 第 6 节 UpgradeRequired

- **审核演示账号与演示数据**（平台，P1，+1.5 人日）
  登录只有手机号验证码，审核员收不到短信。审核员也没有模型 key，BYOK 模式下 agent 跑不起来，会按 2.1（功能不完整）被拒。要做两件事。一是在 auth 里加“审核账号”配置：指定号码加固定验证码，只从环境变量或密钥读取（仓库是公开的，不能写进代码），记审计，随时可关。二是给这个账号预置一个实例、一把平台出资的低额度 key（用 9.5 的限额兜底）、一个示例计划和一次已完成的运行。TestFlight 外部测试的 Beta 审核也要用这个账号。
  依据：crates/auth/src/sms.rs（只有 DevConsoleSms、RecordingSms，加阿里云）；crates/server/src/config.rs:110 dev_sms 只用于本地；docs/architecture-v3.md 5.7 平台额度是可选的

- **首发地区与中国大陆的备案要求**（平台，P1，+0.5 人日）
  在中国大陆 App Store 上架，要在 App Store Connect 填 ICP 备案号。App 备案按 Bundle ID 办，所以 Bundle ID 要先定。生成式 AI 类 App，苹果还会要网信办的备案或登记编号。这些都依赖 16.1、16.2。另外 progress.md 记录了 Claude Code 的地区政策不支持中国大陆。要在 12.11 定首发地区：16.1 / 16.2 办下来之前先不选中国大陆，或者大陆区版本隐藏不合规的 agent。12.11 的前置应加上 16.1、16.2。
  依据：docs/wbs.md 16.1、16.2，12.11 的前置只有 12.8；docs/progress.md 已拍板问题 1；docs/architecture-v3.md 第 11 节

### 12.12 设置、多语言与开源许可

- **新增 12.14 设置中心**（界面，P1，+3 人日）
  建议编号 12.14，名称“设置中心”。入口：抽屉底部的头像。
  分组：
  - 账号：昵称、手机号、设备管理、退出登录、注销。
  - 模型 key 与用量。
  - 保险箱。
  - 通知：系统权限状态、跳系统设置、IM 渠道入口。
  - 外观：跟随系统、浅色、深色。
  - 语言：中文、English。改了调 set_locale，推送和收件箱跟着变。
  - 安全：
  - “全部停止”：确认后调 stop_all，显示取消了几个运行、吊销了几个授权、暂停了几个计划；
  - “下线其他设备”：调 sign_out_other_devices，可以勾选顺带全部停止。
  - 关于：版本、开源许可、隐私政策、用户协议、备案号、AI 生成内容说明。
  对应 Claude 的设置页。这些功能的后端在 4.6、1.6、16.4、16.5 里都做了，但 WBS 里没有界面包。
  依据：ffi.rs:1094 stop_all、:94 StopAllResult、:1100 sign_out_other_devices、:1080 set_locale、:1557 im_channels；docs/architecture-v3.md 4.6；Claude iOS App 的设置页

### 12.14 IM 渠道设置

- **新增 12.18 IM 渠道设置界面**（界面，P4，+2 人日）
  建议编号 12.18，名称“IM 渠道设置”。入口：设置 → 通知 → IM 渠道。
  1. 列表：平台、名字、token 后 4 位、有没有签名密钥、订阅的事件、开关、最近发送时间、最近的错误。
  2. 新建：粘贴 webhook 地址（只认四家官方前缀，自动识别平台）、签名密钥、名字、要发的事件（任务完成、任务失败、审批，至少选一个）。
  3. 发测试消息：每人每小时 10 条，超了提示 429。
  4. 换地址或密钥、开关、删除。
  5. 提示：群机器人的关键词填 ThinkTin；群里不能审批。
  后端和 FFI 都已经有（10.5 在做评审），WBS 里没有对应的 App 工作包。
  依据：docs/im-channels.md §1 §2；ffi.rs:568 ImChannel、:1557-1619（im_channels…delete_im_channel）；docs/progress.md:92（10.5 进行中）

### 12.15 云端审批（审批卡与审批中心）

- **审批：列表只返回待处理的，没有单条查询，事件和审批记录对不上**（审查，P1，+0.25 人日）
  approvals() 只返回 state=pending 且还没过期的审批，也没有 GET /v1/approvals/{id}。agent.permission_requested 事件里是 shim 的 request_id（shim 每次重启从 perm-1 重新编号）；审批记录内部存的是“第几次尝试:request_id”，但 FFI 的 Approval 不带这个字段。后果：(1) 时间线里的历史审批卡片，状态只能从 permission_resolved 或 approval.decided 推出来；两个都没有、待处理列表里也找不到的，显示“已过期或已在别处处理”；(2) 点审批推送时，如果已经处理过，进页面后给提示，不要报错；(3) 同一个运行里同时有多条待审批时，只按 run_id 对不准。请 11.8 给 Approval 加上 request_id 和 attempt，或者在事件里带 approval_id。
  依据：crates/store/src/approvals.rs:184（WHERE state = 'pending' AND expires_at > now()）；crates/gateway/src/routes/mod.rs:89-90；crates/orchestrator/src/executor.rs:1022-1025（approval_key）、1079（事件按 shim 原样写入）；crates/client-core/src/ffi.rs:247-258

- **新增 12.15 审批中心与审批卡（从 12.9 拆到 P1）**（界面，P1，+1 人日）
  建议编号 12.15，名称“审批中心与审批卡”。
  入口：抽屉的“审批”（带待处理数）、对话里的内联审批卡、APPROVAL 推送、收件箱。
  列表每条显示：所属实例、标题、剩余时间（默认 24 小时过期）、工具调用详情（把 tool_call_json 格式化成命令、文件路径、diff）。
  操作：
  - 选项按种类区分样式：允许一次、总是允许、拒绝一次、总是拒绝；
  - 批准前做 Face ID（FFI 注释要求先做生物识别），拒绝不用；
  - 已过期或已被处理的刷新后移走。
  为什么 P1 就要：审批转发 6.13 是 P1，1.2 的 P1 原型也包含审批。不做的话，agent 一请求权限，运行就只能等 24 小时超时、计划被暂停。
  12.9 留下 Secure Enclave 签名和电脑高危审批，这部分只有 14.x 用，可以挪到 P3。新包 3 人日，12.9 相应减 2 人日，净增 1 人日。
  依据：ffi.rs:1346 approvals、:1359 decide_approval（注释“批准前原生端要先做生物识别确认”）、:239 ApprovalOption.kind；crates/proto/src/domain.rs:353 PlanPolicy.approval_timeout_secs；docs/wbs.md:107、:173、:259；crates/notify/src/lib.rs:28 PushKind::Approval

### 12.16 应用框架与导航

- **强制升级：事件流握手遇到 426 会一直重连**（审查，P1，+0.25 人日）
  版本中间件对所有路由生效，包括 /events/ws；App 版本太老时 WebSocket 握手拿到 426。但 events.rs 只认 401、403、404，其他状态码一律按 Dropped 处理，按退避无限重连。StreamStatus 里也没有“需要升级”这个状态，界面只会看到“重连中”。App 要做的：(1) 启动时先调一次 me()，再订阅事件流；(2) 任何 REST 调用返回 UpgradeRequired，就停掉所有 EventSubscription，进全屏升级页，页上放 App Store 链接（要等 App 记录建好、有了 Apple ID 才能填）。另外请 11.8 在握手 426 时报出 StreamStatus 的升级状态。
  依据：crates/client-core/src/events.rs:285-292（其他状态码按 Dropped 处理）、32-48（StreamStatus 没有升级状态）；crates/server/src/http.rs:37、88-111；crates/proto/src/api.rs:4、68

- **账号冻结：解冻没有事件通知，App 要自己重查、重新订阅**（审查，P1，+0.25 人日）
  冻结后 REST 返回 AccountFrozen，事件流以 4003 关闭并停止（StreamStatus::AccountFrozen），会话保留不清。服务端解冻时只发一条 INFO 推送“账号已恢复”，不会给 App 发事件。所以：(1) 冻结页放“重新检查”按钮，App 回到前台、收到 INFO 推送时也自动调一次 me()；(2) 确认解冻后，重新订阅当前实例的事件流、同步收件箱、刷新实例列表；(3) 冻结期间缓存的数据可以只读查看，所有写操作禁用。四个视角都只写了“显示冻结页”。
  依据：crates/client-core/src/events.rs:197-206；crates/client-core/src/error.rs:16-18（登录状态保留）；crates/client-core/src/api.rs:478-479（刷新令牌时遇到冻结不清会话）；docs/i18n.md 第 2 节（账号冻结 / 恢复的推送）

- **离线时哪些页面有缓存**（审查，P1，+0.5 人日）
  本地缓存只有这几张表：instances、runs、cursors、events、inbox、pending_reads。计划、审批、key、路由、用量、保险箱、团队、agent 目录、IM 渠道、设备都不缓存，离线时这些页面只能显示“离线，暂无数据”。所有写操作在离线时禁用，只有标已读例外：它先在本地生效，联网后补发。cache_path 为空就完全不缓存。退出登录和注销都会清掉缓存，换账号后不能显示上一个账号的数据。12.16 要定一张“每页离线时怎么显示”的表，所有页面统一用同一个离线横幅。四个视角只写了“读 cached_*”。
  依据：crates/client-core/src/cache.rs:22-35；crates/client-core/src/ffi.rs:1125、1253、1329、1452、1462、1467（只有这几个 cached_* 和离线标已读）；docs/progress.md 已完成表 11.4 行（缓存按用户隔离，退出登录清空）

- **新增 12.13 应用框架与导航（侧边抽屉、实例切换、深链）**（界面，P1，+4 人日）
  建议编号 12.13，名称“应用框架与导航”。
  侧边抽屉（对应 Claude 的侧边栏），从上到下：
  - 搜索入口；
  - “新任务”按钮（选实例）；
  - 收件箱（未读数）、审批（待处理数）、进行中、计划（待确认数）、团队、产出物；
  - 实例列表：按最近活动排序，带状态点和最后一条消息预览，有等待时标红；
  - 底部头像，点开进设置。
  实例切换：对话页导航栏标题做成下拉菜单。
  iPad 和 macOS：用 NavigationSplitView，14.5 的 macOS App 复用。
  统一深链路由：推送的 tt、收件箱条目、通知操作、小组件都走它。
  全局状态：
  - 事件流连接中、重连倒计时 → 顶部状态条；
  - 登录失效 → 回登录页；
  - 账号被冻结 → 冻结说明页；
  - on_reset → 整页重新加载；
  - 启动时先显示缓存的实例和收件箱，再刷新。
  12.1 只是工程，12.3 只有实例列表，WBS 里没有导航骨架。
  依据：crates/client-core/src/events.rs:33-47 StreamStatus；crates/client-core/src/error.rs:18 AccountFrozen；ffi.rs:1125 cached_instances、:1462 cached_unread、:1346 approvals；crates/notify/src/apns.rs:133-142（tt 里的 id）；Claude iOS App 的侧边栏和标题区

### 12.17 首次启动、引导与空状态

- **新增 12.12 首次启动与引导、空状态**（界面，P1，+3 人日）
  建议编号 12.12，名称“首次启动与引导、空状态”。
  首次启动：先让用户同意隐私政策，同意前不收集信息、不注册推送；然后进欢迎页和登录。
  新用户引导（login 返回 new_user 时）：
  1. 起昵称（可以跳过）。
  2. 领养第一个 agent（目录里的精选）。
  3. 添加第一把模型 key。
  4. 给实例配 main 别名：选刚加的 key 和推荐模型。
  5. 发第一条任务，用预置的示例（比如“每天 8 点整理新闻”顺便演示计划）。
  6. 第一次下任务后再请求通知权限，说明“任务完成时通知你”。
  顺序要求：没有 key 就下任务，运行会直接进“等待 key”，所以引导里配 key 和路由必须在发消息之前。
  空状态：没有实例、没有 key、没有计划（提示可以直接对 agent 说“每天…”）、收件箱空、审批空、产出物空、离线且没有缓存。
  老用户换新手机：跳过引导，但检查有没有实例和 key。
  对应 Claude 的欢迎页和首次登录流程。WBS 里没有这个工作包，1.2 的原型里有“领养、配置 key、对话”。
  依据：ffi.rs:87 LoginResult.new_user、:1134 adopt、:1535 add_credential、:1197 set_model_routes；crates/orchestrator/src/waits.rs KeyProblem::Unavailable（没有能用的 key）；docs/wbs.md:107（1.2 原型）；Claude iOS App 的欢迎页与首次登录

### 12.18 产出物

- **新增 12.16 产出物浏览、预览与分享**（界面，P1，+3 人日）
  建议编号 12.16，名称“产出物浏览、预览与分享”。
  入口：抽屉的“产出物”（对应 Claude 的 Artifacts）、实例详情、运行详情、时间线里的产出物卡。
  列表：按实例或运行树分组，显示名字、版本（同名再发布是新版本）、类型、大小、时间。
  预览：Markdown 和纯文本用自己的渲染器，图片、PDF 和其他格式用 QuickLook。
  分享和存到文件：用系统分享面板。服务端下载时已在纯文本末尾加了 AI 生成标识，非文本只有 x-aigc 元数据，App 保存时别把标识弄丢。
  删除。
  接口缺口：
  - FFI 只有 run_artifacts 和 artifact_content，没有实例级列表、单个详情和删除；后端的 GET /v1/instances/{id}/artifacts、GET 和 DELETE /v1/artifacts/{id} 都有。
  - artifact_content 一次把整个文件读进内存，大文件要改成流式写文件。
  依据：ffi.rs:1289 run_artifacts、:1302 artifact_content（返回 Vec<u8>）；routes/mod.rs:141-147；docs/compliance.md §1（下载产出物的标识）；docs/progress.md:129（已拍板问题 6）

### 12.20 小组件与快捷指令

- **新增 12.19 小组件、快捷指令与分享扩展**（界面，P2，+3 人日）
  建议编号 12.19，名称“小组件、快捷指令与分享扩展”，属于增强功能。对应 Claude iOS 的主屏小组件，以及 Siri、快捷指令、分享菜单里的“问 Claude”。
  ThinkTin 的对应功能：
  - 小组件：显示未读数、待审批数、进行中的运行。
  - App Intents：“给某个 agent 下任务”、“全部停止”。
  - 分享扩展：把文字或链接发给某个实例，同样走 send_message 的密码拦截。
  前提：要用 App Group 共享 Keychain 里的会话（SessionStore）和缓存库路径（ClientConfig.cache_path）。
  依据：Claude 的中尺寸小组件：https://matthewcassinelli.com/claude-adds-a-medium-widget-because-i-asked-them-to/ ；分享菜单和快捷指令：https://beginnersinai.org/claude-app-guide/ ；ffi.rs:50 ClientConfig.cache_path、:44 SessionStore

### 12.21 搜索

- **新增 12.17 搜索**（界面，P2，+3 人日）
  建议编号 12.17，名称“搜索”。对应 Claude 侧边栏顶部的对话搜索。
  搜索范围：实例名、运行的 prompt 和摘要、收件箱、计划标题、保险箱条目名、产出物名。
  要做的：
  - 后端没有搜索接口，client-core 的缓存是按 JSON 存的，没有全文索引。要加 SQLite FTS5 和 search() FFI，约 1.5 人日 Rust。
  - 界面：结果分组、点开跳转，约 1.5 人日。
  限制：只能搜本机缓存过的内容，事件只保留 30 天。
  依据：routes/mod.rs 没有搜索路由；crates/client-core/src/cache.rs:25-35（表结构）；Claude iOS App 侧边栏的搜索

### 12.22 运行附件（待 1.1 拍板）

- **新增 运行附件（相机、相册、文件）**（界面，P2，+5 人日）
  建议编号：后端新增 5.5“运行附件上传”，App 在 12.5 里扩展。
  Claude 输入框的“+”可以拍照、选图、传文件。ThinkTin 后端创建运行时只收 prompt 文本（最长 32000 字），没有上传接口，产出物也只能由 agent 发布。
  要做的：
  - 后端：用户文件按用户加密存对象存储，运行启动时复制到实例的工作区（类似 8.5 把上游产出物复制到 handoff/ 的做法），agent 才看得到。约 3.5 人日 Rust。
  - App：输入框的附件菜单、相册选择（PhotosPicker）、文件选择、上传进度。约 1.5 人日。
  P1 的输入框先不放“+”。
  依据：crates/gateway/src/routes/runs.rs:16-27（CreateReq 只有 prompt）；docs/progress.md:36（8.5 的 HandoffCopier）；Claude iOS App 输入框的附件菜单

### 后端 后端小缺口（转 10.7 / 11.8 / 4.7）

- **后端小缺口：列表字段、等待原因码、推送子类型、审核测试号**（界面，P1，+2 人日）
  App 界面要用、后端还没有的五处（接入网关和编排服务）：
  1. 计划列表带每个计划的下次触发时间。现在列表里 triggers 是空的。
  2. run.state 事件和 Run 加结构化的等待原因码（invalid、no_balance、unavailable、rate_limited、overloaded，KeyProblem 里已经有）。App 才能决定显示“去换 key”还是“稍后自动重试”。
  3. 推送和收件箱条目带子类型（计划待确认、请填账号密码、账号冻结等）和保险箱请求 id。现在这些都是 info，推送里也没有请求 id。
  4. 跨实例的进行中运行列表（比如 GET /v1/runs?active=true），给抽屉的“进行中”和实时活动用。
  5. App Store 审核用的测试手机号：固定验证码，只在生产环境按配置打开。登录只能靠短信验证码，审核员收不到短信；现在的 dev_sms 只能本地开发用。
  依据：ffi.rs:380 Plan.triggers 的注释；crates/orchestrator/src/executor.rs:988（run.state 的内容）；crates/orchestrator/src/waits.rs KeyProblem；crates/notify/src/lib.rs:102 PushTarget；crates/orchestrator/src/vault.rs:153-163；routes/mod.rs 没有全局运行列表；docs/progress.md:74（没配服务商时只能开 api.dev_sms）

