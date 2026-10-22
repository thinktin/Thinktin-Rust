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

client-core 的 App 接口（11.7、11.8 的 `cachedEventsBefore`、5.5 的举报）已全部接进 `ThinktinService`：
`CoreThinktinService` 里没有再抛 `ServiceError.Unsupported` 的方法（这个类型留给以后新加、还没接的接口）。
只给 iOS 的实时活动（`registerLiveActivity`、`endLiveActivity`、`setLiveActivityStartToken`）不接。
Rust 接口再变时：`sync-core.sh --bindings-only` → 在 `:data` 的模型、`Mappers.kt`（两个方向）、
`ThinktinService`、`CoreThinktinService`、`MockThinktinService` 里跟上 → 补映射和服务的单测。

## TLS 初始化（Android 上的 HTTPS）

client-core 的接口请求和事件流用 `rustls-platform-verifier` 做系统证书校验（和系统设置里信任的证书一致），
它在 Android 上要经 JNI 调系统的 `X509TrustManager`，所以**建 `ThinktinClient` 之前必须先初始化**
（`crates/client-core/src/tls.rs`）：

- `:core` 的 `TlsInit`（手写）：`System.loadLibrary("client_core")` + `external fun initialize(context)`，
  对应 Rust 导出的 `Java_cn_thinktin_core_TlsInit_initialize`。`loadLibrary` 不能省：JNA 的 dlopen 不会注册 JNI 函数。
- `ThinktinApp.onCreate` 先 `initializeTls()`（`:data` 的 `SystemTls`，失败不崩溃，原因记在 `TlsState.failure`），
  再建 `AppContainer`；`ClientFactory.createService(context, baseUrl, tls)` 在 base_url 是 https 而 `tls.ready` 为假时
  抛 `ServiceError.TlsUnavailable`（界面显示“无法加载核心库”页和原因），不让 Rust 那边报一个看不懂的内部错误。
  http 的本地联调地址不需要初始化。
- Java 支持包 `org.rustls:rustls-platform-verifier`（AAR）由 `:core` 依赖：版本**必须**和 `Cargo.lock` 里
  `rustls-platform-verifier-android` 的一致，`core/build.gradle.kts` 用 `ValueSource` 从 `../../Cargo.lock` 读
  （`strictly`，Rust 升级后 Gradle 自动跟上），`libs.versions.toml` 里的坐标不写版本。仓库在 `settings.gradle.kts`：
  `https://raw.githubusercontent.com/rustls/rustls-platform-verifier/maven-archive/android-release-support/maven/`
  （只放 `org.rustls` 组；README 里 `github.com/…/raw/…` 的写法多一次重定向，云端会话的代理下是 403）。
  `RustlsVerifierVersionTest` 用独立的解析器读 Cargo.lock，和 Gradle 声明的、实际解析到的版本比对，并确认类在类路径上。
- R8：`:core` 的 `consumer-rules.pro` 保留 `org.rustls.platformverifier.**`（只经 JNI 调用，R8 看不见）。
- 测试：本机 `target/debug/libclient_core.so` 是 Linux 版，没有这个 JNI 函数。JVM / Robolectric 测试**不调**
  `TlsInit.initialize`：`DemoTestApp` 覆盖 `initializeTls()` 返回 `FixedTlsState`，`:data` 的 `TlsStateTest`
  用假的初始化函数测 `SystemTls` 和 `ClientFactory.checkTls`。真正的 JNI 初始化只能在真机 / 模拟器上验证。

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
不联网、不调 Rust（只有启动时 `TlsInit` 会加载一次 `libclient_core.so` 做证书校验初始化，没有 .so 时只记下失败）。
设置页里可以关掉，关掉后走 `CoreThinktinService` → client-core → 服务端，未登录时显示登录流；登录页和“核心库不可用”页
也有“使用演示模式”。

release 包没有演示模式（第 7 节）：上面三个入口都不显示，`AppSettingsRepository(demoAllowed = false)` 也忽略已经存下的
`demo_mode`（比如从 debug 包覆盖安装），release 用户不会困在假数据里。

