// ThinkTin Android 工程（WBS 13.x），模块划分见 docs/android-design.md 第 1 节。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // rustls-platform-verifier 的 Android 支持包（org.rustls:rustls-platform-verifier，见 core/build.gradle.kts）
        // 不在 Maven Central，在 rustls 仓库的 maven-archive 分支上。用 raw.githubusercontent.com：
        // github.com/…/raw/… 的写法要多跳一次重定向，部分代理下是 403。
        maven {
            name = "rustlsPlatformVerifier"
            url = uri("https://raw.githubusercontent.com/rustls/rustls-platform-verifier/maven-archive/android-release-support/maven/")
            content { includeGroup("org.rustls") }
        }
    }
}

rootProject.name = "thinktin-android"

include(":app", ":core", ":design", ":data")
