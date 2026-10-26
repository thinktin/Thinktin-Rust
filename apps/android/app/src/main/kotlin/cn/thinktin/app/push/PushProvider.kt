package cn.thinktin.app.push

import android.content.Context

/**
 * 推送 SDK（13.8，按发行渠道分：`cn` 极光、`global` FCM，各渠道的源码目录里有一个 [FlavorPush]）。
 *
 * 没配 SDK 的 key（[configured] 为假：开发包、测试、还没注册应用时）就不接推送，收件箱照样能用。
 * 用户同意隐私政策（登录）之前不初始化 SDK（[prepare] 先关掉 SDK 的信息收集，[start] 在登录后调）。
 */
interface PushProvider {
    /** 报给服务端的推送通道（`PushChannelKind`）：极光 `unipush`、FCM `fcm`。 */
    val channel: String

    /** 这个构建配了 SDK 的 key。 */
    val configured: Boolean

    /** 隐私清单里要披露的这个 SDK（13.11，设置 → 个人信息与权限）；没接 SDK 时为 null。 */
    val disclosure: cn.thinktin.app.ui.privacy.ThirdPartySdk? get() = null

    /** Application.onCreate：用户同意之前不让 SDK 收集信息。 */
    fun prepare(context: Context)

    /** 登录后：初始化 SDK，拿到令牌（之后令牌变了也一样）交给 [onToken]。 */
    fun start(context: Context, onToken: (String) -> Unit)
}
