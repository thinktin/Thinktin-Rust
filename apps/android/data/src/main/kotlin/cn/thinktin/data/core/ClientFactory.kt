package cn.thinktin.data.core

import android.content.Context
import android.os.Build
import cn.thinktin.core.ClientConfig
import cn.thinktin.core.SessionStore
import cn.thinktin.core.ThinktinClient
import cn.thinktin.data.session.SecureSessionStore
import java.io.File

/** 按设计规范第 8.3 节构造 client-core 的 [ThinktinClient]。 */
object ClientFactory {
    const val PLATFORM: String = "android"
    const val CACHE_FILE: String = "thinktin.db"
    const val TIMEOUT_SECS: UInt = 30u

    /** 设备名默认用 Build.MODEL（显示在设备管理里，用户可改）。 */
    fun defaultDeviceName(): String = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"

    fun config(context: Context, baseUrl: String, deviceName: String = defaultDeviceName()): ClientConfig =
        ClientConfig(
            baseUrl = baseUrl,
            cachePath = File(context.filesDir, CACHE_FILE).absolutePath,
            platform = PLATFORM,
            deviceName = deviceName,
            timeoutSecs = TIMEOUT_SECS,
        )

    /** 会加载 libclient_core.so（JNA）；演示模式不要调用。 */
    fun create(
        context: Context,
        baseUrl: String,
        deviceName: String = defaultDeviceName(),
        sessions: SessionStore = SecureSessionStore(context),
    ): ThinktinClient = ThinktinClient(config(context, baseUrl, deviceName), sessions)

    fun createService(context: Context, baseUrl: String): CoreThinktinService =
        CoreThinktinService(create(context, baseUrl))
}
