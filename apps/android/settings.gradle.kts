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
    }
}

rootProject.name = "thinktin-android"

include(":app", ":core", ":design", ":data")
