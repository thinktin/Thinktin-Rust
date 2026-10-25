package cn.thinktin.app.push

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import cn.thinktin.app.navigation.DeepLinks
import cn.thinktin.data.model.InboxKind
import org.json.JSONException
import org.json.JSONObject

/**
 * 推送带给 App 的数据（docs/push.md 第 3 节）：FCM 的 `data`、极光的 `extras`，键都以 `tt_` 开头、值都是字符串，
 * 只有种类、子类型和 id，不带内容。点开通知时的 Intent 里也是这些键（FCM 在后台时系统把 `data` 放进启动 Intent 的
 * extras；前台时 [PushNotifier] 自己发的通知照样放）。
 */
data class PushMessage(
    val kind: InboxKind,
    val subtype: String? = null,
    val instanceId: String? = null,
    val runId: String? = null,
    val approvalId: String? = null,
    val planId: String? = null,
    val inboxId: String? = null,
    val vaultRequestId: String? = null,
) {
    /**
     * 点开去哪（深链，和 iOS 的 `PushPayload.route`、收件箱的 `targetRoute` 同一套规则，docs/ios.md 第 6.1 节）：
     * - 审批：审批详情；没有审批 id 时运行详情，再没有就是收件箱里的这一条；
     * - 电脑审批（13.9 还没有页面）：运行详情，否则收件箱里的这一条；
     * - 保险箱请求：填写请求；没有请求 id 时同运行完成；
     * - 计划待确认：计划详情（那里确认）；
     * - 运行完成 / 失败、其他提醒：子类型是审批超时跳过的去运行详情；再按运行 → 计划 → 收件箱里的这一条 → 收件箱。
     */
    fun deepLink(): Uri {
        val inbox = inboxId?.let { link("inbox", it) } ?: Uri.parse(DeepLinks.INBOX)
        val fallback = runId?.let { link("run", it) } ?: planId?.let { link("plan", it) } ?: inbox
        return when (kind) {
            InboxKind.Approval -> approvalId?.let { link("approval", it) } ?: runId?.let { link("run", it) } ?: inbox
            InboxKind.ComputerApproval -> runId?.let { link("run", it) } ?: inbox
            InboxKind.VaultRequest -> vaultRequestId?.let { link("vault/request", it) } ?: fallback
            InboxKind.PlanConfirm -> planId?.let { link("plan", it) } ?: inbox
            InboxKind.RunFinished, InboxKind.RunFailed, InboxKind.Info -> fallback
        }
    }

    /** 放进通知的 PendingIntent（[fromExtras] 读回来）。 */
    fun toExtras(): Bundle = Bundle().apply {
        putString(KEY_KIND, kind.wire)
        for ((key, value) in ids()) if (value != null) putString(key, value)
    }

    /** 走哪个通知渠道（和服务端一致：等用户处理的走审批渠道）。 */
    val channelId: String
        get() = if (kind.waitsForUser) NotificationChannels.APPROVAL else NotificationChannels.RESULTS

    private fun ids(): List<Pair<String, String?>> = listOf(
        KEY_SUBTYPE to subtype,
        KEY_INSTANCE to instanceId,
        KEY_RUN to runId,
        KEY_APPROVAL to approvalId,
        KEY_PLAN to planId,
        KEY_INBOX to inboxId,
        KEY_VAULT_REQUEST to vaultRequestId,
    )

    companion object {
        const val KEY_KIND = "tt_kind"
        const val KEY_SUBTYPE = "tt_subtype"
        const val KEY_INSTANCE = "tt_instance"
        const val KEY_RUN = "tt_run"
        const val KEY_APPROVAL = "tt_approval"
        const val KEY_PLAN = "tt_plan"
        const val KEY_INBOX = "tt_inbox"
        const val KEY_VAULT_REQUEST = "tt_vault_request"

        /** FCM 的 `data`（`RemoteMessage.data`）。没有 `tt_kind` 的不是我们的推送。 */
        fun fromData(data: Map<String, String?>): PushMessage? {
            val kind = data[KEY_KIND]?.takeIf { it.isNotBlank() } ?: return null
            fun id(key: String) = data[key]?.trim()?.takeIf { it.isNotEmpty() && isSafeId(it) }
            return PushMessage(
                kind = InboxKind.fromWire(kind.trim()),
                subtype = data[KEY_SUBTYPE]?.trim()?.takeIf { it.isNotEmpty() },
                instanceId = id(KEY_INSTANCE),
                runId = id(KEY_RUN),
                approvalId = id(KEY_APPROVAL),
                planId = id(KEY_PLAN),
                inboxId = id(KEY_INBOX),
                vaultRequestId = id(KEY_VAULT_REQUEST),
            )
        }

        /** 点开通知的 Intent 的 extras（FCM 后台通知、[PushNotifier] 发的、极光点开时转过来的）。 */
        fun fromExtras(extras: Bundle?): PushMessage? {
            if (extras == null || !extras.containsKey(KEY_KIND)) return null
            val data = extras.keySet().filter { it.startsWith("tt_") }.associateWith { key ->
                @Suppress("DEPRECATION")
                extras.get(key)?.toString()
            }
            return fromData(data)
        }

        fun fromIntent(intent: Intent?): PushMessage? = fromExtras(intent?.extras)

        /** 极光的 extras（`NotificationMessage.notificationExtras`，JSON 字符串）。 */
        fun fromJson(json: String?): PushMessage? {
            if (json.isNullOrBlank()) return null
            return try {
                val obj = JSONObject(json)
                fromData(obj.keys().asSequence().associateWith { obj.optString(it) })
            } catch (_: JSONException) {
                null
            }
        }

        /** id 只能是字母、数字、`-`、`_`（UUID）：不像 id 的当作没有，免得拼出奇怪的深链。 */
        private fun isSafeId(value: String) = value.length <= 64 && value.all { it.isLetterOrDigit() || it == '-' || it == '_' }

        private fun link(path: String, id: String): Uri = Uri.parse("${DeepLinks.SCHEME}://$path/${Uri.encode(id)}")
    }
}

/** 等用户处理的种类（审批、电脑审批、保险箱请求）：走高优先级的审批渠道（服务端 `PushKind::waits_for_user`）。 */
val InboxKind.waitsForUser: Boolean
    get() = this == InboxKind.Approval || this == InboxKind.ComputerApproval || this == InboxKind.VaultRequest
