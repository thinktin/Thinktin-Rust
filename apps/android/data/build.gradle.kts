// :data —— App 侧模型、ThinktinService 接口、client-core 适配（CoreThinktinService）与演示数据（MockThinktinService）。
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "cn.thinktin.data"
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
        // android.util.Log 等在 JVM 单元测试里返回默认值，不抛 “not mocked”。
        unitTests.isReturnDefaultValues = true
        unitTests.all { test ->
            // CorePairingCodecTest 经 JNA 真调 libclient_core.so（同 :core 的 CoreSmokeTest）。
            val libDir = System.getenv("THINKTIN_CORE_LIB_DIR")?.takeIf { it.isNotBlank() }
            if (libDir != null) {
                test.systemProperty("jna.library.path", libDir)
                test.inputs.files(File(libDir, "libclient_core.so"), File(libDir, "libclient_core.dylib"))
                    .withPathSensitivity(PathSensitivity.NONE)
                    .withPropertyName("clientCoreLib")
            }
            test.systemProperty("thinktin.requireCore", System.getenv("THINKTIN_REQUIRE_CORE") == "1")
        }
    }

    lint {
        abortOnError = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// JVM 单元测试用 JNA 的 jar（带桌面平台的 jnidispatch），同 :core。
val jnaForTest: Configuration by configurations.creating

dependencies {
    // :core（UniFFI 绑定）只在本模块内部用：对外只暴露 ThinktinService 和 App 模型。
    implementation(project(":core"))
    api(libs.kotlinx.coroutines.core)
    api(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.security.crypto)

    jnaForTest(libs.jna)
    testImplementation(files(jnaForTest))
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
}
