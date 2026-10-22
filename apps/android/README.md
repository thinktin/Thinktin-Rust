# Android 客户端

ThinkTin 的 Android App（WBS 13.x）：Kotlin 2.1 + Jetpack Compose（Material 3），单 Activity + Navigation Compose，
经 UniFFI 调用 `crates/client-core`。规范见 [安卓端设计规范](../../docs/android-design.md)，
架构见 [架构方案 v3 第 8 节](../../docs/architecture-v3.md)，进度见 [docs/progress/android-app.md](../../docs/progress/android-app.md)。

## 目录与模块

```
apps/android/
├─ settings.gradle.kts、build.gradle.kts、gradle.properties
├─ gradle/libs.versions.toml      版本目录（AGP 8.7.3、Kotlin 2.1.0、Compose BOM 2024.12.01……）
├─ gradle/robolectric.gradle.kts  Robolectric 用的 android-all 经 Gradle 解析、离线使用
├─ scripts/sync-core.sh           同步 client-core 的绑定、.so、许可证资源
├─ core/    :core   client-core 的 UniFFI Kotlin 绑定（cn.thinktin.core）+ 手写的 TlsInit + jniLibs，见 core/README.md
├─ data/    :data   App 模型、ThinktinService 接口、CoreThinktinService（真实）、MockThinktinService（演示）、
│                   SecureSessionStore、ClientFactory、TlsState
├─ design/  :design ThinktinTheme（色板、字体、形状）与通用组件（顶栏、主按钮、状态点、输入框、消息、横幅、审批卡片……）
└─ app/     :app    Application、MainActivity、抽屉 + 导航、各页面与 ViewModel
```

依赖方向：`:app → :data → :core`、`:app → :design`。`:design` 只有主题和组件，不依赖数据层
（状态点用 `:design` 自己的 `StatusTone`，`InstanceState` / `RunState` → `StatusTone` 的映射在 `:app` 的 `ui/common`）；
`:data` 对外只暴露 `ThinktinService` 和 App 模型，`:core`（UniFFI 绑定）是它的 `implementation` 依赖。

## 环境准备

本仓库的云端会话是这样装的（容器回收后要重装）：

```bash
# JDK 17 以上（会话里是 JDK 21）；Android SDK 装在 /opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;27.2.12479018"
# 交叉编译 client-core（只有要打带 .so 的完整包时才需要）
cargo install cargo-ndk
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.2.12479018
```

本地开发在 `apps/android/local.properties` 里写 `sdk.dir=...` 也行（已在 .gitignore）。

## 同步核心（client-core）

```bash
apps/android/scripts/sync-core.sh --from target/android  # 本机推荐：已经有 build-android.sh 的输出时只同步
apps/android/scripts/sync-core.sh                        # 交叉编译三个 ABI（NDK + cargo-ndk），再同步绑定、.so、许可证
apps/android/scripts/sync-core.sh --bindings-only        # 只重新生成 Kotlin 绑定（只需要 cargo）
apps/android/scripts/sync-core.sh --check                # 只检查提交的绑定和 Rust 一致（CI 跑这个）
```

不带参数的全量模式调 `tools/client-core/build-android.sh`。那个脚本最后在 PATH 里有 `gradle` 时会再起一个 Gradle 构建打 AAR，
它的库工程写死了 `jvmToolchain(17)`，只有 JDK 21 的机器（比如云端会话）上必然失败，而且违反“同一时间只跑一个 Gradle 构建”。
本工程直接用 `:core` 模块，用不上那个 AAR，所以 `sync-core.sh` 调它时在 PATH 最前面放一个假的 `gradle`（打印“跳过”后退出），
用完删掉（见“已知问题”）。

`client_core.kt` 提交进 git；`core/src/main/jniLibs/`（约 20 MB）和 `core/src/main/assets/thinktin-licenses/`
是生成物，不提交。生成结果原样提交、不打补丁（client-core 的错误字段叫 `detail`，避开了 Kotlin 异常自带的 `message`），
`--check` 直接逐字节比对。`core/src/main/kotlin/cn/thinktin/core/TlsInit.kt` 是手写的（见下一节），脚本不碰它。

client-core 的 App 接口已全部接进 `ThinktinService`，`CoreThinktinService` 里没有再抛 `ServiceError.Unsupported` 的方法
（这个类型留给以后新加、还没接的接口）：

- 11.7：资料、设备列表与吊销、注销账号、实例详情、运行翻页、产出物、改计划与触发器、收件箱单条 / 标未读 / 删除、
  团队与模板、改 key / 换 key、手机和电脑之间的消息、`cachedEventsBefore`（对话页先显示最后一屏）；5.5 的举报。
- 11.8：`ClientConfig.acceptLanguage` + `setAcceptLanguage`（见下一节“启动顺序”）、`initLogging`（`:data` 的 `CoreLogging`）、
  `upgradeRequired()`、跨实例的 `listRuns(RunFilter, before, limit)`、`Run.waitCode`（`WaitCode` 枚举，界面按码出文案）、
  `Plan.nextFireAtMs` / `invalidTriggers`、`Trigger.disabledReason`、`AgentInfo` 的介绍 / 上游 / 许可说明 / 协议、
  `Credential.protocols`。吊销本机设备时 client-core 自己清登录态，`authState` 跟着变成未登录（回登录页）。
- 11.8 收尾 / 10.7（合并 backend-core `ff0d55c`）：错误字段 `message` → `detail`（不再给绑定打补丁）；
  `StreamStatus.UpgradeRequired`（握手 426，事件流以它结束、不再重连）→ `StreamState.UpgradeRequired`，
  和请求返回的 `UpgradeRequired` 一起置 `ThinktinService.upgradeState`，AppRoot 换成升级页；
  `Approval.requestId` / `attempt` / `decidedOption` / `decidedAtMs` 与 `getApproval`（什么状态都能查），
  审批按 `Approval.key`（`runId`、`attempt`、`requestId`）认；`InboxItem.subtype` / `vaultRequestId`，
  `InboxKind` 加 `VaultRequest` / `PlanConfirm`（不认识的按 `Info`，所以收件箱种类没有 Unknown）。

