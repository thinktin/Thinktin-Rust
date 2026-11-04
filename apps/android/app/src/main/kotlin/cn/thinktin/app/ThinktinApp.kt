package cn.thinktin.app

import android.app.Application
import android.content.res.Configuration
import android.util.Log
import cn.thinktin.app.push.FlavorPush
import cn.thinktin.app.push.NotificationChannels
import cn.thinktin.data.core.CoreLogging
import cn.thinktin.data.core.SystemTls
import cn.thinktin.data.core.TlsState

/**
 * Application：先把 client-core 的日志接到 logcat（[initializeLogging]），再初始化 HTTPS 的系统证书校验
 * （[TlsState]，必须在建 ThinktinClient 之前），最后建 [AppContainer]。
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
        initializeLogging()
        tlsState = initializeTls()
        container = createContainer()
        // 进程重建后没有运行中的订阅，只收回上一进程留下的进度通知。
        val notifications = getSystemService(android.app.NotificationManager::class.java)
        notifications.activeNotifications.filter { it.tag == cn.thinktin.app.progress.SystemProgressNotifier.TAG }.forEach {
            notifications.cancel(it.tag, it.id)
        }
        // 通知渠道（13.8）：推送里带着渠道 id，收到推送之前就要有。
        NotificationChannels.ensure(this)
        // 推送 SDK：登录（同意隐私政策）之前不收集信息、不注册（见 AppRoot 的 PushSync）。
        FlavorPush.prepare(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 系统语言可能变了：Accept-Language 跟着变，通知渠道的名字也跟着变。
        if (::container.isInitialized) container.onSystemLocalesChanged()
        NotificationChannels.ensure(this)
    }

    /**
     * client-core 的日志进 logcat：debug 包到 Debug 级别，release 只要 Warn 以上。会加载 libclient_core.so；
     * 失败（安装包里没有 .so）不崩溃，真实服务创建时再报。
     */
    protected open fun initializeLogging() {
        try {
            CoreLogging.install(verbose = BuildConfig.DEBUG)
        } catch (e: Throwable) {
            // 有意兜住 Error：没有 .so 时是 UnsatisfiedLinkError。
            Log.w(TAG, "client-core 日志接入失败", e)
        }
    }

    /**
     * 经 JNI 初始化系统证书校验（:core 的 TlsInit，会加载 libclient_core.so）。失败不崩溃：原因记在 [TlsState.failure]，
     * 演示模式照常可用，真实服务创建时报“无法加载核心库”（见 ClientFactory.createService）。
     */
    protected open fun initializeTls(): TlsState = SystemTls().also { it.initialize(applicationContext) }

    protected open fun createContainer(): AppContainer = AppContainer.create(this, tls = tlsState)

    private companion object {
        const val TAG = "ThinktinApp"
    }
}
