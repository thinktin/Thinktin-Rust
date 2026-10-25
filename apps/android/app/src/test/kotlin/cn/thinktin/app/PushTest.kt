package cn.thinktin.app

import android.app.NotificationManager
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.push.NotificationChannels
import cn.thinktin.app.push.PushCoordinator
import cn.thinktin.app.push.PushMessage
import cn.thinktin.app.push.PushNotifier
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** 13.8 推送：载荷解析、点开去哪、渠道、令牌上报和点开过的通知标已读。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN")
class PushTest {
    private fun data(vararg pairs: Pair<String, String>) = mapOf(*pairs)

    @Test
    fun parsesFcmDataAndIgnoresOtherPushes() {
        val message = PushMessage.fromData(
            data(
                "tt_kind" to "approval", "tt_approval" to "appr-1", "tt_run" to "run-1", "tt_inbox" to "inbox-5",
                "tt_instance" to "inst-coder", "tt_subtype" to " ", "google.message_id" to "x",
            ),
        )
        assertNotNull(message)
        message!!
        assertEquals(InboxKind.Approval, message.kind)
        assertEquals("appr-1", message.approvalId)
        assertEquals("inbox-5", message.inboxId)
        assertNull(message.subtype)
        assertEquals(NotificationChannels.APPROVAL, message.channelId)
        assertNull(PushMessage.fromData(data("title" to "hi")))
        // 认不出的种类按“提醒”；不像 id 的 id 当作没有。
        val odd = PushMessage.fromData(data("tt_kind" to "new_kind", "tt_run" to "../etc", "tt_plan" to "plan-1"))!!
        assertEquals(InboxKind.Info, odd.kind)
        assertNull(odd.runId)
        assertEquals(NotificationChannels.RESULTS, odd.channelId)
    }

    @Test
    fun deepLinksFollowTheSameRulesAsTheInbox() {
        fun link(vararg pairs: Pair<String, String>) = PushMessage.fromData(mapOf(*pairs))!!.deepLink().toString()
        assertEquals("thinktin://approval/a1", link("tt_kind" to "approval", "tt_approval" to "a1", "tt_run" to "r1"))
        assertEquals("thinktin://run/r1", link("tt_kind" to "approval", "tt_run" to "r1"))
        assertEquals("thinktin://inbox/i1", link("tt_kind" to "approval", "tt_inbox" to "i1"))
        assertEquals("thinktin://vault/request/v1", link("tt_kind" to "vault_request", "tt_vault_request" to "v1"))
        assertEquals("thinktin://plan/p1", link("tt_kind" to "plan_confirm", "tt_plan" to "p1"))
        assertEquals("thinktin://run/r1", link("tt_kind" to "run_failed", "tt_run" to "r1", "tt_plan" to "p1"))
        assertEquals("thinktin://plan/p1", link("tt_kind" to "info", "tt_plan" to "p1", "tt_inbox" to "i1"))
        assertEquals("thinktin://inbox/i1", link("tt_kind" to "computer_approval", "tt_inbox" to "i1"))
        assertEquals("thinktin://inbox", link("tt_kind" to "info"))
    }

    @Test
    fun extrasAndJiguangJsonRoundTrip() {
        val message = PushMessage(
            kind = InboxKind.RunFinished, runId = "run-done", inboxId = "inbox-3", instanceId = "inst-coder",
        )
        assertEquals(message, PushMessage.fromExtras(message.toExtras()))
        val intent = Intent().putExtras(message.toExtras())
        assertEquals(message, PushMessage.fromIntent(intent))
        assertNull(PushMessage.fromIntent(Intent(Intent.ACTION_MAIN)))
        val json = """{"tt_kind":"plan_confirm","tt_plan":"plan-weekly","tt_inbox":"inbox-1"}"""
        assertEquals("thinktin://plan/plan-weekly", PushMessage.fromJson(json)!!.deepLink().toString())
        assertNull(PushMessage.fromJson("not json"))
        assertNull(PushMessage.fromJson(null))
    }

