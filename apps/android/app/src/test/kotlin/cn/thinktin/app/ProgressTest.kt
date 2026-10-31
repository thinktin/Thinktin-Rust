package cn.thinktin.app

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.progress.ProgressNotifier
import cn.thinktin.app.progress.RunProgress
import cn.thinktin.app.progress.RunProgressTracker
import cn.thinktin.app.progress.SystemProgressNotifier
import cn.thinktin.app.push.NotificationChannels
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.WaitCode
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** 记下发了、撤了什么。 */
private class RecordingNotifier(var allowed: Boolean = true) : ProgressNotifier {
    val shown = mutableListOf<RunProgress>()
    val cancelled = mutableListOf<String>()

    override fun show(progress: RunProgress): Boolean {
        if (allowed) shown += progress
        return allowed
    }

    override fun cancel(runId: String) {
        cancelled += runId
    }
}

/** 事件流由测试推。 */
private class StreamService(
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    val stream = MutableSharedFlow<EventStreamItem>(extraBufferCapacity = 16)

    override fun events(instanceId: String): Flow<EventStreamItem> = stream
}

private fun run(id: String = "run-1", state: RunState = RunState.Queued, parent: String? = null) = Run(
    id = id, kind = RunKind.Agent, instanceId = "inst-coder", planId = null, parentRunId = parent, rootRunId = parent ?: id,
    stepKey = null, source = RunSource.User, prompt = "写一份报告（不该出现在通知里）", state = state, stateReason = null,
    attempt = 1, tokensUsed = 0, summary = null, error = null, createdAtMs = 1_000, startedAtMs = null, finishedAtMs = null,
)

private fun event(kind: String, runId: String? = "run-1", payload: JsonObject = JsonObject(emptyMap()), at: Long = 5_000) =
    InstanceEvent("inst-coder", 1, runId, kind, payload, aiGenerated = false, createdAtMs = at)

private fun state(value: String, wait: String? = null) = buildJsonObject {
    put("state", value)
    wait?.let { put("wait_code", it) }
}

