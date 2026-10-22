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
├─ core/    :core   client-core 的 UniFFI Kotlin 绑定（cn.thinktin.core）+ jniLibs，见 core/README.md
├─ data/    :data   App 模型、ThinktinService 接口、CoreThinktinService（真实）、MockThinktinService（演示）、
│                   SecureSessionStore、ClientFactory
├─ design/  :design ThinktinTheme（色板、字体、形状）与通用组件（顶栏、主按钮、状态点、输入框、消息、横幅……）
└─ app/     :app    Application、MainActivity、抽屉 + 导航、各页面与 ViewModel
```

依赖方向：`:app → :design → :data → :core`。

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
apps/android/scripts/sync-core.sh                        # 交叉编译三个 ABI，再同步绑定、.so、许可证
apps/android/scripts/sync-core.sh --from target/android  # 已经跑过 tools/client-core/build-android.sh：只同步
apps/android/scripts/sync-core.sh --bindings-only        # 只重新生成 Kotlin 绑定（只需要 cargo）
apps/android/scripts/sync-core.sh --check                # 只检查提交的绑定和 Rust 一致（CI 跑这个）
```

`client_core.kt` 提交进 git；`core/src/main/jniLibs/`（约 20 MB）和 `core/src/main/assets/thinktin-licenses/`
是生成物，不提交。UniFFI 0.32 给错误里名叫 `message` 的字段生成的代码过不了 Kotlin 2 的编译，
`scripts/patch-bindings.py` 会自动修，见该文件开头的说明。

## 构建与测试

```bash
cd apps/android
export ANDROID_HOME=/opt/android-sdk
# CoreSmokeTest 经 JNA 真调本机的 libclient_core.so（cargo build -p client-core 的输出）；不设就跳过
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
2 个实例、覆盖全部事件类型的运行、5 种收件箱条目、计划、key、保险箱……），不联网、不加载 Rust 库。
设置页里可以关掉（仅 debug），关掉后走 `CoreThinktinService` → client-core → 服务端，未登录时显示登录流。
release 包默认关闭。

## CI

`.github/workflows/android.yml`（名为 Android）：改动 `apps/android/**`、`crates/client-core/**`、`crates/proto/**`、
`tools/client-core/**` 时触发。步骤：`sync-core.sh --check`（绑定一致，同时编出本机 .so）→
`./gradlew test lint assembleDebug`（lint 的 abortOnError 开着，不用 baseline）→ 上传 `app-cn-debug.apk`。
CI 里没有交叉编译，这个 APK **不含 jniLibs**，只能用演示模式（关掉演示模式会提示“无法加载核心库”）；
带 .so 的完整包用 `mobile.yml` 的 android job 产出 `target/android`，再 `sync-core.sh --from` 后打包。

## 约定

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
