// :core —— client-core（Rust）的 UniFFI Kotlin 绑定和各 ABI 的 .so。见 core/README.md。
import org.gradle.api.artifacts.result.ResolvedDependencyResult
import org.gradle.process.CommandLineArgumentProvider

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

/**
 * 从 Cargo.lock 读一个 crate 的版本（rustls-platform-verifier 的 README 推荐的做法，对配置缓存友好）。
 * 找不到时构建直接失败：版本对不上的话运行时才会在 JNI 调用处崩溃。
 */
abstract class CargoLockVersion : ValueSource<String, CargoLockVersion.Params> {
    interface Params : ValueSourceParameters {
        val lockFile: RegularFileProperty
        val crate: Property<String>
    }

    override fun obtain(): String {
        val crate = parameters.crate.get()
        val lines = parameters.lockFile.get().asFile.readLines()
        // Cargo.lock 里每个包是一个 [[package]] 段，name 之后紧跟 version。
        val nameIdx = lines.indexOfFirst { it.trim() == "name = \"$crate\"" }
        val version = if (nameIdx < 0) {
            null
        } else {
            lines.drop(nameIdx + 1)
                .takeWhile { it.isNotBlank() && !it.startsWith("[[") }
                .firstOrNull { it.trimStart().startsWith("version = ") }
                ?.substringAfter('"', "")
                ?.substringBefore('"', "")
                ?.takeIf { it.isNotEmpty() }
        }
        return version ?: error("Cargo.lock 里找不到 $crate（${parameters.lockFile.get().asFile}）")
    }
}

/** 仓库根目录的 Cargo.lock（相对 apps/android 是 ../../Cargo.lock）。 */
val cargoLock: RegularFile = rootProject.layout.projectDirectory.file("../../Cargo.lock")

/** Kotlin 支持包的版本必须和 Rust 那边 rustls-platform-verifier-android 的版本完全一致。 */
val rustlsVerifierVersion: Provider<String> = providers.of(CargoLockVersion::class.java) {
    parameters.lockFile.set(cargoLock)
    parameters.crate.set("rustls-platform-verifier-android")
}

android {
    namespace = "cn.thinktin.core"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.all { test ->
            // CoreSmokeTest 经 JNA 加载本机编出的 libclient_core.so（cargo build -p client-core 的 target/debug）。
            val libDir = System.getenv("THINKTIN_CORE_LIB_DIR")?.takeIf { it.isNotBlank() }
            if (libDir != null) {
                test.systemProperty("jna.library.path", libDir)
                // 库文件的内容也是测试的输入（开着构建缓存）：Rust 改了而绑定没变时，不能直接取缓存的测试结果。
                test.inputs.files(File(libDir, "libclient_core.so"), File(libDir, "libclient_core.dylib"))
                    .withPathSensitivity(PathSensitivity.NONE)
                    .withPropertyName("clientCoreLib")
            }
            // CI 设 THINKTIN_REQUIRE_CORE=1：拿不到库目录时冒烟测试失败，不再跳过（同 ci.yml 的 THINKTIN_REQUIRE_DB）。
            test.systemProperty("thinktin.requireCore", System.getenv("THINKTIN_REQUIRE_CORE") == "1")

            // RustlsVerifierVersionTest：Gradle 声明的、实际解析到的支持包版本，和测试自己从 Cargo.lock 读的比对。
            test.inputs.file(cargoLock).withPathSensitivity(PathSensitivity.NONE).withPropertyName("cargoLock")
            test.systemProperty("thinktin.cargoLock", cargoLock.asFile.absolutePath)
            test.systemProperty("thinktin.verifier.declared", rustlsVerifierVersion.get())
            // testDebugUnitTest → debugUnitTestRuntimeClasspath
            val classpath = test.name.removePrefix("test").replaceFirstChar { it.lowercase() } + "RuntimeClasspath"
            val resolved: Provider<String> = configurations.named(classpath)
                .flatMap { it.incoming.resolutionResult.rootComponent }
                .map { root ->
                    root.dependencies.filterIsInstance<ResolvedDependencyResult>()
                        .mapNotNull { it.selected.moduleVersion }
                        .firstOrNull { it.group == "org.rustls" && it.name == "rustls-platform-verifier" }
                        ?.version ?: "missing"
                }
            test.jvmArgumentProviders.add(
                CommandLineArgumentProvider { listOf("-Dthinktin.verifier.resolved=${resolved.get()}") },
            )
        }
    }

    lint {
        abortOnError = true
        // 生成的绑定不归我们改。
        ignoreTestSources = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// JVM 单元测试用 JNA 的 jar（带桌面平台的 jnidispatch），App 里用 aar（带 Android 的）。
val jnaForTest: Configuration by configurations.creating

dependencies {
    // UniFFI 的 Kotlin 绑定经 JNA 调 Rust，async 函数是挂起函数。
    api(variantOf(libs.jna) { artifactType("aar") })
    api(libs.kotlinx.coroutines.core)
    // 系统证书校验的 Java 部分：Rust 经 JNI 调它（TlsInit.initialize 之后），版本锁死为 Cargo.lock 里的。
    implementation(libs.rustls.platform.verifier) {
        version { strictly(rustlsVerifierVersion.get()) }
        because("必须和 Cargo.lock 里 rustls-platform-verifier-android 的版本一致")
    }

    jnaForTest(libs.jna)
    testImplementation(files(jnaForTest))
    testImplementation(libs.junit)
}
