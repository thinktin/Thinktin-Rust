package cn.thinktin.app.push

import android.content.Context

/**
 * global 渠道的推送：FCM（服务端 `[push.fcm]`），通道 `fcm`。SDK 还没接（要人定：SDK 的许可证和隐私合规、应用的 key，见
 * docs/progress/android-app.md 的“坑和决定”），先不接推送：收件箱、点开通知的跳转、令牌上报都在，接上 SDK 时只改
 * 这个文件、这个渠道的清单和依赖。
 */
object FlavorPush : PushProvider {
    override val channel = "fcm"

    override val configured: Boolean = false

    override fun prepare(context: Context) = Unit

    override fun start(context: Context, onToken: (String) -> Unit) = Unit
}
