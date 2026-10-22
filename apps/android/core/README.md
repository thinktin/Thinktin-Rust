# :core —— client-core 绑定

`src/main/kotlin/cn/thinktin/core/client_core.kt` 是 `tools/client-core/gen-bindings.sh` 由 `crates/client-core`
生成的 UniFFI Kotlin 绑定（包 `cn.thinktin.core`），**不要手改**。Rust 接口变了就重新生成并提交：

```bash
apps/android/scripts/sync-core.sh --bindings-only   # 只更新 .kt（只需要 cargo）
apps/android/scripts/sync-core.sh --check           # 只检查提交的 .kt 和 Rust 是否一致（CI 跑这个）
```

`src/main/jniLibs/<abi>/libclient_core.so`（arm64-v8a、armeabi-v7a、x86_64）和
`src/main/assets/thinktin-licenses/`（依赖 crate 的许可证清单与原文，“开源许可”页面读它）是生成物，
不提交（见 `apps/android/.gitignore`），由脚本复制进来：

```bash
apps/android/scripts/sync-core.sh --from target/android # 已经有 build-android.sh 的输出时直接同步（本机推荐）
apps/android/scripts/sync-core.sh                      # 交叉编译（NDK + cargo-ndk）后同步（跳过 build-android.sh 的 AAR）
```

没有 .so 也能编译和跑 JVM 单元测试，只是装到手机上调用 Rust 会因找不到库而崩溃（演示模式不调 Rust）。

`consumer-rules.pro` 让依赖本模块的 App 在 release 混淆时保留 `cn.thinktin.core.**` 与 `com.sun.jna.**`（JNA 靠反射）。

`src/test` 里的 `CoreSmokeTest` 用 JNA 加载本机的 `libclient_core.so`：Gradle 把环境变量
`THINKTIN_CORE_LIB_DIR`（如 `$REPO/target/debug`，`cargo build -p client-core` 的输出）作为
`jna.library.path` 传给测试，并把库文件声明为测试任务的输入（开着构建缓存，Rust 改了要重跑）；没设置时跳过，
同时设了 `THINKTIN_REQUIRE_CORE=1`（CI）时失败。
