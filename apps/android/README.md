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
├─ scripts/patch-bindings.py      给生成的绑定打 Kotlin 2 兼容补丁（sync-core.sh 调用）
├─ core/    :core   client-core 的 UniFFI Kotlin 绑定（cn.thinktin.core）+ 手写的 TlsInit + jniLibs，见 core/README.md
├─ data/    :data   App 模型、ThinktinService 接口、CoreThinktinService（真实）、MockThinktinService（演示）、
│                   SecureSessionStore、ClientFactory、TlsState
├─ design/  :design ThinktinTheme（色板、字体、形状）与通用组件（顶栏、主按钮、状态点、输入框、消息、横幅……）
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
是生成物，不提交。UniFFI 0.32 给错误里名叫 `message` 的字段生成的代码过不了 Kotlin 2 的编译，
`scripts/patch-bindings.py` 会自动修，见该文件开头的说明。`core/src/main/kotlin/cn/thinktin/core/TlsInit.kt`
是手写的（见下一节），脚本不碰它。

client-core 的 App 接口已全部接进 `ThinktinService`，`CoreThinktinService` 里没有再抛 `ServiceError.Unsupported` 的方法
（这个类型留给以后新加、还没接的接口）：

- 11.7：资料、设备列表与吊销、注销账号、实例详情、运行翻页、产出物、改计划与触发器、收件箱单条 / 标未读 / 删除、
  团队与模板、改 key / 换 key、手机和电脑之间的消息、`cachedEventsBefore`（对话页先显示最后一屏）；5.5 的举报。
- 11.8：`ClientConfig.acceptLanguage` + `setAcceptLanguage`（见下一节“启动顺序”）、`initLogging`（`:data` 的 `CoreLogging`）、
  `upgradeRequired()`、跨实例的 `listRuns(RunFilter, before, limit)`、`Run.waitCode`（`WaitCode` 枚举，界面按码出文案）、
  `Plan.nextFireAtMs` / `invalidTriggers`、`Trigger.disabledReason`、`AgentInfo` 的介绍 / 上游 / 许可说明 / 协议、
  `Credential.protocols`。吊销本机设备时 client-core 自己清登录态，`authState` 跟着变成未登录（回登录页）。

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
./gradlew test lint assembleDebug        # 全部单元测试、lint、debug 包
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
2 个实例、覆盖全部事件类型的运行、5 种收件箱条目、计划、key、保险箱、团队与模板、登录设备、设备消息、举报……），
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
  “下次唤醒生效，工作区保留”；目录拉不到时只是没有版本选项。模型别名入口指向 `instance/{id}/routes`（13.4 做页面）。
- **删除实例**（第 8.6 节）：先 `plans()` + `teams()` 算出影响（`DeleteImpact`：它自己的计划、别的计划里引用它的流水线步骤数、
  它是成员的团队），确认框列出计划和团队名（agent 建的计划标题标 AI 生成），“继续”后二次确认再 `deleteInstance`；
  查不到影响范围就不让删（Snackbar 说明原因）；已经被删（404）当作成功。成功后刷新抽屉、回首页（首页重新创建）。
- **首页**：没有实例时显示衬线问候 + “领养一个 agent” + 目录前 3 个精选卡片；抽屉实例行显示名字、agent 显示名（目录拉不到时
  显示 id）、状态点，长按或右侧“更多”进实例设置。

## 深链

`thinktin://run/{id}`、`approval/{id}`、`plan/{id}`、`instance/{id}`、`vault/request/{id}`、`inbox`、`inbox/{id}`（第 3 节）。
`MainActivity` 是 `singleTask`：冷启动（`onCreate`）和 App 已在运行时（`onNewIntent`）收到的深链都放进 `DeepLinkInbox`，
由 `MainNavigation` 在导航图建好后交给 `NavController.handleDeepLink`，返回栈是“首页 → 目标页”。未登录时先留着，登录后再跳；
同一条只处理一次。测试：`DeepLinkTest`（7 种冷启动）、`AppUiTest`（热启动）、`AppRootTest`（登录后再跳）。

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
- AI 生成标识（第 8.4 节）用 `:design` 的 `AiGeneratedLabel`；首页最近运行的 `summary`、委派子运行的 `prompt` 已经标了，
  `error` 等 13.5 能区分 agent 写的部分后再标。

## 已知问题

- 登录页“用户协议”“隐私政策”还只是说明文字，没有链接（正式地址未定，13.13 关于页一起做）；冻结页只写“联系客服”，
  没有具体渠道（客服邮箱 / 工单地址未定）。
- 验证码没有接 SMS Retriever / 一次性验证码自动填充（需要服务端短信模板带 App 哈希）；推送令牌在 13.8 接，现在登录传 null。

- `tools/client-core/build-android.sh` 没有“跳过 AAR”的开关，`sync-core.sh` 用 PATH 垫片绕过（见上）。以后给它加一个开关
  （比如 `THINKTIN_SKIP_AAR=1`）并去掉 `jvmToolchain(17)` 的硬要求后，删掉垫片。
- Robolectric 的触摸注入点不到盖在页面上的层（抽屉、领养面板）：触摸落到了下面的内容 / 遮罩上（真机正常），
  这些控件在测试里用无障碍点击动作（`SemanticsActions.OnClick`）。
- CI 的 APK 不含 .so（见“CI”）。启动时 `TlsInit` 加载不到库，`TlsState.failure` 记下 `UnsatisfiedLinkError`，演示模式照常可用。
- `TlsInit.initialize`（JNI）只能在真机 / 模拟器上验证（云端会话没有模拟器，JVM 上的 .so 是 Linux 版，没有这个 JNI 函数）；
  `initLogging`、`accept_language_header` 是普通的 UniFFI 导出，`:core` 的 CoreSmokeTest 经 JNA 调本机 .so 覆盖了，
  但 Android 上的 .so 和 logcat 输出同样要真机确认：第一次真机联调 https 时确认没有 `TlsUnavailable`、事件流能连上、
  logcat 里有 `ThinktinCore` 的日志、请求带着 `Accept-Language`。