只给 iOS 的实时活动（`registerLiveActivity`、`endLiveActivity`、`setLiveActivityStartToken`）不接。
Rust 接口再变时：`sync-core.sh --bindings-only` → 在 `:data` 的模型、`Mappers.kt`（两个方向）、
`ThinktinService`、`CoreThinktinService`、`MockThinktinService` 里跟上 → 补映射和服务的单测。

## 启动顺序（日志、TLS、语言）

`ThinktinApp.onCreate`：

1. `initializeLogging()`：`CoreLogging.install(verbose = BuildConfig.DEBUG)` 把 client-core 的日志（已抹掉敏感内容）
   接到 `android.util.Log`（tag `ThinktinCore`），debug 包到 Debug 级别、release 只要 Warn 以上。会加载 .so；失败只记一条警告。
2. `initializeTls()`：见下一节。
3. `createContainer()`：`AppContainer` 很轻，真实服务第一次用到时在后台创建。

Accept-Language：`:data` 的 `AcceptLanguage.tags(appLanguage)` 用 `LocaleList` 拼语言列表（App 设置里选的语言在前），
`AcceptLanguage.header` 交给 client-core 的 `accept_language_header` 拼成请求头（q 值、上限和 iOS 共用 Rust 的实现）。
建客户端时放进 `ClientConfig.acceptLanguage`；之后 `AppContainer` 跟着设置里的语言和系统语言
（`ThinktinApp.onConfigurationChanged` → `onSystemLocalesChanged`）调 `ThinktinService.setAcceptLanguage`。

## TLS 初始化（Android 上的 HTTPS）

client-core 的接口请求和事件流用 `rustls-platform-verifier` 做系统证书校验（和系统设置里信任的证书一致），
它在 Android 上要经 JNI 调系统的 `X509TrustManager`，所以**建 `ThinktinClient` 之前必须先初始化**
（`crates/client-core/src/tls.rs`）：

- `:core` 的 `TlsInit`（手写）：`System.loadLibrary("client_core")` + `external fun initialize(context)`，
  对应 Rust 导出的 `Java_cn_thinktin_core_TlsInit_initialize`。`loadLibrary` 不能省：JNA 的 dlopen 不会注册 JNI 函数。
- `ThinktinApp.onCreate` 先 `initializeTls()`（`:data` 的 `SystemTls`，失败不崩溃，原因记在 `TlsState.failure`），
  再建 `AppContainer`；`ClientFactory.createService(context, baseUrl, tls)` 在 base_url 是 https 而 `tls.ready` 为假时
  抛 `ServiceError.TlsUnavailable`（界面显示“无法加载核心库”页，原因是本地文案“无法建立安全连接”，底层异常只进日志），不让 Rust 那边报一个看不懂的内部错误。
  http 的本地联调地址不需要初始化。
- Java 支持包 `org.rustls:rustls-platform-verifier`（AAR）由 `:core` 依赖：版本**必须**和 `Cargo.lock` 里
  `rustls-platform-verifier-android` 的一致，`core/build.gradle.kts` 用 `ValueSource` 从 `../../Cargo.lock` 读
  （`strictly`，Rust 升级后 Gradle 自动跟上），`libs.versions.toml` 里的坐标不写版本。仓库在 `settings.gradle.kts`：
  `https://raw.githubusercontent.com/rustls/rustls-platform-verifier/maven-archive/android-release-support/maven/`
  （只放 `org.rustls` 组；README 里 `github.com/…/raw/…` 的写法多一次重定向，云端会话的代理下是 403）。
  `RustlsVerifierVersionTest` 用独立的解析器读 Cargo.lock，和 Gradle 声明的、实际解析到的版本比对，并确认类在类路径上。
- R8：`:core` 的 `consumer-rules.pro` 保留 `org.rustls.platformverifier.**`（只经 JNI 调用，R8 看不见）和 `cn.thinktin.core.**`。
  规则漏了 R8 只会悄悄删类、构建照样成功，所以由 CI 的“Release dex keeps JNI classes”一步检查：解开 release 包，
  在 `classes*.dex` 里找 `CertificateVerifier` 和 `TlsInit`。
- 测试：本机 `target/debug/libclient_core.so` 是 Linux 版，没有这个 JNI 函数。JVM / Robolectric 测试**不调**
  `TlsInit.initialize`：`DemoTestApp` 覆盖 `initializeTls()` 返回 `FixedTlsState`，`:data` 的 `TlsStateTest`
  用假的初始化函数测 `SystemTls` 和 `ClientFactory.checkTls`；`:core` 的 `TlsInitSignatureTest` 用反射钉住 JNI 的
  类名、方法名和静态 native 签名（不加载类）。真正的 JNI 初始化只能在真机 / 模拟器上验证。

## 构建与测试

```bash
cd apps/android
export ANDROID_HOME=/opt/android-sdk
# CoreSmokeTest 经 JNA 真调本机的 libclient_core.so（cargo build -p client-core 的输出）；不设就跳过，
# 再设 THINKTIN_REQUIRE_CORE=1（CI 这么设）则不设库目录时直接失败
export THINKTIN_CORE_LIB_DIR=$PWD/../../target/debug
./gradlew test lint assembleDebug :app:assembleCnRelease   # 全部单元测试、lint、debug 包、release 包（R8，和 CI 一样）
./gradlew :data:testDebugUnitTest        # 只跑某个模块
./gradlew :app:assembleCnDebug           # 只打 cn 渠道的 debug 包
```

- 产物：`app/build/outputs/apk/{cn,global}/debug/app-*-debug.apk`。
- 渠道（`dist` 维度）：`cn`（极光推送）、`global`（FCM），推送 SDK 在 13.8 接；`BuildConfig.DIST` 区分。
- 后端地址：`BuildConfig.BASE_URL`，默认 `https://api.thinktin.cn`，用 `-PthinktinBaseUrl=...` 覆盖。
- 云端会话没有模拟器：界面测试是 Robolectric 跑的 Compose 测试（`app`、`design` 的 `src/test`），
  只跑 debug（`app` 只跑 cnDebug）。Robolectric 要的 android-all jar 由 `gradle/robolectric.gradle.kts`
  经 Gradle 下载并离线使用，不让它自己连 Maven Central（容易被限流）。
