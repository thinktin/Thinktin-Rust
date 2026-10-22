package cn.thinktin.data.core

import android.content.Context
import cn.thinktin.core.TlsInit

/**
 * HTTPS 系统证书校验的初始化状态（见 :core 的 [TlsInit]）。Application.onCreate 里初始化一次，
 * [ClientFactory] 建客户端前查它：base_url 是 https 而没初始化时抛 [cn.thinktin.data.service.ServiceError.TlsUnavailable]，
 * 不让 Rust 那边报一个看不懂的内部错误。
 *
 * 是接口：JVM / Robolectric 测试里本机的 libclient_core.so 没有 JNI 函数，用 [FixedTlsState] 代替 [SystemTls]。
 */
interface TlsState {
    /** 已经初始化成功。 */
    val ready: Boolean

    /** 初始化失败的原因（成功或还没初始化时为 null）。 */
    val failure: Throwable?
}

/** 固定的状态（测试、演示）。 */
class FixedTlsState(override val ready: Boolean, override val failure: Throwable? = null) : TlsState

/**
 * 经 JNI 初始化系统证书校验。[initializer] 默认调 [TlsInit.initialize]（会 System.loadLibrary("client_core")）；
 * 失败（安装包里没有 .so、JNI 抛异常）不崩溃，记在 [failure] 里，等真正要建 https 客户端时再报。
 */
class SystemTls(
    private val initializer: (Context) -> Unit = { TlsInit.initialize(it) },
) : TlsState {
    @Volatile
    override var ready: Boolean = false
        private set

    @Volatile
    override var failure: Throwable? = null
        private set

    /** 初始化（只做一次，成功后再调直接返回）。返回是否成功。 */
    @Synchronized
    fun initialize(context: Context): Boolean {
        if (ready) return true
        try {
            initializer(context.applicationContext ?: context)
            ready = true
            failure = null
        } catch (e: Throwable) {
            // 有意兜住 Error：没有 .so 时是 UnsatisfiedLinkError，类初始化失败是 ExceptionInInitializerError。
            failure = e
        }
        return ready
    }
}
