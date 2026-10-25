package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.inbox.InboxEvent
import cn.thinktin.app.ui.inbox.InboxViewModel
import cn.thinktin.app.ui.inbox.groupByDay
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.InboxPage
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.ZoneId

/** 收件箱的服务替身：[items] 最新的在前，单数的读过；[failNext] 让某个方法下一次调用抛错。 */
private class InboxService(
    count: Int,
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    private val now = DemoTestApp.FIXED_CLOCK.millis()
    val items: MutableList<InboxItem> = (0 until count).map { i ->
        InboxItem(
            id = "inbox-%03d".format(999 - i), instanceId = "inst-coder", runId = if (i == 0) "run-done" else null,
            planId = null, approvalId = null, kind = if (i == 0) InboxKind.RunFinished else InboxKind.Info,
            title = "第 $i 条", body = "正文 $i", aiGenerated = i == 0, read = i % 2 == 1, createdAtMs = now - i * 3_600_000L,
        )
    }.toMutableList()
    private val failures = mutableMapOf<String, ServiceError>()

    fun failNext(method: String, error: ServiceError) {
        failures[method] = error
    }

    private fun maybeFail(method: String) {
        failures.remove(method)?.let { throw it }
    }

    private fun unread() = items.count { !it.read }.toLong()

    override suspend fun syncInbox(limit: Int): InboxPage {
        maybeFail("syncInbox")
        return InboxPage(items.take(limit), unread())
    }

    override suspend fun olderInbox(beforeId: String, limit: Int): List<InboxItem> {
        maybeFail("olderInbox")
        return cachedInbox(beforeId, limit)
    }

    override suspend fun cachedInbox(beforeId: String?, limit: Int): List<InboxItem> {
        val start = beforeId?.let { id -> items.indexOfFirst { it.id == id } + 1 } ?: 0
        return items.drop(start).take(limit)
    }

    override suspend fun cachedUnread(): Long = unread()

    override suspend fun markInboxRead(ids: List<String>, upToId: String?): Long {
        maybeFail("markInboxRead")
        val from = upToId?.let { id -> items.indexOfFirst { it.id == id } } ?: -1
        items.replaceAll { item ->
            val index = items.indexOf(item)
            if (item.id in ids || (ids.isEmpty() && from >= 0 && index >= from)) item.copy(read = true) else item
        }
        return unread()
    }

    override suspend fun markInboxUnread(itemId: String): Long {
        maybeFail("markInboxUnread")
        items.replaceAll { if (it.id == itemId) it.copy(read = false) else it }
        return unread()
    }

    override suspend fun inboxItem(itemId: String): InboxItem {
        maybeFail("inboxItem")
        return items.firstOrNull { it.id == itemId } ?: throw ServiceError.Api(404, "not_found", "no such item", null)
    }

    override suspend fun deleteInboxItem(itemId: String) {
        maybeFail("deleteInboxItem")
        if (!items.removeAll { it.id == itemId }) throw ServiceError.Api(404, "not_found", "no such item", null)
    }
}