- 同一时间只跑一个 Gradle 构建（内存和 Maven Central 限流）。

## 演示模式

debug 包默认开着演示模式（`BuildConfig.DEMO_DEFAULT`）：用 `MockThinktinService` 的确定性假数据（3 个目录 agent、
2 个实例、覆盖全部事件类型的运行、全部 7 种收件箱条目、计划、key、保险箱、团队与模板、登录设备、设备消息、举报……），
不联网；启动时只有日志接入（`CoreLogging.install`，经 JNA 调 `initLogging`）和 TLS 初始化（`TlsInit`）会加载
`libclient_core.so`（见“启动顺序”），没有 .so 时两者都只记下失败、不崩溃。
设置页里可以关掉，关掉后走 `CoreThinktinService` → client-core → 服务端，未登录时显示登录流；登录页和“核心库不可用”页
也有“使用演示模式”。

release 包没有演示模式（第 7 节）：上面三个入口都不显示，`AppSettingsRepository(demoAllowed = false)` 也忽略已经存下的
`demo_mode`（比如从 debug 包覆盖安装），release 用户不会困在假数据里。

真实服务（`ClientFactory.createService`：检查 TLS 初始化、加载 .so、打开 SQLite、读 Keystore）在 `AppContainer` 里第一次用到时才在
IO 线程上创建，创建中显示加载，任何异常（`UnsatisfiedLinkError`、契约版本不一致的 `ExceptionInInitializerError`、
Keystore 失效……）都显示“无法加载核心库”页（原因 + 重试），不崩溃。`SecureSessionStore` 遇到 Keystore 失效或偏好文件损坏时
删掉重建，还不行就退回内存存储，读不出的令牌按未登录处理。

## 登录与账号（13.2）

- **登录流**（`ui/login`，未登录时替换整个主区）：手机号页（国家 / 地区码，默认 +86，常用 8 个；`PhoneRegion` 按位数和开头粗查格式，
  E.164 交给服务端）→ 验证码页（6 位、自动聚焦、满 6 位自动提交、60 秒倒计时重发、“更换手机号”返回）→
  `login(phone, code, null, null)`（推送令牌在 13.8 接）。两页共用一个 `LoginViewModel`，挂在 Activity 上（旋转不丢号码和倒计时，
  登录成功后界面切走也不会取消没跑完的回调），每次新进登录流 `reset()`。
  错误映射：`rate_limited` 显示剩余秒数（发码时倒计时，按号码算，换号码可以马上发）；`account_frozen` 进 `login/frozen`
  （还没有登录态，只能返回）；网络错误、服务暂时不可用用 Snackbar 带“重试”；`invalid` 按当前步骤做字段级提示
  （服务端对号码不对和验证码错都报 `invalid`）。
- 登录成功后服务的 `authState` 变成已登录，`AppRoot` 换成主界面，暂存的深链在那里处理（`DeepLinkInbox`）；
  `AppContainer.syncServerLocale` 在容器的作用域里比较 `User.locale` 和 App 当前语言（`AppLanguage.serverLocale`，
  跟随系统时中文以外一律 en），不一致就 `setLocale`。已登录时，服务就绪（冷启动）、App 语言切换、系统语言变化也会
  `me()` 后再同步一次（`AppContainer.followLanguage`，失败只记日志）。
- **冻结页**：已登录时（接口或事件流返回 `AccountFrozen`）是 `FrozenAccountScreen`：登录态保留、提示联系客服、“重新检查”
  （`me()` 成功时 `CoreThinktinService` 回到已登录）、退出登录。登录时被拒不进这个页：`CoreThinktinService.login` 报冻结时
  保持未登录（没有会话），由登录流自己的冻结说明处理。
- **设备与账号**（路由 `devices?action=…`，入口在设置页“安全”区）：资料（手机号、昵称）、设备列表（平台图标、名字、本机标记、
  电脑的在线状态、最后活跃）、远程下线（确认框；本机没有这个按钮）、下线其他设备（可勾选“同时停止全部 agent”，二次确认，
  结果 Snackbar）、全部停止（二次确认，结果框里是取消的运行 / 吊销的授权 / 暂停的计划数）、退出登录（只下线本设备）。
  `action` 是设置页直接要打开的对话框（`sign_out_others`、`stop_all`）。
- **改昵称**（`account/name`）、**注销账号**（`account/delete`）是单独的页面：注销三步（说明后果，含保险箱 DEK 一并销毁 →
  `sendSelfCode(DeleteAccount)` 的验证码 → 最后确认），验证码错回第二步；成功后服务变成未登录，回登录页。
  它们不做成对话框，是因为对话框里的输入框在 Robolectric 下一直不空闲（`AppNotIdleException`），测不了（真机没问题）。
- 演示模式下没有退出登录和注销（关掉演示模式就是“退出”）；设备列表、下线、全部停止照常演示。
- 设置页（13.2 的骨架升级）：账号区（手机号、昵称入口）、安全区（设备与账号、下线其他设备、全部停止）、外观、演示模式、
  危险区（退出登录、注销账号）；语言、通知、关于等在 13.13。

## Agent 目录与领养（13.3）

- **目录**（`catalog`，入口：抽屉“领养 agent”、首页空状态的主按钮和精选卡片、首页溢出菜单）：卡片（名字、一句话介绍、许可证、
  接入方式、模型协议标签），搜索框按名字 / 介绍 / id / 许可证 / 接入方式 / 协议过滤（空白分隔的每个词都要命中）；
  拉取失败显示错误和“重试”，目录为空、没有匹配各有提示。介绍是上游写的，不标 AI 生成（第 8.4 节）。
- **详情**（`agent/{agentId}`，目录接口没有单个查询，从 `agents()` 里找；找不到显示“已下架”）：介绍、最新版本与版本列表、
  接入方式（默认的加标记）、模型协议与 `activeProtocol`、许可证与 `licenseNote`、会访问的网站、上游链接（只认 https，
  `ACTION_VIEW` 打开，没有浏览器时 Snackbar）。底部“领养”。
