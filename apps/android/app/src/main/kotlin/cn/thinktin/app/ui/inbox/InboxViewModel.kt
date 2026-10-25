package cn.thinktin.app.ui.inbox

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.navigation.targetRoute
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

data class InboxUiState(
    /** 第一次加载（还没有数据）。 */
    val loading: Boolean = true,
    /** 下拉刷新中。 */
    val refreshing: Boolean = false,
    val loadingMore: Boolean = false,
    val items: List<InboxItem> = emptyList(),
    val unread: Long = 0,
    /** 更早的都拉完了。 */
    val endReached: Boolean = false,
    /** 加载失败且没有数据：整页显示错误和重试。 */
    val loadError: UiText? = null,
    /** 正在标未读、删除的条目。 */
    val busy: Set<String> = emptySet(),
    /** 打开着的一条（推送点进来的 `inbox?itemId=`，或者没有更具体页面的条目）。 */
    val opened: InboxItem? = null,
    /** 要打开的那条找不到了（删了、不是这个账号的）。 */
    val openedMissing: Boolean = false,
) {
    val isEmpty: Boolean get() = items.isEmpty()
}

sealed interface InboxEvent {
    /** 去条目对应的页面（[targetRoute]）。 */
    data class Navigate(val route: String) : InboxEvent

    /** 操作失败、刷新失败（已经有列表时）的提示。 */
    data class Notice(val text: UiText) : InboxEvent
}

/** 一天的条目（列表按天分组，第 4.8 节）。 */
data class InboxDay(val day: LocalDate, val items: List<InboxItem>)

/** 按天分组（[zone] 里的日期），保持原来的顺序（最新的在前）。 */
fun List<InboxItem>.groupByDay(zone: ZoneId): List<InboxDay> =
    groupBy { Instant.ofEpochMilli(it.createdAtMs).atZone(zone).toLocalDate() }
        .map { (day, items) -> InboxDay(day, items) }

/**
 * 收件箱（13.8，路由 `inbox?itemId=`，第 4.8 节）：运行完成、失败、待审批、保险箱请求、计划待确认、其他提醒，最新的在前。
 *
 * - 先显示缓存（`cachedInbox`、`cachedUnread`），再同步（`syncInbox`：补发离线时标的已读、拉最新一页）；最新一页换掉开头，
 *   已经翻出来的留着；上拉加载更早的（`olderInbox`，断网时翻缓存）。
 * - 点一条：标已读，去对应的页面（[targetRoute]，和推送同一套规则）；没有更具体的页面时在面板里打开它。
 * - 标已读断网也行（client-core 联网后补发），标回未读、删除要联网；“全部已读”只标到最上面那条为止。
 * - 带 [initialItemId]（推送、深链 `thinktin://inbox/{id}`）：打开那一条并标已读。
 */
