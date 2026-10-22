// :app —— ThinkTin Android App（单 Activity + Navigation Compose），见 docs/android-design.md。
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

/** 后端地址：-PthinktinBaseUrl=... 或 gradle.properties。 */
val thinktinBaseUrl: String =
    providers.gradleProperty("thinktinBaseUrl").getOrElse("https://api.thinktin.cn")

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
        // 只打 client-core 有 .so 的三个 ABI（JNA 自带的 x86、mips 等目录里没有 libclient_core.so）。
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    // 推送 SDK 按发行渠道分：cn（极光推送）、global（FCM）。13.8 再接 SDK，这里先只有 BuildConfig.DIST。
    flavorDimensions += "dist"
    productFlavors {
        create("cn") {
            dimension = "dist"
            buildConfigField("String", "DIST", "\"cn\"")
        }
        create("global") {
            dimension = "dist"
            buildConfigField("String", "DIST", "\"global\"")
        }
    }

    buildTypes {
        debug {
            // debug 默认进演示模式（Mock 数据，不联网），设置里可以关掉。
            buildConfigField("boolean", "DEMO_DEFAULT", "true")
        }
        release {
            buildConfigField("boolean", "DEMO_DEFAULT", "false")
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
        // 纯逻辑测试（ViewModel 等）用 JUnit 5；Robolectric / Compose 测试是 JUnit 4 写法，经 vintage 引擎跑。
        unitTests.all { it.useJUnitPlatform() }
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

// 单元测试（含 Robolectric 界面测试）只跑 cnDebug：两个渠道的代码相同，release 没有 ui-test-manifest。
androidComponents {
    beforeVariants { variant ->
        if (variant.buildType == "release" || variant.productFlavors.any { it.second == "global" }) {
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
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.junit4)
    testRuntimeOnly(libs.junit.vintage.engine)
    testRuntimeOnly(libs.junit.platform.launcher)
    testImplementation(libs.robolectric)
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
}