- **领养**：盖在页面上的底部面板（遮罩、返回键、“取消”收起；不是 `ModalBottomSheet`，弹出窗口里的输入框在 Robolectric 下
  测不了）。名字默认“<agent 名> 的实例”（截到 64 个码点），接入方式多于一种时用 FilterChip 选（默认 `defaultHarness`，
  只有一种时不传，让服务端用默认）。本地先校验 1–64 字（和服务端一致）。失败映射：`conflict` 和说名字不对的 `invalid`
  提示在名字下；限频（剩余秒数）、数量上限（code 含 `limit`）、`not_found`（已下架）、其余 `invalid`（版本下架、接入方式停用）
  是表单级。成功后刷新抽屉，跳到 `chat/{instanceId}`，返回栈弹到首页（返回回首页，首页显示时重新取实例列表）。
- **实例设置**（`instance/{instanceId}`，入口：对话页顶栏的“实例设置”、首页溢出菜单、抽屉实例行的长按或“更多”、深链）：
  先用缓存渲染再联网；名字（`instance/{id}/name` 单独页面）、agent 与接入方式（点进详情）、状态点 + 文字、最后活跃；
  版本：当前版本、不是最新时“升级到最新”（`setInstanceVersion(null)`）、`versions` 里的其他版本可回滚 / 切换，确认框提示
  “下次唤醒生效，工作区保留”；目录拉不到时只是没有版本选项。模型别名入口指向 `instance/{id}/routes`，旁边是 key 列表入口（13.4）。
- **删除实例**（第 8.6 节）：先 `plans()` + `teams()` 算出影响（`DeleteImpact`：它自己的计划、别的计划里引用它的流水线步骤数、
  它是成员的团队），确认框列出计划和团队名（agent 建的计划标题标 AI 生成），“继续”后二次确认再 `deleteInstance`；
  查不到影响范围就不让删（Snackbar 说明原因）；已经被删（404）当作成功。成功后刷新抽屉、回首页（首页重新创建）。
- **首页**：没有实例时显示衬线问候 + “领养一个 agent” + 目录前 3 个精选卡片；抽屉实例行显示名字、agent 显示名（目录拉不到时
  显示 id）、状态点，长按或右侧“更多”进实例设置。

## 模型 key 与用量（13.4）

- **key 列表**（`keys`，入口：设置页“模型”区、实例设置里模型别名旁、模型别名页顶栏）：每行厂商标记（首字母，不用各家的图标）、
  标签（没有时用厂商名）、厂商与后 4 位、每日限额（`TokenFormat`，第 5 节的千分位 / 万 / k）、状态（正常 / 已停用）、协议标签。
  点行进编辑；“更多”菜单：编辑、换 key、停用 / 启用（直接 `updateCredential`）、删除。顶栏进用量页。
- **删除**：先 `instances()` + 每个实例的 `modelRoutes()` 找出在用这把 key 的别名（查不到就不让删）。服务端在有别名（主 key 或
  降级链）用着时拒绝删除（409），所以确认框列出“实例：别名（主 key / 降级）”，确认后先按 `KeyRules.detachCredential` 改这些实例的
  别名（降级链里的去掉；它是主 key 时第一个备用顶上；没有备用的别名删掉，那个实例会等 key），再 `deleteCredential`；404 当作成功。
  整表替换时服务端会重新检查每把 key，那个实例的别名里还有停用的 key 时会被拒（invalid）：提示先启用或去别名页换掉。
- **添加**（`keys/new`，单独页面，两步）：第一步 `vendors()` 按协议分组（协议多的组在前），最后是“自定义接口”；第二步 key
  （密码输入、可切换显示、关自动更正；一次进来 8 个字符以上当作粘贴：去掉首尾空白、引号、`Bearer `、`NAME=`，并马上检查订阅前缀）、
  标签（默认厂商名；自定义接口默认地址的主机名）、自定义接口按勾选的协议填 `anthropicBase` / `openaiBase` / `responsesBase`、
  可选每日 token 限额（正整数，可带千分位）。本地校验（`KeyRules`，和服务端一致）：key 8–4096 个可打印 ASCII、各厂商的订阅类前缀
  （百炼 `sk-sp-`、MiniMax `sk-cp-`、腾讯 `sk-tp-`、Claude 订阅 `sk-ant-oat` / `sk-ant-ort`）；地址只收 `https://`、不带用户名密码 /
  查询串 / 片段、主机是公网（不是 localhost、`.local` 等内网后缀、单段主机名、私网 / 回环 / 链路本地 / 运营商 NAT / 文档 / 组播 IP，
  IPv6 只收 2000::/3 且排除 Teredo、6to4、文档段；`0x7f.1`、`2130706433` 这类写法不收）、不是套餐专用地址。服务端返回的 invalid
  按 detail 里的字段名挂到对应字段下（detail 只用来定位，显示的是本地文案）。成功回列表。
- **编辑**（`keys/{id}/edit`）：标签、启用开关；**换 key**（`keys/{id}/secret`）：密码输入，同样的本地检查，模型别名不用改。
  每日限额 `updateCredential` 改不了，编辑页只显示并说明“删掉重新添加”。
- **模型别名**（`instance/{id}/routes`）：每个别名一张卡片：别名（`^[a-z0-9][a-z0-9._-]{0,63}$`）、key（下拉，只列没停用且支持
  agent `activeProtocol` 的；已选的不能用了照样显示并报错）、上游模型（手填，下面是这家厂商 `models` 的推荐，选 key 时自动填第一个）、
  降级链（最多 3 个，上移 / 下移 / 删除）。默认别名 `main` 必填（服务端没有 main 时顶部警告“未配置模型（main），运行会等待 key”），
  最多 16 个别名，别名不能重复，降级项不能和主 key + 主模型完全一样。保存 `setModelRoutes`（整表替换，main 在前）后重新取；
  服务端拒绝时刷新 key 列表并提示。从 key 页回来时重新取 key（不动正在编辑的内容）。
- **用量**（`usage`，入口：设置页、key 列表顶栏）：时间段（今天 / 7 天 / 30 天 / 自定义：页面里的 `DateRangePicker`，不是对话框，
  只能选今天及以前、最多 366 天）× 分组（按天 / 实例 / 模型 / key），按设备时区切天（`tz`）。总计卡片（请求、记账 token、输入、
  输出、缓存命中 / 写入、估算、失败）；按天时 Canvas 柱状图（主色柱子，空的天画描边色底线，读屏读一句汇总），各分组是表格
  （名字 + 记账 token，下一行请求 / 输入 / 输出 / 缓存 / 失败）。实例名、key 标签、厂商名只用来显示，拉不到显示 id，已删除的标出来。
