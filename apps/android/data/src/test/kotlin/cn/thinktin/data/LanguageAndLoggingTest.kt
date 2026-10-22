package cn.thinktin.data

import android.util.Log
import cn.thinktin.core.LogLevel
import cn.thinktin.core.LogRecord
import cn.thinktin.data.core.AcceptLanguage
import cn.thinktin.data.core.CoreLogging
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 11.8 的两处接入：Accept-Language 的语言列表、client-core 日志进 logcat。
 * 只测纯逻辑：拼请求头（accept_language_header）和 initLogging 要加载 .so，在真机 / CoreSmokeTest 里覆盖。
 */
class LanguageAndLoggingTest {
    @Test
    fun appLanguageGoesFirstThenSystemList() {
        assertEquals(
            listOf("en", "zh-Hans-CN", "fr-FR"),
            AcceptLanguage.merge("en", listOf("zh-Hans-CN", "en", "fr-FR")),
        )
        // 跟随系统：只有系统的列表。
        assertEquals(listOf("zh-CN", "en-US"), AcceptLanguage.merge(null, listOf("zh-CN", "en-US")))
    }

    @Test
    fun mergeDropsBlanksUndAndCaseInsensitiveDuplicates() {
        assertEquals(
            listOf("zh-CN", "en-US"),
            AcceptLanguage.merge("zh-CN", listOf(" zh-cn ", "", "und", "en-US", "EN-us")),
        )
        assertTrue(AcceptLanguage.merge(null, listOf("", "und")).isEmpty())
    }

    @Test
    fun emptyListMeansNoHeader() {
        assertNull(AcceptLanguage.header(emptyList()))
    }

    @Test
    fun logLevelsMapToLogcatPriorities() {
        assertEquals(Log.ERROR, CoreLogging.priority(LogLevel.ERROR))
        assertEquals(Log.WARN, CoreLogging.priority(LogLevel.WARN))
        assertEquals(Log.INFO, CoreLogging.priority(LogLevel.INFO))
        assertEquals(Log.DEBUG, CoreLogging.priority(LogLevel.DEBUG))
        assertEquals(Log.VERBOSE, CoreLogging.priority(LogLevel.TRACE))
    }

    @Test
    fun lineKeepsModuleAndMessage() {
        val record = LogRecord(LogLevel.WARN, "client_core::events", "stream reconnecting in 2s")
        assertEquals("client_core::events: stream reconnecting in 2s", CoreLogging.line(record))
        assertTrue("logcat 的 tag 不超过 23 个字符", CoreLogging.TAG.length <= 23)
    }
}
