package cn.thinktin.core

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.fail
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

/**
 * 经 JNA 真调本机编出的 libclient_core.so，确认提交的绑定和 Rust 库对得上（校验和、调用约定）。
 * 需要 THINKTIN_CORE_LIB_DIR（Gradle 转成系统属性 jna.library.path）。没有时跳过；
 * 设了 THINKTIN_REQUIRE_CORE=1（CI）时直接失败，免得配错了也是绿的。
 */
class CoreSmokeTest {
    @BeforeEach
    fun requireNativeLibrary() {
        val dir = System.getProperty("jna.library.path")
        if (dir.isNullOrBlank()) {
            if (System.getProperty("thinktin.requireCore") == "true") {
                fail<Unit>("THINKTIN_REQUIRE_CORE=1，但没有设置 THINKTIN_CORE_LIB_DIR（libclient_core.so 所在目录）")
            }
            assumeTrue(false, "未设置 THINKTIN_CORE_LIB_DIR，跳过 client-core 冒烟测试")
        }
    }

    @Test
    fun detectSecretsFindsPassword() {
        val hits = detectSecrets("password: hunter2hunter2")
        assertTrue(hits.isNotEmpty(), "应该认出密码：$hits")
        assertTrue(hits.any { it.value.contains("hunter2hunter2") })
    }

    @Test
    fun newClientIsSignedOut() {
        val store = MemorySessionStore()
        val config = ClientConfig(
            baseUrl = "https://api.thinktin.cn",
            cachePath = null,
            platform = "android",
            deviceName = "JVM 测试",
            timeoutSecs = 5u,
        )
        ThinktinClient(config, store).use { client ->
            assertFalse(client.signedIn())
        }
    }

    private class MemorySessionStore : SessionStore {
        @Volatile
        private var session: Session? = null

        override fun load(): Session? = session

        override fun save(session: Session?) {
            this.session = session
        }
    }
}
