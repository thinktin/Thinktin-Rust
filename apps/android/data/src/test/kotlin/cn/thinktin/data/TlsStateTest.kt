package cn.thinktin.data

import android.content.ContextWrapper
import cn.thinktin.data.core.ClientFactory
import cn.thinktin.data.core.FixedTlsState
import cn.thinktin.data.core.SystemTls
import cn.thinktin.data.service.ServiceError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * HTTPS 系统证书校验的初始化状态与 ClientFactory 的检查。JVM 上没有 TlsInit 的 JNI 函数：
 * 用假的初始化函数和 [FixedTlsState]，不碰真的 TlsInit。
 */
class TlsStateTest {
    // 单元测试的 android.jar 桩返回默认值：getApplicationContext() 是 null，SystemTls 退回传进来的 context。
    private val context = ContextWrapper(null)

    private fun expectTlsUnavailable(block: () -> Unit): ServiceError.TlsUnavailable {
        try {
            block()
        } catch (e: ServiceError.TlsUnavailable) {
            return e
        }
        fail("应该抛 TlsUnavailable")
        error("unreachable")
    }

    @Test
    fun httpsNeedsInitializedTls() {
        expectTlsUnavailable { ClientFactory.checkTls("https://api.thinktin.cn", FixedTlsState(ready = false)) }
        expectTlsUnavailable { ClientFactory.checkTls("  HTTPS://api.thinktin.cn", FixedTlsState(ready = false)) }
        ClientFactory.checkTls("https://api.thinktin.cn", FixedTlsState(ready = true))
        // 本地联调的 http 地址不经 TLS，不需要初始化。
        ClientFactory.checkTls("http://10.0.2.2:8080", FixedTlsState(ready = false))
    }

    @Test
    fun createServiceFailsBeforeTouchingTheNativeLibrary() {
        val cause = UnsatisfiedLinkError("dlopen failed: library \"libclient_core.so\" not found")
        val error = expectTlsUnavailable {
            ClientFactory.createService(context, "https://api.thinktin.cn", FixedTlsState(ready = false, failure = cause))
        }
        assertSame(cause, error.cause)
        assertTrue(error.message!!.contains("TlsInit.initialize"))
    }

    @Test
    fun systemTlsRecordsFailureWithoutThrowing() {
        val cause = UnsatisfiedLinkError("no client_core in java.library.path")
        val tls = SystemTls(initializer = { throw cause })
        assertFalse(tls.initialize(context))
        assertFalse(tls.ready)
        assertSame(cause, tls.failure)
        val error = expectTlsUnavailable { ClientFactory.checkTls("https://api.thinktin.cn", tls) }
        assertSame(cause, error.cause)
    }

    @Test
    fun systemTlsInitializesOnce() {
        var calls = 0
        val tls = SystemTls(initializer = { calls++ })
        assertFalse(tls.ready)
        assertTrue(tls.initialize(context))
        assertTrue(tls.initialize(context))
        assertEquals(1, calls)
        assertTrue(tls.ready)
        assertNull(tls.failure)
        ClientFactory.checkTls("https://api.thinktin.cn", tls)
    }

    @Test
    fun retryAfterFailureCanSucceed() {
        var fail = true
        val tls = SystemTls(initializer = { if (fail) throw RuntimeException("jni") })
        assertFalse(tls.initialize(context))
        fail = false
        assertTrue(tls.initialize(context))
        assertNull(tls.failure)
    }
}