- 文案都在 strings.xml；token 的写法（万 / k）由资源 `number_style` 决定。key 标签、实例名是用户起的，厂商说明是平台写的，都不标 AI 生成。

## 云端审批（13.16）

- **卡片**（`:design` 的 `ApprovalCard`，界面模型 `ApprovalCardUi`；对话页 13.5 直接嵌入）：AI 生成标识 + agent 写的标题
  （第 8.4 节）、工具调用摘要（图标、标题、类别、参数一句话：`command` / `path` / `url`……，最多 200 字；“查看原始请求”展开
  排好版的 JSON）、选项按钮（`allow_once` / `allow_always` 主按钮在前，`reject_once` / `reject_always` 次按钮；四种已知的用本地文案
  “批准 / 一直允许 / 拒绝 / 一直拒绝”，不认识的 kind 用 agent 给的名字、按批准类处理要验证）、到期倒计时（不到 1 小时警告色）；
  决定之后换成结果：谁决定的（你 / 预授权策略 / 超时 / 运行结束）、选了什么（只在“一直……”和不认识的选项时说）、相对时间；
  作废（待处理但 `attempt` 比运行当前的尝试小）显示“已作废：运行已重试”，不能点。
- **数据**（`:data` 的 `model/ApprovalCards.kt`）：`ApprovalCards.fromApproval(approval, currentAttempt)` 给审批中心；
  `ApprovalCards.reconcile(events, approvals, runAttempts)` 给对话页：`agent.permission_requested` 出卡片，键是
  (run_id, attempt, request_id)（`ApprovalKey.matches`，老数据 attempt 为 0 时只比另外两个）；`agent.permission_resolved` 以
  `approval_state` 为准（平台判的超时 `by` 是 user、`approval_state` 是 expired → 过期 / 超时），没有时按 `by` 和选项 kind；
  按策略直接决定的没有请求、不出卡片；`approval.decided` 是别处做的决定；审批记录按键或 `approval_id` 对上，补上审批 id、到期时间、
  完整的工具调用（事件里常常只有 `tool_call_id`），事件已经是终态的不会被旧列表改回待处理；`run.state` 的 `attempt` 和传进来的
  `Run.attempt` 取大的判作废。`applyDecision` 用 `decideApproval` / `getApproval` 返回的记录更新卡片。
- **审批中心**（路由 `approvals`，入口：抽屉“审批”（待处理数角标）、收件箱审批条目、推送深链）：`approvals()` 的待处理列表，
  每条查一次所在运行（`getRun`，查不到的不判作废），按实例分组（组里最新的在前，组标题“实例名 · N 条待处理”，拉不到实例名显示
  “已删除的实例”），下拉刷新（Material 3 的 `PullToRefreshBox`）；加载失败且没有列表时整页错误 + 重试，有列表时 Snackbar；
  从详情页回来重新取。决定之后卡片原地变成结果，下次刷新才移走。
- **审批详情**（`approval/{id}`，深链 `thinktin://approval/{id}`）：`getApproval` 什么状态都能查，已处理 / 过期 / 取消的显示结果、
  不报错；404 显示“找不到这条审批”。卡片（原始请求默认展开）+ 实例（点进对话）、运行（状态，点进运行详情）、第几次尝试
  （运行已到更新的尝试时标出来）、请求 / 到期 / 处理时间。
- **决定**（`ApprovalActions` + `ApprovalDecider`，三个地方共用）：拒绝类直接发（不验证，没有锁屏也能拒绝）；批准类先查
  `ApprovalGate.availability()`：没有锁屏凭证 → “先设置锁屏密码”（“去设置”打开 `ACTION_SET_NEW_PASSWORD`，退到安全设置），
  做不了 → “无法验证身份”；可以 → 确认框（`allow_always` 加一句“同类操作不再询问”）→ `BiometricPrompt` → `decideApproval`。
  用户取消什么都不发；锁定 / 失败提示，不发。服务端 409 / 404 / 410 / expired → 重新 `getApproval`，显示最新结果
  （“已经处理过了” / “已过期” / “已取消”），查不到就移走；网络等可重试的错误 Snackbar 带“重试”，重试同一个决定时不再验证一次。
- **身份确认**（`ApprovalGate`，`AppContainer.approvalGate`，测试里换成假的）：`BiometricApprovalGate` 用 androidx.biometric，
  允许 `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`（没有生物识别时用锁屏密码）；API 28–29 系统不支持这个组合，用
  `BIOMETRIC_WEAK or DEVICE_CREDENTIAL`。它不持有 Activity：`MainActivity.onCreate` 把自己登记到 `AppContainer`（弱引用），
  弹提示框时才取，旋转屏幕后 ViewModel 里的 gate 照样能用。所以 `MainActivity` 是 `FragmentActivity`，窗口主题的父主题换成
  AppCompat（API 26–27 的指纹对话框是 AppCompat 的，非 AppCompat 主题会崩）。提示框的描述里 agent 写的标题加 AI 生成标识。
- **收件箱条目去哪**：`navigation/InboxTargets.kt` 的 `InboxItem.targetRoute()`（审批 → `approval/{id}`，没有 id → 审批中心；
  保险箱请求、计划待确认、运行……），收件箱页面（13.8）点条目时用它。
- 测试：`:data` 的 `ApprovalCardsTest`（对上、作废、超时、策略、旧列表不回退、摘要）、`:design` 的 `ApprovalCardTest`、
  `:app` 的 `ApprovalViewModelTest`（列表、详情、过期 / 已处理、生物识别成功 / 取消 / 锁定 / 无凭证、拒绝直接发、重试不再验证、
  作废）和 `ApprovalUiTest`（抽屉进审批中心、批准经假的 gate、拒绝直接发、无锁屏提示、深链打开详情 / 过期 / 不存在）。

## 对话与运行过程（13.5）