class InboxViewModel(
    private val service: ThinktinService,
    initialItemId: String? = null,
) : ViewModel() {
    private val state = MutableStateFlow(InboxUiState())
    val uiState: StateFlow<InboxUiState> = state.asStateFlow()

    private val eventChannel = Channel<InboxEvent>(Channel.BUFFERED)
    val events: Flow<InboxEvent> = eventChannel.receiveAsFlow()

    private var loadJob: Job? = null
    private var moreJob: Job? = null
    private var shownOnce = false

    init {
        viewModelScope.launch {
            showCached()
            load(initial = state.value.isEmpty)
        }
        if (initialItemId != null) openItem(initialItemId)
    }

    /** 页面每次显示时调：第一次已经在 init 里加载了；之后（从别的页面回来）重新同步。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        refresh()
    }

    fun refresh() = load(initial = false)

    fun retry() = load(initial = true)

    private fun load(initial: Boolean) {
        loadJob?.cancel()
        state.update { it.copy(loading = initial && it.isEmpty, refreshing = !initial, loadError = null) }
        loadJob = viewModelScope.launch {
            try {
                val page = service.syncInbox(PAGE_SIZE)
                state.update { it.merge(page.items).copy(unread = page.unread, loading = false, refreshing = false) }
            } catch (e: ServiceError) {
                // 断网：照缓存显示（离线时标的已读、删掉的都在缓存里）。
                if (e is ServiceError.Network) showCached()
                val text = ErrorText.of(e)
                if (!state.value.isEmpty) eventChannel.trySend(InboxEvent.Notice(text))
                state.update {
                    it.copy(loading = false, refreshing = false, loadError = if (it.isEmpty) text else null)
                }
            }
        }
    }

    /** 上拉加载更早的（列表滚到底时）。 */
    fun loadMore() {
        val current = state.value
        val last = current.items.lastOrNull() ?: return
        if (current.endReached || current.loadingMore || moreJob?.isActive == true) return
        state.update { it.copy(loadingMore = true) }
        moreJob = viewModelScope.launch {
            try {
                val older = service.olderInbox(last.id, PAGE_SIZE)
                state.update { it.append(older).copy(loadingMore = false, endReached = older.size < PAGE_SIZE) }
            } catch (e: ServiceError) {
                val cached = if (e is ServiceError.Network) service.cachedInbox(last.id, PAGE_SIZE) else emptyList()
                if (cached.isNotEmpty()) {
                    state.update { it.append(cached).copy(loadingMore = false) }
                } else {
                    state.update { it.copy(loadingMore = false) }
                    eventChannel.trySend(InboxEvent.Notice(ErrorText.of(e)))
                }
            }
        }
    }

    /** 点一条：标已读；有对应的页面就去，没有就在面板里打开。 */
    fun open(item: InboxItem) {
        markRead(item)
        val route = item.targetRoute()
        if (route != null) {
            eventChannel.trySend(InboxEvent.Navigate(route))
        } else {
            state.update { it.copy(opened = item.copy(read = true), openedMissing = false) }
        }
    }

    /** 推送、深链点进来的一条：列表里有就用列表里的，没有就单独取。 */
    fun openItem(itemId: String) {
        viewModelScope.launch {
            val known = state.value.items.firstOrNull { it.id == itemId }
            val item = known ?: try {
                service.inboxItem(itemId)
            } catch (e: ServiceError) {
                if (e is ServiceError.Api && (e.code == "not_found" || e.status == 404)) {
                    state.update { it.copy(opened = null, openedMissing = true) }
                } else {
                    eventChannel.trySend(InboxEvent.Notice(ErrorText.of(e)))
                }
                return@launch
            }
            state.update { it.copy(opened = item.copy(read = true), openedMissing = false) }
            markRead(item)
        }
    }

    /** 打开着的那条去对应的页面（面板上的“查看”）。 */
    fun openTarget() {
        val route = state.value.opened?.targetRoute() ?: return
        closeOpened()
        eventChannel.trySend(InboxEvent.Navigate(route))
    }

    fun closeOpened() {
        state.update { it.copy(opened = null, openedMissing = false) }
    }

    fun markRead(item: InboxItem) {
        if (item.read) return
        setRead(item.id, true)
        viewModelScope.launch {
            try {
                val unread = service.markInboxRead(listOf(item.id))
                state.update { it.copy(unread = unread) }
            } catch (e: ServiceError) {
                setRead(item.id, false)
                eventChannel.trySend(InboxEvent.Notice(ErrorText.of(e)))
            }
        }
    }

    /** 全部已读（到最上面那条为止，之后新来的不算）。 */
    fun markAllRead() {
        val newest = state.value.items.firstOrNull() ?: return
        val before = state.value.items
        state.update { s -> s.copy(items = s.items.map { it.copy(read = true) }) }
        viewModelScope.launch {
            try {
                val unread = service.markInboxRead(emptyList(), upToId = newest.id)
                state.update { it.copy(unread = unread) }
            } catch (e: ServiceError) {
                state.update { it.copy(items = before) }
                eventChannel.trySend(InboxEvent.Notice(ErrorText.of(e)))
            }
        }
    }

    /** 标回未读（要联网）。 */
    fun markUnread(item: InboxItem) {
        if (!item.read || item.id in state.value.busy) return
        busy(item.id, true)
        viewModelScope.launch {
            try {
                val unread = service.markInboxUnread(item.id)
                setRead(item.id, false)
                state.update { it.copy(unread = unread) }
            } catch (e: ServiceError) {
                eventChannel.trySend(InboxEvent.Notice(ErrorText.of(e)))
            } finally {
                busy(item.id, false)
            }
        }
    }

    /** 删一条（要联网，缓存里一起删）；已经没有了的照样拿掉。 */
    fun delete(item: InboxItem) {
        if (item.id in state.value.busy) return
        busy(item.id, true)
        viewModelScope.launch {
            try {
                service.deleteInboxItem(item.id)
                remove(item)
                eventChannel.trySend(InboxEvent.Notice(UiText(R.string.inbox_deleted)))
            } catch (e: ServiceError) {
                if (e is ServiceError.Api && (e.code == "not_found" || e.status == 404)) {
                    remove(item)
                } else {
                    eventChannel.trySend(InboxEvent.Notice(ErrorText.of(e)))
                }
            } finally {
                busy(item.id, false)
            }
        }
    }

    private suspend fun showCached() {
        val limit = maxOf(state.value.items.size, PAGE_SIZE)
        val cached = service.cachedInbox(null, limit)
        val unread = service.cachedUnread()
        state.update { if (cached.isEmpty() && it.isEmpty) it.copy(unread = unread) else it.copy(items = cached, unread = unread) }
    }

    private fun remove(item: InboxItem) {
        state.update { s ->
            s.copy(
                items = s.items.filterNot { it.id == item.id },
                unread = if (item.read) s.unread else (s.unread - 1).coerceAtLeast(0),
                opened = s.opened?.takeIf { it.id != item.id },
            )
        }
    }

    private fun setRead(id: String, read: Boolean) {
        state.update { s ->
            s.copy(
                items = s.items.map { if (it.id == id) it.copy(read = read) else it },
                opened = s.opened?.let { if (it.id == id) it.copy(read = read) else it },
            )
        }
    }

    private fun busy(id: String, on: Boolean) {
        state.update { it.copy(busy = if (on) it.busy + id else it.busy - id) }
    }

    companion object {
        const val PAGE_SIZE = 30
    }
}

/** 最新一页换掉列表的开头；比它更早的、已经翻出来的留着。不满一页说明一共就这么多。 */
internal fun InboxUiState.merge(latest: List<InboxItem>): InboxUiState {
    val oldest = latest.lastOrNull()
    if (latest.size < InboxViewModel.PAGE_SIZE || oldest == null) {
        return copy(items = latest, endReached = true, loadError = null)
    }
    val ids = latest.mapTo(HashSet()) { it.id }
    val older = items.filter { it.id !in ids && isOlder(it, oldest) }
    return copy(items = latest + older, endReached = if (older.isEmpty()) false else endReached, loadError = null)
}

private fun InboxUiState.append(older: List<InboxItem>): InboxUiState {
    val ids = items.mapTo(HashSet()) { it.id }
    return copy(items = items + older.filter { it.id !in ids })
}

/** 列表的顺序：时间新的在前，同一时间按 id。 */
private fun isOlder(item: InboxItem, than: InboxItem): Boolean =
    item.createdAtMs < than.createdAtMs || (item.createdAtMs == than.createdAtMs && item.id < than.id)
