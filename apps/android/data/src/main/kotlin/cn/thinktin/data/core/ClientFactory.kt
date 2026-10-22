package cn.thinktin.data.core

import android.content.Context
import android.os.Build
import cn.thinktin.core.ClientConfig
import cn.thinktin.core.SessionStore
import cn.thinktin.core.ThinktinClient
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.data.session.SecureSessionStore
import java.io.File

/** 按设计规范第 8.3 节构造 client-core 的 [ThinktinClient]。对外只暴露 [createService]。 */
object ClientFactory {
    const val PLATFORM: String = "android"
    const val CACHE_FILE: String = "thinktin.db"
    const val TIMEOUT_SECS: UInt = 30u

    /** 设备名默认用 Build.MODEL（显示在设备管理里，用户可改）。 */
    fun defaultDeviceName(): String = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"

    internal fun config(
        filesDir: File,
        baseUrl: String,
        deviceName: String = defaultDeviceName(),
        acceptLanguage: String? = null,
    ): ClientConfig =
        ClientConfig(
            baseUrl = baseUrl,
            cachePath = File(filesDir, CACHE_FILE).absolutePath,
            platform = PLATFORM,
            deviceName = deviceName,
            timeoutSecs = TIMEOUT_SECS,
            acceptLanguage = acceptLanguage,
        )

    /** 会加载 libclient_core.so（JNA）、打开 SQLite、读 Keystore：放在后台线程调用；演示模式不要调用。 */
    internal fun create(
        context: Context,
        baseUrl: String,
        languageTags: List<String>,
        deviceName: String = defaultDeviceName(),
        sessions: SessionStore = SecureSessionStore(context),
    ): ThinktinClient = ThinktinClient(
        config(context.filesDir, baseUrl, deviceName, AcceptLanguage.header(languageTags)),
        sessions,
    )

    /** https 的地址要先初始化系统证书校验（[TlsState]）；没有时抛 [ServiceError.TlsUnavailable]。 */
    internal fun checkTls(baseUrl: String, tls: TlsState) {
        if (baseUrl.trimStart().startsWith("https://", ignoreCase = true) && !tls.ready) {
            throw ServiceError.TlsUnavailable(tls.failure)
        }
    }

    /**
     * 真实服务（client-core）。可能抛异常（https 但 [tls] 没初始化、安装包里没有 .so、绑定与库的契约版本不一致、
     * 缓存打不开……），调用方要在后台线程调用并兜住（见 :app 的 AppContainer）。
     * [languageTags] 是请求头 Accept-Language 的语言列表（null 用系统的语言列表，见 [AcceptLanguage.tags]）；
     * 之后切换语言调 [ThinktinService.setAcceptLanguage]。
     */
    fun createService(
        context: Context,
        baseUrl: String,
        tls: TlsState,
        languageTags: List<String>? = null,
    ): ThinktinService {
        checkTls(baseUrl, tls)
        return CoreThinktinService(create(context, baseUrl, languageTags ?: AcceptLanguage.tags(appLanguage = null)))
    }
}