/** 13.8：收件箱的同步、翻页、标已读 / 未读、删除、打开一条（路由里的 id 要 Uri.encode：用 Robolectric）。 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class)
class InboxViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun loadsPagesAndKeepsOlderOnesAfterSync() = runTest(dispatcher) {
        val service = InboxService(70)
        val vm = InboxViewModel(service)
        advanceUntilIdle()
        assertEquals(InboxViewModel.PAGE_SIZE, vm.uiState.value.items.size)
        assertEquals(35L, vm.uiState.value.unread)
        assertFalse(vm.uiState.value.endReached)
        vm.loadMore()
        advanceUntilIdle()
        vm.loadMore()
        advanceUntilIdle()
        assertEquals(70, vm.uiState.value.items.size)
        assertTrue(vm.uiState.value.endReached)

        service.items.add(0, service.items[0].copy(id = "inbox-new", title = "新的", createdAtMs = service.items[0].createdAtMs + 1))
        vm.refresh()
        advanceUntilIdle()
        assertEquals(71, vm.uiState.value.items.size)
        assertEquals("新的", vm.uiState.value.items.first().title)
        assertEquals(71, vm.uiState.value.items.map { it.id }.toSet().size)
    }

    @Test
    fun smallInboxIsComplete() = runTest(dispatcher) {
        val vm = InboxViewModel(InboxService(5))
        advanceUntilIdle()
        assertEquals(5, vm.uiState.value.items.size)
        assertTrue(vm.uiState.value.endReached)
        assertEquals(1, vm.uiState.value.items.groupByDay(ZoneId.of("Asia/Shanghai")).size)
    }

    @Test
    fun readUnreadAllReadAndDelete() = runTest(dispatcher) {
        val service = InboxService(6)
        val vm = InboxViewModel(service)
        advanceUntilIdle()
        val unreadItem = vm.uiState.value.items.first { !it.read }
        vm.markRead(unreadItem)
        advanceUntilIdle()
        assertEquals(2L, vm.uiState.value.unread)
        val read = vm.uiState.value.items.first { it.id == unreadItem.id }
        assertTrue(read.read)
        vm.markUnread(read)
        advanceUntilIdle()
        assertEquals(3L, vm.uiState.value.unread)
        vm.markAllRead()
        advanceUntilIdle()
        assertEquals(0L, vm.uiState.value.unread)
        assertTrue(vm.uiState.value.items.all { it.read })
        vm.delete(vm.uiState.value.items.last())
        advanceUntilIdle()
        assertEquals(5, vm.uiState.value.items.size)
        assertEquals(5, service.items.size)
    }

    @Test
    fun failedMarkReadIsRolledBackAndReported() = runTest(dispatcher) {
        val service = InboxService(4)
        val vm = InboxViewModel(service)
        advanceUntilIdle()
        vm.events.test {
            val item = vm.uiState.value.items.first { !it.read }
            service.failNext("markInboxRead", ServiceError.Api(500, "internal", "boom", null))
            vm.markRead(item)
            advanceUntilIdle()
            assertTrue(awaitItem() is InboxEvent.Notice)
            assertFalse(vm.uiState.value.items.first { it.id == item.id }.read)
            // 已经删掉了的照样拿掉，不报错。
            service.items.removeAll { it.id == item.id }
            vm.delete(item)
            advanceUntilIdle()
            assertTrue(vm.uiState.value.items.none { it.id == item.id })
            expectNoEvents()
        }
    }

    @Test
    fun openingGoesToTheTargetOrShowsTheItem() = runTest(dispatcher) {
        val service = InboxService(3)
        // 没有实例、运行、计划的提醒：没有更具体的页面。
        service.items[2] = service.items[2].copy(instanceId = null)
        val vm = InboxViewModel(service)
        advanceUntilIdle()
        vm.events.test {
            // 有运行的去运行详情。
            vm.open(vm.uiState.value.items[0])
            advanceUntilIdle()
            assertEquals(InboxEvent.Navigate("run/run-done"), awaitItem())
            // 没有更具体页面的在面板里打开、标已读。
            val bare = vm.uiState.value.items[2]
            vm.open(bare)
            advanceUntilIdle()
            assertEquals(bare.id, vm.uiState.value.opened?.id)
            assertTrue(service.items.first { it.id == bare.id }.read)
            vm.closeOpened()
            assertNull(vm.uiState.value.opened)
        }
    }

    @Test
    fun pushedItemOpensOrSaysItIsGone() = runTest(dispatcher) {
        val service = InboxService(3)
        val vm = InboxViewModel(service, initialItemId = service.items[2].id)
        advanceUntilIdle()
        assertEquals(service.items[2].id, vm.uiState.value.opened?.id)
        assertTrue(service.items[2].read)

        val gone = InboxViewModel(service, initialItemId = "inbox-gone")
        advanceUntilIdle()
        assertTrue(gone.uiState.value.openedMissing)
        assertNull(gone.uiState.value.opened)
    }

    @Test
    fun offlineShowsTheCache() = runTest(dispatcher) {
        val service = InboxService(4)
        service.failNext("syncInbox", ServiceError.Network("offline"))
        val vm = InboxViewModel(service)
        advanceUntilIdle()
        assertEquals(4, vm.uiState.value.items.size)
        assertNull(vm.uiState.value.loadError)
    }
}
