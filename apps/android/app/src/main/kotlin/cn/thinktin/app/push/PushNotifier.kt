package cn.thinktin.app.push

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import cn.thinktin.app.MainActivity
import cn.thinktin.app.R
import cn.thinktin.app.ThinktinApp
import cn.thinktin.data.model.InboxKind

/**
 * 自己发系统通知：FCM 在 App 前台时不显示通知、只回调 `onMessageReceived`，由这里照推送的标题、正文发一条
 * （后台时系统按推送里的 `notification` 和渠道 id 自己显示）。点开回到 [MainActivity]，Intent 带深链和 `tt_*`
 * （[PushMessage.toExtras]），和系统发的通知走同一条路。同一条收件箱通知只占一个位置（新的替换旧的）。
 */
object PushNotifier {
    /** 没有通知权限（Android 13 起要用户允许）时什么都不做，返回 false。 */
    fun show(context: Context, title: String, body: String, message: PushMessage): Boolean {
        if (!hasNotificationPermission(context)) return false
        val intent = openIntent(context, message)
        val requestCode = message.inboxId?.hashCode() ?: message.hashCode()
        val pending = PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, message.channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(
                if (message.kind.waitsForUser) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT,
            )
            .setCategory(
                if (message.kind.waitsForUser) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_STATUS,
            )
            .setAutoCancel(true)
            .setContentIntent(pending)
            .apply {
                val approval = message.approvalId
                val user = (context.applicationContext as? ThinktinApp)?.container?.push?.notificationAccountId
                if (message.kind == InboxKind.Approval && approval != null && user != null) {
                    val reject = ApprovalRejectReceiver.pendingIntent(context, user, approval, message.inboxId ?: TAG, requestCode, message.inboxId)
                    addAction(0, context.getString(R.string.notification_reject_once), reject)
                }
            }
            .build()
        return try {
            NotificationManagerCompat.from(context).notify(message.inboxId ?: TAG, requestCode, notification)
            true
        } catch (_: SecurityException) {
            false
        }
    }

    /** 点开通知打开的 Intent：深链（主界面按它跳）加 `tt_*`（标已读）。 */
    fun openIntent(context: Context, message: PushMessage): Intent =
        Intent(Intent.ACTION_VIEW, message.deepLink(), context, MainActivity::class.java)
            .putExtras(message.toExtras())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    /** 退出登录时清掉通知栏里的（推送里没有用户 id，不能留着上一个账号的）。 */
    fun cancelAll(context: Context) {
        NotificationManagerCompat.from(context).cancelAll()
    }

    private const val TAG = "thinktin"
}
