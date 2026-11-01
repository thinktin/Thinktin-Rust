package cn.thinktin.app.push

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationManagerCompat
import cn.thinktin.app.ServiceState
import cn.thinktin.app.ThinktinApp
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/** 只处理本应用为前台通知签发的不可变 PendingIntent，每次向服务端核实当前账号、审批和可选动作。 */
class ApprovalRejectReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? ThinktinApp ?: return
        if (intent.action != ACTION) return
        val uri = intent.data ?: return
        if (uri.scheme != "thinktin-action" || uri.host != "reject" || uri.pathSegments.size != 4) return
        val (accountId, approvalId, tag, notification) = uri.pathSegments
        val id = notification.toIntOrNull() ?: return
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                // 超时或断网时保留通知；再点会先核对是否已处理。
                withTimeoutOrNull(8_000) {
                    val container = app.container
                    val settings = container.settings.first()
                    if (!settings.privacyAccepted || settings.demoMode) return@withTimeoutOrNull
                    val ready = container.coreService().first { it !is ServiceState.Loading } as? ServiceState.Ready
                        ?: return@withTimeoutOrNull
                    val handled = decide(ready.service, accountId, approvalId, intent.getStringExtra(INBOX), container.clock.millis())
                    if (handled) NotificationManagerCompat.from(app).cancel(tag, id)
                }
            } catch (_: ServiceError) {
                // 暂态失败交给下一次点击重试，不更改本地审批状态。
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        private const val ACTION = "cn.thinktin.app.action.REJECT_APPROVAL_ONCE"
        private const val INBOX = "inbox_id"
        private val decisions = Mutex()

        internal fun pendingIntent(context: Context, user: String, approval: String, tag: String, id: Int, inbox: String?): PendingIntent {
            val uri = Uri.Builder().scheme("thinktin-action").authority("reject").appendPath(user).appendPath(approval)
                .appendPath(tag).appendPath(id.toString()).build()
            val intent = Intent(context, ApprovalRejectReceiver::class.java).setAction(ACTION).setData(uri).putExtra(INBOX, inbox)
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        internal suspend fun decide(service: ThinktinService, userId: String, approvalId: String, inboxId: String?, nowMs: Long): Boolean =
            decisions.withLock {
                if (service.authState.value != AuthState.SignedIn || service.me().id != userId) return@withLock false
                val approval = try {
                    service.getApproval(approvalId)
                } catch (e: ServiceError.Api) {
                    if (e.status == 404) return@withLock true
                    throw e
                }
                if (approval.id != approvalId) return@withLock false
                if (approval.state == ApprovalState.Pending && approval.expiresAtMs > nowMs) {
                    val option = approval.options.firstOrNull { it.kind == OptionKind.RejectOnce } ?: return@withLock false
                    if (service.authState.value != AuthState.SignedIn || service.me().id != userId) return@withLock false
                    try {
                        service.decideApproval(approvalId, option.optionId)
                    } catch (e: ServiceError.Api) {
                        if (e.status != 404 && e.status != 409) throw e
                        if (e.status == 409 && service.getApproval(approvalId).state == ApprovalState.Pending) return@withLock false
                    }
                } else if (approval.state == ApprovalState.Unknown) {
                    return@withLock false
                }
                if (inboxId != null && service.me().id == userId) {
                    try {
                        val item = service.inboxItem(inboxId)
                        if (item.kind == InboxKind.Approval && item.approvalId == approvalId && !item.read) {
                            service.markInboxRead(listOf(item.id))
                        }
                    } catch (e: ServiceError.Api) {
                        if (e.status != 404) throw e
                    }
                }
                true
            }
    }
}
