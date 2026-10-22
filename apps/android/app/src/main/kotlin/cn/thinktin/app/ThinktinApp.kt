package cn.thinktin.app

import android.app.Application
import cn.thinktin.data.core.SystemTls
import cn.thinktin.data.core.TlsState

/**
 * Application：先初始化 HTTPS 的系统证书校验（[TlsState]，必须在建 ThinktinClient 之前），再建 [AppContainer]。
 * 容器本身很轻（真实服务第一次用到时才在后台创建，见 [AppContainer.coreService]）。
 * 测试覆盖 [initializeTls]（JVM 上没有 JNI 函数，不能真的初始化）和 [createContainer]，
 * 或在启动 Activity 之前换掉 [container]。
 */
open class ThinktinApp : Application() {
    lateinit var tlsState: TlsState
        internal set

    lateinit var container: AppContainer
        internal set

    override fun onCreate() {
        super.onCreate()
        tlsState = initializeTls()
        container = createContainer()
    }

    /**
     * 经 JNI 初始化系统证书校验（:core 的 TlsInit，会加载 libclient_core.so）。失败不崩溃：原因记在 [TlsState.failure]，
     * 演示模式照常可用，真实服务创建时报“无法加载核心库”（见 ClientFactory.createService）。
     */
    protected open fun initializeTls(): TlsState = SystemTls().also { it.initialize(applicationContext) }

    protected open fun createContainer(): AppContainer = AppContainer.create(this, tls = tlsState)
}
