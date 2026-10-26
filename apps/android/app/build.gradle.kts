// :app —— ThinkTin Android App（单 Activity + Navigation Compose），见 docs/android-design.md。
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

/** 后端地址：-PthinktinBaseUrl=... 或 gradle.properties。 */
val thinktinBaseUrl: String =
    providers.gradleProperty("thinktinBaseUrl").getOrElse("https://api.thinktin.cn")

/** 官网安装包的更新清单（13.12，docs/android-release.md 第 3 节）：-PthinktinUpdateUrl=... 或 gradle.properties。 */
val thinktinUpdateUrl: String =
    providers.gradleProperty("thinktinUpdateUrl").getOrElse("https://thinktin.cn/download/android/latest.json")

/**
 * 正式签名（docs/android-release.md 第 4 节）：密钥库不进仓库，发版机器上设这四个环境变量；没设时 release 包不签名
 * （CI 只检查能打包）。所有渠道用同一把签名密钥：官网包和商店包能互相覆盖安装，应用内更新也靠它校验。
 */
val releaseKeystore: String? = providers.environmentVariable("THINKTIN_KEYSTORE").orNull

android {
    namespace = "cn.thinktin.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "cn.thinktin.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "BASE_URL", "\"$thinktinBaseUrl\"")
        buildConfigField("String", "UPDATE_MANIFEST_URL", "\"$thinktinUpdateUrl\"")
        // 只打 client-core 有 .so 的三个 ABI（JNA 自带的 x86、mips 等目录里没有 libclient_core.so）。
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    // 发行渠道：cn（国内应用商店，极光推送）、direct（官网安装包，推送同 cn，能在 App 里更新，13.12）、global（Google Play，
    // FCM）。推送 SDK 还没接（13.8，要人定）。只有 direct 能自己装更新：应用商店不允许绕过商店更新。
    flavorDimensions += "dist"
    productFlavors {
        create("cn") {
            dimension = "dist"
            buildConfigField("String", "DIST", "\"cn\"")
            buildConfigField("boolean", "SELF_UPDATE", "false")
        }
        create("direct") {
            dimension = "dist"
            buildConfigField("String", "DIST", "\"direct\"")
            buildConfigField("boolean", "SELF_UPDATE", "true")
        }
        create("global") {
            dimension = "dist"
            buildConfigField("String", "DIST", "\"global\"")
            buildConfigField("boolean", "SELF_UPDATE", "false")
        }
    }

    sourceSets {
        // 官网包的推送和国内商店包一样（极光）：共用 cn 的 FlavorPush。
        getByName("direct") { kotlin.srcDir("src/cn/kotlin") }
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = providers.environmentVariable("THINKTIN_KEYSTORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("THINKTIN_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("THINKTIN_KEY_PASSWORD").get()
            }
        }
    }

    buildTypes {
        debug {
            // debug 默认进演示模式（Mock 数据，不联网），设置里可以关掉。
            buildConfigField("boolean", "DEMO_DEFAULT", "true")
        }
        release {
            buildConfigField("boolean", "DEMO_DEFAULT", "false")
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    lint {
        abortOnError = true
        checkDependencies = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

apply(from = rootProject.file("gradle/robolectric.gradle.kts"))

// 单元测试（含 Robolectric 界面测试）只跑 cnDebug：各渠道只有推送、更新的开关不同（更新的逻辑在 main 里，测试照样覆盖），
// release 没有 ui-test-manifest。
androidComponents {
    beforeVariants { variant ->
        if (variant.buildType == "release" || variant.productFlavors.any { it.second != "cn" }) {
            variant.enableUnitTest = false
        }
    }
}

dependencies {
    implementation(project(":data"))
    implementation(project(":design"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.biometric)
    implementation(libs.kotlinx.coroutines.android)

    val composeBom = platform(libs.compose.bom)
    implementation(composeBom)
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    testImplementation(composeBom)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
}
