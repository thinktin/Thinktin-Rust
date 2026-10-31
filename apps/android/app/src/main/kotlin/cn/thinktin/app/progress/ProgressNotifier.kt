package cn.thinktin.app.progress

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import cn.thinktin.app.MainActivity
import cn.thinktin.app.ThinktinApp
import cn.thinktin.app.R
import cn.thinktin.app.push.NotificationChannels
import cn.thinktin.app.push.hasNotificationPermission
import cn.thinktin.app.ui.common.WaitText
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.data.model.RunState

/** 发、更新、撤掉常驻通知（测试里换成记录）。 */
interface ProgressNotifier {
    /** 没有通知权限时什么都不做，返回 false。 */
    fun show(progress: RunProgress): Boolean

    fun cancel(runId: String)
}

/** 什么都不发（测试里默认用它）。 */
object NoProgressNotifier : ProgressNotifier {
    override fun show(progress: RunProgress): Boolean = false

    override fun cancel(runId: String) = Unit
}

/**
 * 系统通知：渠道 `tt_progress`（低优先级、不响不震），常驻（Android 14 起用户可以划掉），只提醒一次；计时器从开始时间算
 * （进程被系统回收、不再更新时，耗时照样走）；8 小时后系统自动撤掉（和服务端运行的上限一样，免得留下过期的）。
 * 锁屏上只显示“ThinkTin 有任务在进行”。点开去运行页（深链 `thinktin://run/{id}`）。
 */
class SystemProgressNotifier(private val context: Context) : ProgressNotifier {
    override fun show(progress: RunProgress): Boolean {
        if (!hasNotificationPermission(context)) return false
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return false
        if (manager.getNotificationChannel(NotificationChannels.PROGRESS)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        return try {
            manager.notify(TAG, progress.runId.hashCode(), build(progress))
            true
        } catch (_: SecurityException) {
            // 刚好在检查之后被收回了权限。
            false
        }
    }

    override fun cancel(runId: String) {
        NotificationManagerCompat.from(context).cancel(TAG, runId.hashCode())
    }

    internal fun build(progress: RunProgress): android.app.Notification {
        val context = androidx.core.content.ContextCompat.getContextForLanguage(context)
        val state = context.getString(progress.state.labelRes())
        val wait = WaitText.of(progress.waitCode)?.let { context.getString(it.resId, *it.args.toTypedArray()) }
        val steps = context.resources.getQuantityString(R.plurals.progress_steps, progress.steps, progress.steps)
        val text = listOfNotNull(wait ?: state, steps.takeIf { progress.steps > 0 }).joinToString(" · ")
        val open = PendingIntent.getActivity(
            context,
            progress.runId.hashCode(),
            Intent(Intent.ACTION_VIEW, openRunUri(progress.runId), context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val locked = NotificationCompat.Builder(context, NotificationChannels.PROGRESS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.app_name))
            .setContentText(context.getString(R.string.progress_public))
            .build()
        val running = progress.state == RunState.Running || progress.state == RunState.Starting
        return NotificationCompat.Builder(context, NotificationChannels.PROGRESS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(progress.title)
            .setContentText(text)
            .setContentIntent(open)
            .setDeleteIntent(PendingIntent.getBroadcast(
                context, 0, Intent(context, ProgressDismissedReceiver::class.java).apply { data = openRunUri(progress.runId) },
                PendingIntent.FLAG_IMMUTABLE,
            ))
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(!progress.isFinished)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(progress.startedAtMs != null)
            .setUsesChronometer(progress.startedAtMs != null && !progress.isFinished)
            .apply { progress.startedAtMs?.let { setWhen(it) } }
            .setProgress(0, 0, running)
            .setTimeoutAfter(TIMEOUT_MS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(locked)
            .build()
    }

    companion object {
        const val TAG = "run_progress"

        /** 8 小时（服务端运行时长的上限）。 */
        const val TIMEOUT_MS = 8L * 60 * 60 * 1000
    }
}

private fun openRunUri(id: String): Uri = Uri.parse("thinktin://run/${Uri.encode(id)}")

class ProgressDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.data?.lastPathSegment ?: return
        (context.applicationContext as ThinktinApp).container.progress.stop(id)
    }
}
