# android-app

目标：Android App（WBS 13.x）。Kotlin + Jetpack Compose（Material 3）原生开发，信息架构与视觉参考 Claude Android App（见 [安卓端设计规范](../android-design.md)）；经 UniFFI 调 `crates/client-core`（`cn.thinktin.core` Kotlin 绑定 + jniLibs，由 `tools/client-core/build-android.sh` 打出）。分支从 `backend-core`（`82b60b5`）切出，后端接口以那里为准。

PR：[#7](https://github.com/thinktin/Thinktin-Rust/pull/7)（草稿，叠在 #5 之上；#5 合并后差异只剩 Android 部分；13.2、13.3 做完后转为可评审）。

认领：Android 会话（session_01T2zubC6hDr9ZZR3ihhPP5b）在做，2026-10-22 01:15 起（北京时间）。13.x 全部由本分支负责；`backend-core`、`ios-app` 会话请不要重做 13.x。client-core（11.x）接口如有变动，请在 `docs/progress.md` 里记一句，本分支定期合 `backend-core`。

已完成：
- 分支与进度文件（本文件）。
- WBS 13.x 对齐：`docs/gen_wbs.py` 里补回 `backend-core` 手改进 `wbs.md` 的 1.6、9.11、9.12、11.6、13.12；13.1–13.12 的“同 12.x”改成明确交付物；新增 13.13 设置 / 多语言 / 开源许可、13.14 密码保险箱界面、13.15 IM 渠道设置、13.16 云端审批；13.9 改为电脑高危操作的签名审批（P3）；重新生成 `wbs.md`、`wbs.csv`。
- 安卓端设计规范 `docs/android-design.md`（含第 8 节数据契约：状态取值、事件流种类与载荷、调用约定、AI 标识规则、审批与生物识别、易漏交互）。
- **13.1 工程搭建**（`37088ca` 搭建，`b37536f`…修复）：`apps/android` Gradle 多模块工程（`:app`、`:core`、`:design`、`:data`，Kotlin 2.1 / AGP 8.7.3 / Compose BOM 2024.12）；`:core` 放 UniFFI 生成的 `client_core.kt`（早期经 `scripts/patch-bindings.py` 修 Kotlin 2 下 `message` 字段与 `Throwable.message` 的冲突；client-core 改名 `detail` 后补丁已去掉），jniLibs 与许可证资源由 `scripts/sync-core.sh` 同步（不提交）；`:design` 主题（设计规范 2.1 色值、衬线标题）与通用组件（含 AI 生成标识）；`:data` 模型与映射、`ThinktinService` 接口、`CoreThinktinService`（异常统一转 `ServiceError`）、`MockThinktinService`（覆盖全部事件种类）、`SecureSessionStore`（Keystore 失效 / 文件损坏时清空重建）、`ClientFactory`；`:app` cn / global 风味、`AppContainer`（后台初始化、核心库不可用页）、抽屉与全部路由、冷启动与热启动（`onNewIntent`）深链、首页、各页骨架、中英文文案；150 个 JVM / Robolectric 测试（含经 JNA 真调本机 .so 的 `CoreSmokeTest`）、lint 0 错误；`.github/workflows/android.yml`（绑定一致性检查 + test + lint + assembleDebug）。四维评审 35 条确认发现已修复（CI 不打三个 ABI 的 .so 是有意的，见 README）。
- **11.7 / 11.8 接入与 TlsInit**（`fa2b5f3`…`c75737b`）：`ThinktinService` 不再有“暂不支持”，设备、注销、计划修改与触发器、团队与模板、key 修改、运行翻页 / 跨实例列表、产出物、收件箱单条操作、设备消息、举报、`cachedEventsBefore`、`waitCode`、触发器失效原因、`AgentInfo` / `Credential` 的协议字段都接上，Mock 同步；`:core` 的 `TlsInit`（JNI，`System.loadLibrary` + `initialize(context)`）、rustls-platform-verifier 支持包（版本由 Gradle 从 `Cargo.lock` 读并校验一致，仓库用 raw.githubusercontent.com）、R8 keep；`TlsState` + `ClientFactory.checkTls`（https 未初始化时清晰报错）；Accept-Language 按系统语言列表拼并随语言变化重发；client-core 日志接 Logcat；CI 加 release 打包与 dex 里 JNI 类的保留检查。
- **13.2 注册登录与设备管理**（`c75737b`）：两步登录（地区码、格式校验、6 位验证码自动提交、60 秒重发、按错误码映射：限频倒计时 / 冻结 / 网络重试 / 字段级提示）；登录后同步服务端语言；冻结页（保留登录态、重新检查、退出）；设备与账号页（设备列表、远程下线、下线其他设备可选全部停止、全部停止及结果、退出本机）；改昵称页；三步注销（说明 → 验证码 → 确认，DEK 一并销毁）；设置页骨架（账号 / 安全 / 危险区）。四维评审 19 条确认发现已修复。208 个 JVM / Robolectric 测试（debug；含 release 变体共 318），lint 0 错误，CI 绿。
- **13.3 Agent 目录与领养**（`f40a767`…）：目录（卡片、搜索、错误重试、空状态）、agent 详情（版本、上游链接、许可证、协议、接入方式）、领养底部表单（名字、接入方式、默认模型：键列表到达后选第一个可用 key 与厂商首个模型，没有可用 key 则领养后打开模型别名页）、实例设置（改名页、升级 / 回滚并提示下次唤醒生效、状态、最后活跃、模型别名入口、删除前列出受影响的流水线步骤与团队成员并二次确认）、抽屉显示 agent 名与状态点、首页空状态 + 精选目录。
- **13.4 模型 key 配置**（`47eeab6`…）：key 列表（厂商、标签、后 4 位、限额、状态、协议）、编辑 / 换 key / 停用 / 删除（删除前查出引用该 key 的实例别名，先从别名里移除再删）、两步添加（按协议分组的厂商 + 自定义端点；粘贴清洗、订阅类 key 前缀与套餐专用地址的本地校验与 `proto::vendors` 一致）、按实例的模型别名与降级链编辑（main 必填、未配置时警告）、用量看板（时间段 / 分组、总计卡片、按天柱状图、token 格式化）。四维评审 20 条确认发现已修复（领养默认模型、重复提交防抖、Mock 不再虚构级联删除、错误路径测试等）。306 个 debug 测试 + 112 个 release 变体，lint 0 错误。
- **破坏性改动适配**（`ca2eac3`）：去掉 `patch-bindings.py`，`ServiceError` 读 `detail`，`StreamStatus.UpgradeRequired` → 升级页，`Approval` 关联键（`run_id, attempt, request_id`）、`getApproval`，收件箱 `subtype` / `vault_request_id` 与新 kind；311 个 debug 测试。
- **13.16 云端审批**（`69f75db`）：`ApprovalCards`（从审批记录或事件流归并出卡片，含作废与 `approval_state` 优先规则）、`:design` 的 ApprovalCard、审批中心与详情（`getApproval` 对已处理 / 过期不报错）、`ApprovalGate`（BiometricPrompt：BIOMETRIC_STRONG 或 DEVICE_CREDENTIAL，无锁屏凭证不允许批准；拒绝不验证）；360 个 debug 测试。
- **与 backend-core 同步对齐（用户 2026-10-23 07:28 的要求）**：合并到 `67f9e7a`（11.9），绑定重生成（`c90ec76`），App 适配（`8115eba`…`92957c3`）：`setCredentialDailyLimit` 接上、13.4 编辑页每日限额可改；`KeyRules` 改用 `VendorInfo.subscriptionKeyPrefixes` / `planOnlyBases`，删掉复制自 `proto::vendors` 的表和 `KeyRulesSyncTest`（已告知 backend-core 可去掉 `PLAN_ONLY_BASES`）；`instance_limit` / `_limit` 错误码判断“已达上限”，未知错误码按 HTTP 状态显示；删实例的确认文案与 Mock 语义（自己的计划删除、他人流水线暂停需改步骤、别名一起删）；别名页允许保留原有的停用 key；Mock 的模板领养全成或全不成。437 个 debug 测试 + 163 个 release 变体，lint 0 错误。
- **13.5 对话与运行过程**（2026-10-25 由集成分支 `claude/determined-lovelace-vn0j5h` 上的会话收尾）：上一轮停在部分改动的快照上，核对下来代码已经齐了（按实例的运行时间线与翻页、全部事件种类的渲染与 AI 标识、密码拦截与保险箱表单、agent 的填写请求、停止、断线续传与 on_reset、离线缓存、运行树入口），对照 WBS 13.5 和设计规范第 4.3、8.2–8.4 节逐项看过视图模型和界面；修了运行页深链定位子运行时少算了横幅那一行。`:app` 257 个、`:design` 17 个、`:core` 8 个测试过（和 iOS 的 Swift 编译抢 CPU 时 Robolectric 跑挂过一次，单独再跑就过了）。
- **13.6 计划**（2026-10-25，集成分支 `claude/determined-lovelace-vn0j5h`）：`:data` 的 `schedule/`（cron / RRULE 的本地预测和触发器草稿，照 iOS 的 `ScheduleForecast` / `TriggerDraft` 移植到 java.time；期望值由 Python zoneinfo 独立算出），`:app` 的 `ui/plans/`：列表（等确认置顶、查看并确认 / 拒绝，在跑 / 已暂停，开关暂停恢复）、详情（触发规则描述与下一次、策略、补跑、步骤只读、运行历史；确认带版本号，冲突换新版本、步骤在已删除实例上的 409 按实例列表认出）、新建 / 编辑（实例、标题、目标、触发规则面板：写法、TimeInput、DatePicker、星期 / 日期、cron / RRULE、时区、接下来 5 次预览；策略按小时；只发改了的字段，触发器先删后加，失败后只做剩下的），路由 `plans`、`plan/{id}`、`plans/new?instanceId=`、`plan/{id}/edit`，深链 `thinktin://plan/{id}` 不再是骨架页。说明见 README“计划（13.6）”。`ScheduleTest` 14 个、`PlansViewModelTest` 18 个、`PlansUiTest` 3 个；全量 `test lint assembleDebug :app:assembleCnRelease` 通过（`:app` 277 个、`:data` 338 个含 release 变体、`:design` 17 个、`:core` 16 个，lint 0 错误）。
- **13.8 推送与收件箱**（2026-10-25，集成分支 `claude/determined-lovelace-vn0j5h`）：收件箱页（`ui/inbox/`：先缓存再同步、最新一页换开头、滚到底翻页、按天分组、未读加粗 / 圆点、种类图标、AI 标识、每行的标已读 / 未读与删除、全部已读、没有更具体页面的和推送进来的在面板里打开）；`push/`：`PushMessage`（`tt_*` 解析，和 iOS、收件箱同一套深链规则）、`PushCoordinator`（令牌登录着才报、同一个只报一次、点开过的通知等登录着标已读、断网重试）、`NotificationChannels`（`tt_approval` / `tt_results`，和服务端默认一致）、`PushNotifier`（前台自己发通知）、通知权限登录后问一次、`MainActivity` 把带 `tt_kind` 的 Intent 换成深链、退出登录清通知；`PushProvider` + 各渠道的 `FlavorPush`（现在是空实现，见“坑和决定”）。测试 `PushTest`、`InboxViewModelTest`、`InboxUiTest`，`DeepLinkTest` / `AppUiTest` 改成真收件箱。
- **13.13 设置、多语言与开源许可**（2026-10-26，集成分支）：设置页补上语言（跟随系统语言 / 中文 / English，先存再 `AppCompatDelegate.setApplicationLocales`，`MainActivity` 改成 `AppCompatActivity`，清单加 `AppLocalesMetadataHolderService`，系统设置里改过“应用语言”的以系统为准）、通知（是否允许，去系统设置）、关于（隐私政策、用户协议、开源许可）；开源许可页（App 自己的库＋客户端核心清单，移植 iOS 的 `LicenseInventory`：分组、搜索、组件详情、原文页）。测试 `LicensesTest`、`SettingsUiTest`。
- **13.7 团队与流水线**（2026-10-26，集成分支）：团队列表与模板（一键领养、删除）、团队详情（成员、配模型、存为模板、删除、用团队建流水线）、新建 / 编辑团队（成员 1–12、一个负责人）；计划编辑页里的流水线步骤编辑（`Pipeline`：键名、依赖、环、提示词长度和服务端一致，改名 / 删除时依赖跟着变；从团队预填，负责人汇总）。运行树的整树 / 单个停止、产出物在 13.5 里已有。测试 `TeamsTest`、`TeamsUiTest`。

进行中：
- 无。按用户要求（“让各会话把代码都同步对齐先，后面我再安排工作”）已停下等安排；03:20 UTC 的自动恢复提醒已停用。

下一步（等用户安排后）：
1. ~~恢复 13.5 对话与运行过程~~（2026-10-25 已收尾，见上）：`Workflow({scriptPath: "<会话目录>/workflows/scripts/android-adapt-13-16-13-5-wf_2830c5a3-21b.js", resumeFromRunId: "wf_2830c5a3-21b"})`（适配与 13.16 已缓存；13.5 的部分改动在 `ba78a8d`，恢复前把脚本里任务 C 的“注意”段改成描述当前工作区状态），之后四维评审 → 反方核实 → 修复 → 最终验证。
2. ~~13.6 计划~~、~~13.8 推送与收件箱~~（已完成，SDK 等人定）→ ~~13.13 设置~~ → ~~13.7 团队与流水线~~ → 13.11 / 13.12，再做 P2 的 13.10、13.14。
3. 每个工作包：Workflow → 提交推送 → 更新本文件。

坑和决定：
- **推送 SDK 要人定（13.8）**：试接过极光 6.2.1（jcore 钉 5.5.7，极光的 pom 里 jcore 是开放区间）和 firebase-messaging 24.1.0（不用 google-services 插件，key 走构建属性），代码能编过，但没有提交：(1) 极光是闭源 SDK，FCM 带 Play 服务的 SDK 许可，和 README“只用 Apache / MIT / BSD 类许可证”的约定冲突，要法务（16.5）点头并登记；(2) 极光清单带着定位、读手机状态、`QUERY_ALL_PACKAGES`、存储等权限，要在 `src/cn` 清单里去掉（lint 仍报 QueryAllPackagesPermission，要 `tools:ignore`），隐私政策要写明第三方 SDK；(3) 极光的混淆字节码让 Robolectric 抛 VerifyError，cnDebug 的界面测试全挂，要么单元测试改跑 globalDebug、要么极光只进 release；(4) 要极光 AppKey、Firebase 项目。定了之后只改各渠道的 `FlavorPush`、清单和依赖（`PushProvider` 的接口、登录后启动、令牌上报都在）。
- 云端会话没有 KVM，跑不了模拟器：界面测试用 Robolectric 跑 Compose UI 测试，业务逻辑用 JVM 单元测试；真机联调靠 CI 产出的 APK。
- Android SDK、NDK（r27c）、cargo-ndk 在会话里装在 `/opt/android-sdk`（容器回收后要重装，见 `apps/android/README.md`）。
- `tools/client-core/build-android.sh` 在本会话实跑通过：三个 ABI 的 `libclient_core.so`（共 20 MB）、Kotlin 绑定（`cn.thinktin.core`，与 `gen-bindings.sh` 的输出逐字节一致）、许可证资源（278 个 crate，2.4 MB）都产出；最后的 `gradle assembleRelease` 一步在本机因 Maven Central 对代理出口限流（429）失败，与脚本无关。另外该库工程用 `jvmToolchain(17)`，本机只有 JDK 21（GitHub 的 runner 预装 JDK 17，CI 不受影响）。
- 本机 Gradle 一律先走阿里云镜像（`~/.gradle/init.d/aliyun-mirror.gradle`，只影响这台机器），否则 Maven Central 会 429；同一时间只跑一个 Gradle 构建。
- client-core 还没导出、服务端已有的接口（设备列表与下线、注销、update_plan / add_trigger / delete_trigger、团队与模板、update_credential、产出物列表与删除、收件箱删除和标未读、runs 分页）：App 侧的 `ThinktinService` 先定义、Mock 实现、真核心适配层返回“暂不支持”，等 backend-core 的 11.7 落地后接上（iOS 会话同样处理）。
- 分支约定同 `CLAUDE.md`：小步提交马上推送，`autosave/android-app` 兜底。
- 用量限制后由预约的提醒叫醒本会话接着做（五小时窗口由三个会话共用，比预期更早触顶；Workflow 被中断后用 `resumeFromRunId` 恢复，已完成的 agent 直接回放）。
- 13.1 的有意偏差：测试框架用 JUnit 4（Robolectric、Compose 测试规则所需）；CI 的 debug APK 不含 .so（完整包走 `mobile.yml` 或本地 `sync-core.sh`）；Robolectric 的 android-all 经 Gradle 依赖离线取（Maven Central 直连会 429）；`sync-core.sh` 全量模式用不含 gradle 的 PATH 调 `build-android.sh` 跳过 AAR（本机没有 JDK 17）。
- 13.2 的有意偏差：改昵称、注销是独立页面而不是对话框（AlertDialog 里有输入框时 Robolectric 永远不会空闲，无法做界面测试；README 记为规则“对话框里不放输入框”）；一个 LoginViewModel 服务登录的两页并挂在 Activity 作用域（旋转不丢状态、登录后的回调不被取消）。用户协议 / 隐私政策链接、客服渠道待定（随 13.13）；短信自动填充、推送令牌随 13.8。
- 13.3 / 13.4 发现的后端缺口（已告知 backend-core 会话）：`update_credential` 改不了每日 token 限额（编辑页只读，提示“删了重加”）；`delete_credential` 把已删除实例的 `model_routes` 也算在内，App 看不到也清不掉，这种 key 永远 409；`set_model_routes` 整表替换时引用了已停用 key 的实例保存不了；`VendorInfo` 没有订阅类 key 前缀和地区字段（App 侧 `KeyRules` 复制了 `proto::vendors` 的表，有测试保持同步）；删除实例只标记删除、它自己的计划保留（确认框按“将停止运行”列出）；实例数上限没有专门错误码。
- Robolectric 的点击到不了覆盖层（抽屉、领养底部面板）里的控件：相关界面测试用无障碍点击动作，真机行为待验证（README Known issues）。
- 建议 client-core 把 `ClientError` / `PairingError` 里的 `message` 字段改名，这样 Kotlin 绑定不需要补丁（已告知 backend-core 会话）。