- **归并**（`:data` 的 `model/Conversation.kt`，纯函数 `ConversationBuilder.build(runs, events, approvals, vaultRequests, window)`）：
  按 run_id 把事件归到运行区块，区块内按 seq 排序、重复的 seq 只算一次；相邻的 `agent.message` 拼成一段 Markdown，相邻的
  `agent.thought` 拼成一个折叠块；`agent.tool_call` + `tool_call_update` 按 `tool_call_id` 合成一张卡（更新先到也只有一张）；
  `agent.platform_tool_call` 卡；`agent.plan` 清单（后来的覆盖前面的）；审批事件交给 13.16 的 `ApprovalCards.reconcile`
  （关联键 (run_id, attempt, request_id)、`approval_state` 优先于 `by`、旧尝试的待处理卡作废）；`vault.requested` / `fulfilled` /
  `declined` 合成填写请求卡（和 `vaultRequests(all = true)` 的记录对上，终态不会被旧记录改回待处理）；`artifact.published`
  产出物卡；`pipeline.step_started` / `delegate.started` 子运行入口；`run.state` 只有等待 / 重试 / 失败 / 取消 / 新的一次尝试才出
  状态行（带 `wait_code`）；`plan.needs_confirmation` / `plan.cancelled` 计划卡；`agent.error` / `session_lost` / `exited` /
  `run.log_truncated` / 异常的 `stop_reason` 是系统行。`agent.usage`、`turn_started` / `turn_ended`、`ready`、`update`、
  `instance.state` 不进时间线（`turn_ended` 结束流式状态，usage 记在区块上）。不认识的 kind 是灰色系统行；payload 缺字段、类型不对不崩。
  没有 run_id 的（计划卡等）按时间插在运行之间。运行树（`model/RunTree.kt` 的 `RunTrees.build`）：平铺 → 缩进树，卡在等 key /
  等电脑 / 等审批的子孙冒泡到祖先（等 key、等电脑排在等审批前面）。
- **对话页**（`chat/{instanceId}?runId=…`，入口：抽屉实例、首页输入框、首页“最近运行”（带 runId，定位到那个运行；不在已加载的
  范围里时往前翻最多 5 页去找））：
  - 打开先 `cachedInstances` + `cachedRuns` + `cachedEventsBefore`（最后一屏）渲染，再订阅 `events(instanceId)` 实时追加，同时
    联网刷新实例、运行、待处理审批、保险箱请求；补发的事件按批归并（排到主线程队列后面，缓冲里已到的先收完）。上拉到顶：
    `cachedEventsBefore` 往前翻一屏 + `olderRuns`。比已加载的最早事件还早的运行等翻到再显示；缓存翻到头的标“本机没有过程记录”。
  - `on_reset`：清空事件、保留运行并重新 `runs()`；比 `oldest_seq` 早的运行只显示 prompt / summary / error，标“过程记录已超过保留期”。
  - 顶部细条：连接中 / 重连中 / 事件流断了（“重新连接”）/ 离线显示缓存。`NotFound` 和 404 回首页；`SignedOut`、
    `AccountFrozen`、`UpgradeRequired` 由服务的 `authState` / `upgradeState` 换整个界面。
  - 顶栏：实例名 + 状态点（点进实例设置），更多：运行树（当前运行，没有就最新的）、实例设置。
  - 时间线：`LazyColumn(reverseLayout = true)` 锚定底部；用户在底部时新内容跟着滚，往上翻时不抢，右下角“回到底部”。每个运行：
    区块头（来源 你 / 计划 / 流水线 / 委派、状态、耗时、token，点进运行页）→ 提问（用户的右侧气泡；委派、流水线的 prompt 标 AI
    生成、不显示成“你”）→ 过程 → 摘要（标 AI）/ 失败原因（平台诊断，不标）。
  - agent 文本：左侧无气泡，`:design` 的 `MarkdownText`（commonmark 解析 + Compose 渲染，不用 WebView：标题、列表、引用、
    代码块（横向滚动、复制按钮）、行内代码、链接、粗斜体、删除线、表格（简化成网格）、图片显示成替代文字的链接、HTML 原样当文字）。
    长按复制（读屏是自定义操作“复制”），复制的文字末尾追加 `【AI 生成】` / `[AI-generated]`；代码块的复制同样追加。
  - 工具调用卡：`:design` 的 `ToolCallCard`（按 kind 选图标：读 / 改 / 搜 / 执行 / 出网 / 电脑……，展开看原始内容）；审批卡嵌
    13.16 的 `ApprovalCardItem`（决定经 `ApprovalActions` → `ApprovalGate`）；产出物卡（名字、大小、版本；打开 / 分享：
    `artifactContent` 下载到 `cacheDir/artifacts/<id>/<名字>`，FileProvider 交给系统，只转圈，超过 20 MiB 提示不下载）；
    填写请求卡（agent 写的用途标 AI，“填写” / “拒绝”，已填写 / 已拒绝 / 已过期）；子运行入口；计划卡（“去确认”）。
  - 等待类横幅（警告色，输入框上方）：等审批 → 去审批（本页有能点的卡就滚过去，没有去审批中心）；等 key → 按 `wait_code`
    去配 key / 去配模型（限频、过载只提示）；等电脑 → 查看设备。运行中顶部细进度条，输入框为空时发送键变停止
    （`cancelRun(wholeTree = true)`）。
  - 发送：`detectSecrets` 有命中 → 盖在页面上的底部表单（不是对话框）：名字（`uniqueVaultName` 避开已有条目，冲突 409 再换一个）、
    用途、账号、密码（预填命中值）→ `saveSecretFromMessage` → 换成 `[vault:名字]` 的文本放回输入框，还有命中接着弹；
    私钥（`storable = false`）只提示不发；“仍然发送”二次确认后 `sendMessage(allowSecrets = true)`；`sendMessage` 抛
    `ContainsSecrets` 同样处理。发出后新运行马上进时间线（乐观），失败回填输入框并给“重试”。首页输入框拦下密码时把消息转给
    对话页（`DraftHandoff`），在那里弹表单。
  - agent 的填写请求：底部表单（账号、密码、用途）→ `fulfillVaultRequest`，或 `declineVaultRequest`；已处理 / 过期的重新取记录。
