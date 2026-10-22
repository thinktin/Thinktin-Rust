# android-app

目标：Android App（WBS 13.x）。Kotlin + Jetpack Compose（Material 3）原生开发，信息架构与视觉参考 Claude Android App（见 [安卓端设计规范](../android-design.md)）；经 UniFFI 调 `crates/client-core`（`cn.thinktin.core` Kotlin 绑定 + jniLibs，由 `tools/client-core/build-android.sh` 打出）。分支从 `backend-core`（`82b60b5`）切出，后端接口以那里为准。

PR：[#7](https://github.com/thinktin/Thinktin-Rust/pull/7)（草稿，叠在 #5 之上；#5 合并后差异只剩 Android 部分；13.2、13.3 做完后转为可评审）。

认领：Android 会话（session_01T2zubC6hDr9ZZR3ihhPP5b）在做，2026-10-22 01:15 起（北京时间）。13.x 全部由本分支负责；`backend-core`、`ios-app` 会话请不要重做 13.x。client-core（11.x）接口如有变动，请在 `docs/progress.md` 里记一句，本分支定期合 `backend-core`。

已完成：
- 分支与进度文件（本文件）。
- WBS 13.x 对齐：`docs/gen_wbs.py` 里补回 `backend-core` 手改进 `wbs.md` 的 1.6、9.11、9.12、11.6、13.12；13.1–13.12 的“同 12.x”改成明确交付物；新增 13.13 设置 / 多语言 / 开源许可、13.14 密码保险箱界面、13.15 IM 渠道设置、13.16 云端审批；13.9 改为电脑高危操作的签名审批（P3）；重新生成 `wbs.md`、`wbs.csv`。
- 安卓端设计规范 `docs/android-design.md`（含第 8 节数据契约：状态取值、事件流种类与载荷、调用约定、AI 标识规则、审批与生物识别、易漏交互）。
- **13.1 工程搭建**（`37088ca` 搭建，`b37536f`…修复）：`apps/android` Gradle 多模块工程（`:app`、`:core`、`:design`、`:data`，Kotlin 2.1 / AGP 8.7.3 / Compose BOM 2024.12）；`:core` 放 UniFFI 生成的 `client_core.kt`（经 `scripts/patch-bindings.py` 修 Kotlin 2 下错误类型 `message` 字段与 `Throwable.message` 的冲突），jniLibs 与许可证资源由 `scripts/sync-core.sh` 同步（不提交）；`:design` 主题（设计规范 2.1 色值、衬线标题）与通用组件（含 AI 生成标识）；`:data` 模型与映射、`ThinktinService` 接口、`CoreThinktinService`（异常统一转 `ServiceError`）、`MockThinktinService`（覆盖全部事件种类）、`SecureSessionStore`（Keystore 失效 / 文件损坏时清空重建）、`ClientFactory`；`:app` cn / global 风味、`AppContainer`（后台初始化、核心库不可用页）、抽屉与全部路由、冷启动与热启动（`onNewIntent`）深链、首页、各页骨架、中英文文案；150 个 JVM / Robolectric 测试（含经 JNA 真调本机 .so 的 `CoreSmokeTest`）、lint 0 错误；`.github/workflows/android.yml`（绑定一致性检查 + test + lint + assembleDebug）。四维评审 35 条确认发现已修复（CI 不打三个 ABI 的 .so 是有意的，见 README）。
- **11.7 / 11.8 接入与 TlsInit**（`fa2b5f3`…`c75737b`）：`ThinktinService` 不再有“暂不支持”，设备、注销、计划修改与触发器、团队与模板、key 修改、运行翻页 / 跨实例列表、产出物、收件箱单条操作、设备消息、举报、`cachedEventsBefore`、`waitCode`、触发器失效原因、`AgentInfo` / `Credential` 的协议字段都接上，Mock 同步；`:core` 的 `TlsInit`（JNI，`System.loadLibrary` + `initialize(context)`）、rustls-platform-verifier 支持包（版本由 Gradle 从 `Cargo.lock` 读并校验一致，仓库用 raw.githubusercontent.com）、R8 keep；`TlsState` + `ClientFactory.checkTls`（https 未初始化时清晰报错）；Accept-Language 按系统语言列表拼并随语言变化重发；client-core 日志接 Logcat；CI 加 release 打包与 dex 里 JNI 类的保留检查。
- **13.2 注册登录与设备管理**（`c75737b`）：两步登录（地区码、格式校验、6 位验证码自动提交、60 秒重发、按错误码映射：限频倒计时 / 冻结 / 网络重试 / 字段级提示）；登录后同步服务端语言；冻结页（保留登录态、重新检查、退出）；设备与账号页（设备列表、远程下线、下线其他设备可选全部停止、全部停止及结果、退出本机）；改昵称页；三步注销（说明 → 验证码 → 确认，DEK 一并销毁）；设置页骨架（账号 / 安全 / 危险区）。四维评审 19 条确认发现已修复。208 个 JVM / Robolectric 测试（debug；含 release 变体共 318），lint 0 错误，CI 绿。

进行中：
- 13.3 Agent 目录与领养 + 13.4 模型 key 配置（Workflow，启动时间见提交记录）。

下一步：
1. 13.3 → 13.4 做完后把 PR #7 转为可评审；合并 backend-core 的 11.8 收尾（审批字段、`get_approval`）后做 13.16 云端审批 → 13.5 对话 → 13.6 计划 → 13.8 推送与收件箱 → 13.13 设置 → 13.7 团队与流水线 → 13.11 / 13.12，再做 P2 的 13.10、13.14。
2. 每个工作包：Workflow（实现 → 多维评审 → 反方核实 → 修复 → 最终验证）→ 提交推送 → 更新本文件。

坑和决定：
- 云端会话没有 KVM，跑不了模拟器：界面测试用 Robolectric 跑 Compose UI 测试，业务逻辑用 JVM 单元测试；真机联调靠 CI 产出的 APK。
- Android SDK、NDK（r27c）、cargo-ndk 在会话里装在 `/opt/android-sdk`（容器回收后要重装，见 `apps/android/README.md`）。
- `tools/client-core/build-android.sh` 在本会话实跑通过：三个 ABI 的 `libclient_core.so`（共 20 MB）、Kotlin 绑定（`cn.thinktin.core`，与 `gen-bindings.sh` 的输出逐字节一致）、许可证资源（278 个 crate，2.4 MB）都产出；最后的 `gradle assembleRelease` 一步在本机因 Maven Central 对代理出口限流（429）失败，与脚本无关。另外该库工程用 `jvmToolchain(17)`，本机只有 JDK 21（GitHub 的 runner 预装 JDK 17，CI 不受影响）。
- 本机 Gradle 一律先走阿里云镜像（`~/.gradle/init.d/aliyun-mirror.gradle`，只影响这台机器），否则 Maven Central 会 429；同一时间只跑一个 Gradle 构建。
- client-core 还没导出、服务端已有的接口（设备列表与下线、注销、update_plan / add_trigger / delete_trigger、团队与模板、update_credential、产出物列表与删除、收件箱删除和标未读、runs 分页）：App 侧的 `ThinktinService` 先定义、Mock 实现、真核心适配层返回“暂不支持”，等 backend-core 的 11.7 落地后接上（iOS 会话同样处理）。
- 分支约定同 `CLAUDE.md`：小步提交马上推送，`autosave/android-app` 兜底。
- 用量限制后由预约的提醒叫醒本会话接着做（五小时窗口由三个会话共用，比预期更早触顶；Workflow 被中断后用 `resumeFromRunId` 恢复，已完成的 agent 直接回放）。
- 13.1 的有意偏差：测试框架用 JUnit 4（Robolectric、Compose 测试规则所需）；CI 的 debug APK 不含 .so（完整包走 `mobile.yml` 或本地 `sync-core.sh`）；Robolectric 的 android-all 经 Gradle 依赖离线取（Maven Central 直连会 429）；`sync-core.sh` 全量模式用不含 gradle 的 PATH 调 `build-android.sh` 跳过 AAR（本机没有 JDK 17）。
- 13.2 的有意偏差：改昵称、注销是独立页面而不是对话框（AlertDialog 里有输入框时 Robolectric 永远不会空闲，无法做界面测试；README 记为规则“对话框里不放输入框”）；一个 LoginViewModel 服务登录的两页并挂在 Activity 作用域（旋转不丢状态、登录后的回调不被取消）。用户协议 / 隐私政策链接、客服渠道待定（随 13.13）；短信自动填充、推送令牌随 13.8。
- 建议 client-core 把 `ClientError` / `PairingError` 里的 `message` 字段改名，这样 Kotlin 绑定不需要补丁（已告知 backend-core 会话）。