真实服务（`ClientFactory.createService`：检查 TLS 初始化、加载 .so、打开 SQLite、读 Keystore）在 `AppContainer` 里第一次用到时才在
IO 线程上创建，创建中显示加载，任何异常（`UnsatisfiedLinkError`、契约版本不一致的 `ExceptionInInitializerError`、
Keystore 失效……）都显示“无法加载核心库”页（原因 + 重试），不崩溃。`SecureSessionStore` 遇到 Keystore 失效或偏好文件损坏时
删掉重建，还不行就退回内存存储，读不出的令牌按未登录处理。

## 深链

`thinktin://run/{id}`、`approval/{id}`、`plan/{id}`、`instance/{id}`、`vault/request/{id}`、`inbox`、`inbox/{id}`（第 3 节）。
`MainActivity` 是 `singleTask`：冷启动（`onCreate`）和 App 已在运行时（`onNewIntent`）收到的深链都放进 `DeepLinkInbox`，
由 `MainNavigation` 在导航图建好后交给 `NavController.handleDeepLink`，返回栈是“首页 → 目标页”。未登录时先留着，登录后再跳；
同一条只处理一次。测试：`DeepLinkTest`（7 种冷启动）、`AppUiTest`（热启动）、`AppRootTest`（登录后再跳）。

## CI

`.github/workflows/android.yml`（名为 Android）：改动 `apps/android/**`、`crates/client-core/**`、`crates/proto/**`、
`tools/client-core/**`、`Cargo.toml`、`Cargo.lock` 时触发，也可以手动触发。步骤：`sync-core.sh --check`（绑定一致，同时编出本机 .so）→
`./gradlew test lint assembleDebug`（`THINKTIN_REQUIRE_CORE=1`，CoreSmokeTest 必须真跑；lint 的 abortOnError 开着，不用 baseline）
→ 上传 `app-cn-debug.apk`。

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
- 错误：服务调用抛 `ServiceError`；文案由 `:app` 的 `ErrorText` 映射；`SignedOut` 回登录流，`AccountFrozen` 显示冻结页
  （由 `ThinktinService.authState` 驱动）。
- 无障碍：图标按钮都有 `contentDescription`；edge-to-edge 下用 Scaffold 的 innerPadding / `navigationBarsPadding` / `imePadding`。
- 不提交生成的 `.so` 和许可证资源；`client_core.kt` 只通过脚本更新，不手改。
- 服务调用只抛 `ServiceError`（`CoreThinktinService` 把 `ClientException` 之外的异常，包括 Rust panic 的 `InternalException`，
  也包成 `ServiceError.Other`；取消照常抛出）；ViewModel 里只 catch `ServiceError`，catch 宽异常时先放行 `CancellationException`。
- `cached*` 是挂起函数（真实实现在 IO 线程上读 SQLite），ViewModel 在协程里调，不在构造时同步读。
- AI 生成标识（第 8.4 节）用 `:design` 的 `AiGeneratedLabel`；首页最近运行的 `summary`、委派子运行的 `prompt` 已经标了，
  `error` 等 13.5 能区分 agent 写的部分后再标。

## 已知问题

- `tools/client-core/build-android.sh` 没有“跳过 AAR”的开关，`sync-core.sh` 用 PATH 垫片绕过（见上）。以后给它加一个开关
  （比如 `THINKTIN_SKIP_AAR=1`）并去掉 `jvmToolchain(17)` 的硬要求后，删掉垫片。
- CI 的 APK 不含 .so（见“CI”）。启动时 `TlsInit` 加载不到库，`TlsState.failure` 记下 `UnsatisfiedLinkError`，演示模式照常可用。
- `TlsInit.initialize` 的 JNI 调用只能在真机 / 模拟器上验证（云端会话没有模拟器，JVM 上的 .so 是 Linux 版）：
  第一次真机联调 https 时确认没有 `TlsUnavailable`、事件流能连上。
- 计划列表（`plans`）里的 `triggers`、`steps` 为空（服务端列表接口不带），`Plan.nextFireAtMs` 在列表里是 null；
  要显示下次触发时间得取详情（`getPlan`），13.6 做计划页时处理。演示数据的列表里带着触发器，和真实服务不完全一样。