- **运行页**（`run/{runId}`，深链 `thinktin://run/{id}`）：详情（状态、来源、第几次尝试、耗时、token、输入 / 输出 token（本机
  缓存里最近一次 `agent.usage`）、摘要 / 错误、产出物列表）+ 运行树（`runTree(rootRunId)`：缩进，每行状态点、实例名、耗时，
  点节点换详情；单个停止 `cancelRun(id, false)`，“停止整棵树”二次确认后从根 `cancelRun(root, true)`）。卡在等 key 的子步骤冒泡到
  根节点显示横幅（去配模型）。深链指向子运行时取整棵树、选中那个节点（标“当前”）。“在对话中查看”回对话页并定位。
- 测试：`:data` 的 `ConversationBuilderTest`（8.2 表里每种 kind、乱序 / 重复 seq、未知 kind、坏 payload、审批关联键与作废、
  超时、on_reset 与翻页的缺口、流式状态、委派 prompt 的 AI 标识……）、`RunTreesTest`；`:design` 的 `MarkdownTest`；
  `:app` 的 `ChatViewModelTest`（打开、补发按批、续传、on_reset、状态细条、翻页、定位、发送 / 乐观 / 失败、拦截 / 重名 / 仍然发送 /
  私钥、取消、等待横幅、审批经 gate、填写请求、产出物）、`RunViewModelTest` 和 Robolectric 的 `ChatUiTest`（最近运行定位、
  Mock 的各类事件、复制带 AI 标识、发送后出气泡、拦截弹表单、填写请求、运行页运行树、更多菜单进运行树并停止）。

## 深链

`thinktin://run/{id}`、`approval/{id}`、`plan/{id}`、`instance/{id}`、`vault/request/{id}`、`inbox`、`inbox/{id}`（第 3 节）。
`MainActivity` 是 `singleTask`：冷启动（`onCreate`）和 App 已在运行时（`onNewIntent`）收到的深链都放进 `DeepLinkInbox`，
由 `MainNavigation` 在导航图建好后交给 `NavController.handleDeepLink`，返回栈是“首页 → 目标页”。未登录时先留着，登录后再跳；
同一条只处理一次。测试：`DeepLinkTest`（4 种骨架页的冷启动）+ `CatalogUiTest`（`instance/{id}`）、`ApprovalUiTest`（`approval/{id}`）、`ChatUiTest`（`run/{id}`）、`AppUiTest`（热启动）、`AppRootTest`（登录后再跳）。

## CI

`.github/workflows/android.yml`（名为 Android）：改动 `apps/android/**`、`crates/client-core/**`、`crates/proto/**`、
`tools/client-core/**`、`Cargo.toml`、`Cargo.lock` 时触发，也可以手动触发。步骤：`sync-core.sh --check`（绑定一致，同时编出本机 .so）→
`./gradlew test lint assembleDebug :app:assembleCnRelease`（`THINKTIN_REQUIRE_CORE=1`，CoreSmokeTest 必须真跑；lint 的
abortOnError 开着，不用 baseline；release 包跑一遍 R8）→ 解开 release 包检查 dex 里还有只经 JNI 用到的类
（`CertificateVerifier`、`TlsInit`，保留规则漏了在这一步失败）→ 上传 `app-cn-debug.apk`。

**有意**不在这个 workflow 里交叉编译三个 ABI 的 .so（NDK + cargo-ndk 每次几十分钟，每个 PR 都跑不划算），所以这个 APK
**不含 jniLibs**，只能用演示模式（关掉演示模式会显示“无法加载核心库”页）。绑定和库是否对得上由 `--check` 和 CoreSmokeTest 保证。
带 .so 的完整包：手动跑 `mobile.yml` 的 android job，把产物 `thinktin-core-android` 解压成 `<目录>/thinktin-core/`，
`sync-core.sh --from <目录>` 后打包；本地直接 `sync-core.sh`（或先跑 `build-android.sh` 再 `--from target/android`）。

## 第三方依赖与许可证

只用 Apache-2.0 / MIT / BSD 类许可证的库（打进 App 的；版本见 `gradle/libs.versions.toml`）。新增依赖先在这里登记。

| 依赖 | 用途 | 许可证 |
|---|---|---|
| AndroidX（core-ktx、activity-compose、lifecycle、navigation-compose、datastore、security-crypto）、Jetpack Compose（BOM、Material 3、图标） | 基础框架与界面 | Apache-2.0 |
| `androidx.biometric:biometric`（13.16） | 批准审批前的 BiometricPrompt | Apache-2.0 |
| `androidx.appcompat:appcompat`（13.16） | biometric 在 API 26–27 的指纹对话框要 AppCompat 主题（也带来 `androidx.fragment` 的 FragmentActivity） | Apache-2.0 |
| `org.commonmark:commonmark`、`commonmark-ext-gfm-tables`、`commonmark-ext-gfm-strikethrough`（13.5） | 对话页 agent 文本的 Markdown 解析（Compose 自己渲染） | BSD-2-Clause |
| kotlinx-coroutines、kotlinx-serialization-json | 协程、JSON | Apache-2.0 |
| JNA（`net.java.dev.jna:jna`） | UniFFI 绑定调 client-core | Apache-2.0 / LGPL-2.1 双许可，按 Apache-2.0 使用 |
| `org.rustls:rustls-platform-verifier` | client-core 的系统证书校验（JNI） | Apache-2.0 / MIT |
| client-core 依赖的 Rust crate | 见 `assets/thinktin-licenses/`（`sync-core.sh` 生成） | 见清单 |

只在测试里用、不打进 App：JUnit 4（EPL-1.0）、Robolectric（MIT）、Turbine（Apache-2.0）、androidx.test（Apache-2.0）。

## 约定

- 测试统一用 **JUnit 4**（`junit:junit`），不用 JUnit 5：Robolectric 的 runner 和 Compose 的测试规则（`createComposeRule`）
  都基于 JUnit 4，混用两套引擎只会多一层 vintage。规范第 1 节已按此修订。纯逻辑测试（`:data`、`:core`、ViewModel）
  也用 JUnit 4 + kotlinx-coroutines-test + Turbine；界面测试是 Robolectric 跑的 Compose 测试。

