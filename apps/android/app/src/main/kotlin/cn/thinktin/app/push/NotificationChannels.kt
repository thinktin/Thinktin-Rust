package cn.thinktin.app.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import cn.thinktin.app.R

/**
 * 通知渠道（docs/push.md 第 2 节）：id 和服务端一致（`[push.fcm]` / `[push.jpush]` 的 `approval_channel`、
 * `default_channel`，默认 `tt_approval`、`tt_results`），推送里带着渠道 id，系统按它显示。
 * Application 启动时建（已经有的只更新名字，用户改过的重要程度不动）；语言换了重建一次名字跟着变。
 */
object NotificationChannels {
    /** 审批、电脑审批、保险箱请求：高优先级，有声音、横幅。 */
    const val APPROVAL = "tt_approval"

    /** 运行完成、失败、计划待确认、其他提醒。 */
    const val RESULTS = "tt_results"

    /** 运行进度的常驻通知（13.10，本地发的，服务端不用）：低优先级，不响不震。 */
    const val PROGRESS = "tt_progress"

    fun ensure(app: Context) {
        val context = androidx.core.content.ContextCompat.getContextForLanguage(app)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(
                    APPROVAL,
                    context.getString(R.string.notification_channel_approvals),
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply { description = context.getString(R.string.notification_channel_approvals_description) },
                NotificationChannel(
                    RESULTS,
                    context.getString(R.string.notification_channel_results),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = context.getString(R.string.notification_channel_results_description) },
                NotificationChannel(
                    PROGRESS,
                    context.getString(R.string.notification_channel_progress),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = context.getString(R.string.notification_channel_progress_description) },
            ),
        )
    }
}