/** 13.10：进度怎么按事件变、跟踪器发 / 更新 / 撤通知、系统通知的样子（常驻、低优先级、不带任务原文）。 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN")
class ProgressTest {
    @Test
    fun progressFollowsStateAndToolCalls() {
        var p = RunProgress.of(run(), "小码")
        assertEquals(RunState.Queued, p.state)
        p = p.apply(event(EventKinds.RUN_STATE, payload = state("running"), at = 7_000))
        assertEquals(RunState.Running, p.state)
        assertEquals(7_000L, p.startedAtMs)
        p = p.apply(event(EventKinds.AGENT_TOOL_CALL)).apply(event(EventKinds.AGENT_PLATFORM_TOOL_CALL))
        assertEquals(1, p.steps)
        // 别的运行、别的事件不算。
        p = p.apply(event(EventKinds.AGENT_TOOL_CALL, runId = "other")).apply(event(EventKinds.AGENT_MESSAGE))
        assertEquals(1, p.steps)
        p = p.apply(event(EventKinds.RUN_STATE, payload = state("waiting_quota", "rate_limited")))
        assertEquals(WaitCode.RateLimited, p.waitCode)
        assertEquals("开始时间不变", 7_000L, p.startedAtMs)
        p = p.apply(event(EventKinds.RUN_STATE, payload = state("succeeded")))
        assertTrue(p.isFinished)
        assertNull(p.waitCode)
        // 缓存里已经收到的终止事件覆盖较旧的运行快照。
        val cached = listOf(event(EventKinds.AGENT_TOOL_CALL), event(EventKinds.RUN_STATE, payload = state("failed")))
        val fromCache = RunProgress.of(run(state = RunState.Running), "小码", cached)
        assertEquals(1, fromCache.steps)
        assertEquals(RunState.Failed, fromCache.state)
    }

    @Test
    fun trackerShowsUpdatesAndCancelsWhenTheRunEnds() = runTest(UnconfinedTestDispatcher()) {
        val service = StreamService()
        val notifier = RecordingNotifier()
        val tracker = RunProgressTracker(TestScope(testScheduler), notifier)
        tracker.track(service, run(), "小码")
        testScheduler.advanceUntilIdle()
        assertEquals(setOf("run-1"), tracker.tracked.value)
        assertEquals(1, notifier.shown.size)
        // 已经在跟：不重复。
        tracker.track(service, run(), "小码")
        testScheduler.advanceUntilIdle()
        assertEquals(1, notifier.shown.size)

        service.stream.emit(EventStreamItem.Event(event(EventKinds.RUN_STATE, payload = state("running"))))
        service.stream.emit(EventStreamItem.Event(event(EventKinds.AGENT_TOOL_CALL)))
        service.stream.emit(EventStreamItem.Event(event(EventKinds.AGENT_MESSAGE)))
        testScheduler.advanceUntilIdle()
        assertEquals(listOf(0, 0, 1), notifier.shown.map { it.steps })
        service.stream.emit(EventStreamItem.Event(event(EventKinds.RUN_STATE, payload = state("succeeded"))))
        testScheduler.advanceUntilIdle()
        assertEquals(listOf("run-1"), notifier.cancelled)
        assertTrue(tracker.tracked.value.isEmpty())
    }

    @Test
    fun trackerStopsOnRequestStreamEndOrMissingPermission() = runTest(UnconfinedTestDispatcher()) {
        val service = StreamService()
        val notifier = RecordingNotifier()
        val tracker = RunProgressTracker(TestScope(testScheduler), notifier)
        // 已经结束的不跟。
        tracker.track(service, run(state = RunState.Succeeded), "小码")
        testScheduler.advanceUntilIdle()
        assertTrue(notifier.shown.isEmpty())

        tracker.track(service, run("a"), "小码")
        tracker.track(service, run("b"), "小码")
        testScheduler.advanceUntilIdle()
        tracker.stop("a")
        assertEquals(setOf("b"), tracker.tracked.value)
        assertEquals(listOf("a"), notifier.cancelled)
        // 事件流以终止状态结束：不再更新，通知留着（计时器照走）。
        service.stream.emit(EventStreamItem.Status(StreamState.SignedOut))
        testScheduler.advanceUntilIdle()
        assertTrue(tracker.tracked.value.isEmpty())
        assertEquals(listOf("a"), notifier.cancelled)

        // 退出登录：全撤。
        tracker.track(service, run("c"), "小码")
        testScheduler.advanceUntilIdle()
        tracker.stopAll()
        assertEquals(listOf("a", "c"), notifier.cancelled)

        // 没有通知权限：什么都不跟。
        val denied = RecordingNotifier(allowed = false)
        val quiet = RunProgressTracker(TestScope(testScheduler), denied)
        quiet.track(service, run("d"), "小码")
        testScheduler.advanceUntilIdle()
        assertTrue(quiet.tracked.value.isEmpty())
    }

    @Test
    fun systemNotificationIsOngoingQuietAndHidesTheTask() {
        val app = ApplicationProvider.getApplicationContext<DemoTestApp>()
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        NotificationChannels.ensure(app)
        val notifier = SystemProgressNotifier(app)
        val progress = RunProgress("run-1", "inst-coder", "小码", RunState.Running, 2, 10_000, null)
        assertTrue(notifier.show(progress))
        val manager = app.getSystemService(NotificationManager::class.java)
        val posted = shadowOf(manager).allNotifications.single()
        assertEquals(NotificationChannels.PROGRESS, posted.channelId)
        assertTrue(posted.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(NotificationCompat.CATEGORY_PROGRESS, posted.category)
        assertEquals("小码", posted.extras.getString(Notification.EXTRA_TITLE))
        assertEquals("运行中 · 2 步", posted.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals(10_000L, posted.`when`)
        assertFalse(posted.extras.toString().contains("写一份报告"))
        assertEquals("有任务在进行", posted.publicVersion.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals(SystemProgressNotifier.TIMEOUT_MS, posted.timeoutAfter)
        assertEquals(NotificationManager.IMPORTANCE_LOW, manager.getNotificationChannel(NotificationChannels.PROGRESS).importance)

        // 等 key：显示原因。
        notifier.show(progress.copy(state = RunState.WaitingQuota, waitCode = WaitCode.RateLimited, steps = 0))
        val waiting = shadowOf(manager).allNotifications.single()
        assertTrue(waiting.extras.getCharSequence(Notification.EXTRA_TEXT).toString().isNotBlank())
        notifier.cancel("run-1")
        assertTrue(shadowOf(manager).allNotifications.isEmpty())
    }

    @Test
    fun startedRunsAreTrackedOnlyWhenTheSettingIsOn() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<DemoTestApp>()
        val notifier = RecordingNotifier()
        val service = StreamService()
        val container = testContainer(app, { service }, progressNotifier = notifier)
        container.trackStartedRun(service, run(), "ThinkTin")
        waitUntil { container.progress.tracked.value.isNotEmpty() }
        assertEquals("小码", notifier.shown.first().title)
        container.progress.stopAll()

        container.settingsRepository.setProgressNotifications(false)
        assertFalse(container.settings.first().progressNotifications)
        container.trackStartedRun(service, run("run-2"), "ThinkTin")
        Thread.sleep(200)
        assertTrue(container.progress.tracked.value.isEmpty())
    }

    private fun waitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "timed out" }
            Thread.sleep(10)
        }
    }
}