- 文案全部进资源：`res/values`（中文，默认）和 `res/values-en`（英文），两边的键必须一致（lint 会查）。
  代码标识符用英文，注释用中文。
- 服务端的状态字符串在 `:data` 里转成枚举（`InstanceState`、`RunState`、`InboxKind`……），未知取值一律 `Unknown`，界面不崩。
  时间统一是 Unix 毫秒（Long），相对时间用 `RelativeTime`。
- 一个页面一个 ViewModel（`StateFlow<UiState>`，一次性事件用 Channel），用 `viewModel(factory = viewModelFactory { … })`
  从 `LocalThinktinService` / `LocalAppContainer` 取依赖；不引入 Hilt。
- 错误：服务调用抛 `ServiceError`；文案由 `:app` 的 `ErrorText` 映射（`isRateLimited`、`isInvalid`、`isRetryable` 给表单页
  做字段级提示和“重试”）；`SignedOut` 回登录流，`AccountFrozen` 显示冻结页（由 `ThinktinService.authState` 驱动）。
- 按钮用 `:design` 的 `PrimaryButton` / `DangerButton`（错误色，注销、删除）/ `SecondaryButton`（描边），统一 20dp 圆角、
  24/12 内边距和转圈；不直接用 M3 的 `Button` / `OutlinedButton`（默认是胶囊形）。
- 倒计时（验证码重发、限频剩余秒数）用 `ui/common/Countdown`，跑在 viewModelScope 上，测试里用 TestCoroutineScheduler 推进。
- 对话框（`AlertDialog`）里不放输入框：Robolectric 下一直不空闲。要输入的做成单独的页面（见“登录与账号”）。
- 无障碍：图标按钮都有 `contentDescription`；edge-to-edge 下用 Scaffold 的 innerPadding / `navigationBarsPadding` / `imePadding`。
- 不提交生成的 `.so` 和许可证资源；`client_core.kt` 只通过脚本更新，不手改。
- 服务调用只抛 `ServiceError`（`CoreThinktinService` 把 `ClientException` 之外的异常，包括 Rust panic 的 `InternalException`，
  也包成 `ServiceError.Other`；取消照常抛出）；ViewModel 里只 catch `ServiceError`，catch 宽异常时先放行 `CancellationException`。
- `cached*` 是挂起函数（真实实现在 IO 线程上读 SQLite），ViewModel 在协程里调，不在构造时同步读。
- AI 生成标识（第 8.4 节）用 `:design` 的 `AiGeneratedLabel`：agent 文本 / 思考 / 计划按 `ai_generated`；工具调用和平台
  工具调用的标题、审批标题、填写请求的用途、委派标题、委派 / 流水线子运行的 prompt、`Run.summary`、`plan.needs_confirmation`
  的标题由 App 补标；`Run.error`（平台诊断）、用户自己的 prompt、平台文案不标。复制 agent 输出时末尾追加标识文字。

## 已知问题

- 登录页“用户协议”“隐私政策”还只是说明文字，没有链接（正式地址未定，13.13 关于页一起做）；冻结页只写“联系客服”，
  没有具体渠道（客服邮箱 / 工单地址未定）。
- 验证码没有接 SMS Retriever / 一次性验证码自动填充（需要服务端短信模板带 App 哈希）；推送令牌在 13.8 接，现在登录传 null。

- `tools/client-core/build-android.sh` 没有“跳过 AAR”的开关，`sync-core.sh` 用 PATH 垫片绕过（见上）。以后给它加一个开关
  （比如 `THINKTIN_SKIP_AAR=1`）并去掉 `jvmToolchain(17)` 的硬要求后，删掉垫片。
- 审批的身份确认（`BiometricApprovalGate`）只在 JVM 上测了映射（认证方式、错误码），提示框本身要真机验证：
  有指纹 / 面容、只有锁屏密码、没有锁屏（应提示先设置）、API 28–29（WEAK + 凭证）、API 26–27（AppCompat 指纹对话框）、
  提示框弹出时旋转屏幕。通知上的“拒绝”快捷操作随 13.8 推送一起做（先 `getApproval` 确认还是待处理再发）。
- Robolectric 的触摸注入点不到盖在页面上的层（抽屉、领养面板）：触摸落到了下面的内容 / 遮罩上（真机正常），
  这些控件在测试里用无障碍点击动作（`SemanticsActions.OnClick`）。
- 每日 token 限额只能在添加 key 时设：client-core 的 `update_credential` 只有标签和停用（服务端 `PATCH` 也一样），编辑页只读显示。
- 服务端删除实例只是标记删除，`model_routes` 还留着：被已删除实例的别名引用的 key 永远删不掉（409），App 也查不到那些别名
  （提示“还有模型别名在用这把 key”，并说明可能是已删除实例留下的、可以先停用）。需要 backend-core 在删除实例时清掉它的别名，
  或删除 key 时不算已删除的实例。同样，删除实例后其他计划里引用它的流水线步骤也还在（运行到时会失败），只有团队读取时会过滤掉它；
  设计规范 8.6 写的“级联删除”和后端不一致，待 backend-core 确认以哪边为准。在那之前确认框写“这些步骤之后会运行失败”，Mock 也按软删除实现。
- 用量按天的 `key` 按日期解析（`yyyy-MM-dd`）；服务端换格式时柱状图会退化成只有表格。
- CI 的 APK 不含 .so（见“CI”）。启动时 `TlsInit` 加载不到库，`TlsState.failure` 记下 `UnsatisfiedLinkError`，演示模式照常可用。
- `TlsInit.initialize`（JNI）只能在真机 / 模拟器上验证（云端会话没有模拟器，JVM 上的 .so 是 Linux 版，没有这个 JNI 函数）；
  `initLogging`、`accept_language_header` 是普通的 UniFFI 导出，`:core` 的 CoreSmokeTest 经 JNA 调本机 .so 覆盖了，
  但 Android 上的 .so 和 logcat 输出同样要真机确认：第一次真机联调 https 时确认没有 `TlsUnavailable`、事件流能连上、
  logcat 里有 `ThinktinCore` 的日志、请求带着 `Accept-Language`。
