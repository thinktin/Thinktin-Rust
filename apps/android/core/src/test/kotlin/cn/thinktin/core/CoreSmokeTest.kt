package cn.thinktin.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * 经 JNA 真调本机编出的 libclient_core.so，确认提交的绑定和 Rust 库对得上（校验和、调用约定）。
 * 需要 THINKTIN_CORE_LIB_DIR（Gradle 转成系统属性 jna.library.path）。没有时跳过；
 * 设了 THINKTIN_REQUIRE_CORE=1（CI）时直接失败，免得配错了也是绿的。
 */
class CoreSmokeTest {
    @Before
    fun requireNativeLibrary() {
        val dir = System.getProperty("jna.library.path")
        if (dir.isNullOrBlank()) {
            if (System.getProperty("thinktin.requireCore") == "true") {
                fail("THINKTIN_REQUIRE_CORE=1，但没有设置 THINKTIN_CORE_LIB_DIR（libclient_core.so 所在目录）")
            }
            assumeTrue("未设置 THINKTIN_CORE_LIB_DIR，跳过 client-core 冒烟测试", false)
        }
    }

    @Test
    fun detectSecretsFindsPassword() {
        val hits = detectSecrets("password: hunter2hunter2")
        assertTrue("应该认出密码：$hits", hits.isNotEmpty())
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

    @Test
    fun acceptLanguageHeaderWeightsLaterTags() {
        val header = acceptLanguageHeader(listOf("zh-CN", "en-US"))
        assertTrue("首选语言在前：$header", header.startsWith("zh-CN"))
        assertTrue("后面的带权重：$header", header.contains("en-US;q="))
    }

    @Test
    fun initLoggingAcceptsSink() {
        // initLogging 装的是进程级的订阅者：整个测试 JVM 里只在这里调一次。
        val records = java.util.Collections.synchronizedList(mutableListOf<LogRecord>())
        val sink = object : LogSink {
            override fun log(record: LogRecord) {
                records.add(record)
            }
        }
        // 返回值表示是否装上（进程里已有别的订阅者时为 false），这里只确认经 JNA 调得通、不崩。
        initLogging(sink, LogLevel.DEBUG)
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
