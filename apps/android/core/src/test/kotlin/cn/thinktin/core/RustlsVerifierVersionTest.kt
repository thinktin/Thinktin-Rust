package cn.thinktin.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/**
 * 系统证书校验的 Kotlin 支持包（org.rustls:rustls-platform-verifier）必须和 Rust 那边
 * rustls-platform-verifier-android 的版本完全一致，否则运行时在 JNI 调用处崩溃。
 *
 * core/build.gradle.kts 用 ValueSource 从 Cargo.lock 读版本；这里用独立写的解析器再读一遍，
 * 和 Gradle 声明的（`thinktin.verifier.declared`）、实际解析到的（`thinktin.verifier.resolved`）比对，
 * 再确认支持包的类真的在类路径上（依赖没被丢掉）。
 */
class RustlsVerifierVersionTest {

    private fun property(name: String): String =
        System.getProperty(name) ?: throw AssertionError("Gradle 没有传系统属性 $name（见 core/build.gradle.kts）")

    @Test
    fun gradleUsesTheVersionFromCargoLock() {
        val lock = File(property("thinktin.cargoLock"))
        val expected = CargoLock.version(lock.readText(), "rustls-platform-verifier-android")
        assertNotNull("Cargo.lock 里没有 rustls-platform-verifier-android", expected)
        assertEquals("Gradle 声明的版本", expected, property("thinktin.verifier.declared"))
        assertEquals("Gradle 解析到的版本", expected, property("thinktin.verifier.resolved"))
    }

    @Test
    fun supportClassesAreOnTheClasspath() {
        // Rust 侧（rustls-platform-verifier 的 android 模块）经 JNI 找的就是这个类。
        // 不初始化（静态初始化会碰 Android API，JVM 测试里只有桩）。
        Class.forName("org.rustls.platformverifier.CertificateVerifier", false, javaClass.classLoader)
    }

    @Test
    fun parserReadsTheVersionOfTheNamedPackageOnly() {
        val text = """
            version = 4

            [[package]]
            name = "rustls-platform-verifier"
            version = "0.7.1"
            source = "registry+https://github.com/rust-lang/crates.io-index"

            [[package]]
            name = "rustls-platform-verifier-android"
            version = "0.2.0"
            source = "registry+https://github.com/rust-lang/crates.io-index"
        """.trimIndent()
        assertEquals("0.2.0", CargoLock.version(text, "rustls-platform-verifier-android"))
        assertEquals("0.7.1", CargoLock.version(text, "rustls-platform-verifier"))
        assertNull(CargoLock.version(text, "rustls"))
    }

    /** 按 TOML 的 [[package]] 段解析（和构建脚本里的实现互相独立）。 */
    private object CargoLock {
        fun version(text: String, crate: String): String? =
            text.split("[[package]]").drop(1).firstNotNullOfOrNull { block ->
                val fields = block.lines().mapNotNull { line ->
                    val eq = line.indexOf('=')
                    if (eq < 0) null else line.substring(0, eq).trim() to line.substring(eq + 1).trim().trim('"')
                }.toMap()
                fields["version"]?.takeIf { fields["name"] == crate }
            }
    }
}
