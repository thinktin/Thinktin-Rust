// Robolectric 运行时需要的 android-all（Android 15，SDK 35）由 Gradle 解析：走工程的仓库和 Gradle 缓存，
// 测试时离线使用。不让 Robolectric 自己去 Maven Central 下载（CI、云端经常被限流 429）。
// 升级 Robolectric 时按它的 AndroidSdk 对照表一起改这个版本。
val androidAllInstrumented = "org.robolectric:android-all-instrumented:15-robolectric-12650502-i7"

val robolectricRuntime: Configuration = configurations.create("robolectricRuntime") {
    isTransitive = false
    isCanBeConsumed = false
}
dependencies.add(robolectricRuntime.name, androidAllInstrumented)

val robolectricDir = layout.buildDirectory.dir("robolectric-deps")
val prepareRobolectric = tasks.register<Sync>("prepareRobolectricDeps") {
    from(robolectricRuntime)
    into(robolectricDir)
}

tasks.withType<Test>().configureEach {
    dependsOn(prepareRobolectric)
    systemProperty("robolectric.offline", "true")
    systemProperty("robolectric.dependency.dir", robolectricDir.get().asFile.absolutePath)
}
