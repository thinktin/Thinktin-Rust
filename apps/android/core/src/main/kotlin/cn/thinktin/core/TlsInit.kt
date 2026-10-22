package cn.thinktin.core

import android.content.Context

/**
 * Android 上 HTTPS 的系统证书校验（client-core 的 `rustls-platform-verifier`，见 crates/client-core/src/tls.rs）
 * 要经 JNI 调系统的 `X509TrustManager`，所以 App 在建 [ThinktinClient] 之前要先调 [initialize]；
 * 没调的话 https 的 base_url 建客户端时 Rust 那边直接报错。
 *
 * 手写的（不是 UniFFI 生成的）：对应 Rust 导出的 `Java_cn_thinktin_core_TlsInit_initialize`。
 * `System.loadLibrary` 必须有：JNA 用 dlopen 加载库，不会注册 JNI 函数，`external` 方法要靠它才找得到。
 *
 * 只在真机 / 模拟器上调用。JVM 单元测试里本机编的 libclient_core.so 是 Linux 版，没有这个 JNI 函数，
 * 测试经 :data 的 `TlsState` 接口用假实现隔离。
 */
object TlsInit {
    init {
        System.loadLibrary("client_core")
    }

    /** 把 App 的 Context 交给系统证书校验（只用第一次的，重复调用无害）。失败时抛 RuntimeException。 */
    @JvmStatic
    external fun initialize(context: Context)
}
