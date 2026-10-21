// :core —— client-core（Rust）的 UniFFI Kotlin 绑定和各 ABI 的 .so。见 core/README.md。
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
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
            System.getenv("THINKTIN_CORE_LIB_DIR")?.let { test.systemProperty("jna.library.path", it) }
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

    jnaForTest(libs.jna)
    testImplementation(files(jnaForTest))
    testImplementation(libs.junit)
}