    @Test
    fun channelsAreCreatedAtStartup() {
        val context = ApplicationProvider.getApplicationContext<DemoTestApp>()
        val manager = context.getSystemService(NotificationManager::class.java)
        val approval = manager.getNotificationChannel(NotificationChannels.APPROVAL)
        val results = manager.getNotificationChannel(NotificationChannels.RESULTS)
        assertEquals(NotificationManager.IMPORTANCE_HIGH, approval.importance)
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, results.importance)
        assertEquals("审批与请求", approval.name.toString())
    }

    @Test
    fun notifierNeedsPermissionAndOpensTheDeepLink() {
        val context = ApplicationProvider.getApplicationContext<DemoTestApp>()
        val message = PushMessage(kind = InboxKind.Approval, approvalId = "appr-1", inboxId = "inbox-5")
        assertFalse(PushNotifier.show(context, "小码等你审批", "删除文件", message))
        shadowOf(context).grantPermissions(android.Manifest.permission.POST_NOTIFICATIONS)
        assertTrue(PushNotifier.show(context, "小码等你审批", "删除文件", message))
        val manager = context.getSystemService(NotificationManager::class.java)
        val posted = shadowOf(manager).allNotifications.single()
        assertEquals(NotificationChannels.APPROVAL, posted.channelId)
        val open = PushNotifier.openIntent(context, message)
        assertEquals("thinktin://approval/appr-1", open.data.toString())
        assertEquals(message, PushMessage.fromIntent(open))
        PushNotifier.cancelAll(context)
        assertTrue(shadowOf(manager).allNotifications.isEmpty())
    }

    @Test
    fun coordinatorReportsTheTokenOnceAndMarksOpenedNotificationsRead() = runTest {
        val service = RecordingPushService()
        val push = PushCoordinator()
        push.sync(service)
        assertTrue(service.tokens.isEmpty())
        push.onNewToken("fcm", " token-1 ")
        push.sync(service)
        push.sync(service)
        assertEquals(listOf("fcm" to "token-1"), service.tokens)
        // 换了令牌再报。
        push.onNewToken("fcm", "token-2")
        push.sync(service)
        assertEquals("token-2", service.tokens.last().second)

        // 点开过的通知：登录着时标已读。
        push.onOpened(PushMessage(kind = InboxKind.Approval, inboxId = "inbox-5"))
        push.onOpened(PushMessage(kind = InboxKind.Info))
        push.sync(service)
        assertEquals(listOf(listOf("inbox-5")), service.reads)
        assertTrue(push.pendingReads.value.isEmpty())

        // 断网：留着下次再标。
        service.failReads = ServiceError.Network("offline")
        push.onOpened(PushMessage(kind = InboxKind.Info, inboxId = "inbox-6"))
        push.sync(service)
        assertEquals(setOf("inbox-6"), push.pendingReads.value)
        service.failReads = null
        push.sync(service)
        assertTrue(push.pendingReads.value.isEmpty())

        // 退出登录后再登录：令牌再报一次。
        service.fake.auth.value = AuthState.SignedOut
        push.sync(service)
        service.fake.auth.value = AuthState.SignedIn
        push.sync(service)
        assertEquals(3, service.tokens.size)
    }
}

/** 记下令牌、标已读的服务替身（登录状态由 [fake] 控制）。 */
private class RecordingPushService(
    val fake: FakeThinktinService = FakeThinktinService(),
) : cn.thinktin.data.service.ThinktinService by fake {
    val tokens = mutableListOf<Pair<String, String>>()
    val reads = mutableListOf<List<String>>()
    var failReads: ServiceError? = null

    override val authState get() = fake.authState

    override suspend fun setPushToken(channel: String, token: String) {
        tokens += channel to token
    }

    override suspend fun markInboxRead(ids: List<String>, upToId: String?): Long {
        failReads?.let { throw it }
        reads += ids
        return 0
    }
}
