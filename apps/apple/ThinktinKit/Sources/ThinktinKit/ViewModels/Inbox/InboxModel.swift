import Foundation
import Observation

/// 收件箱（WBS 12.8，`.inbox`，抽屉里的“收件箱”）：运行结束、失败、待审批、保险箱请求、计划待确认、其他提醒，最新的在前。
///
/// - 先显示缓存（`cachedInbox`、`cachedUnread`），再同步（`syncInbox`：补发离线时标的已读、拉最新一页、合并进缓存）；
///   往下翻用 `olderInbox`，离线时翻缓存。离线策略是“有缓存”（docs/ios.md 第 6.2 节）。
/// - 点一条：标已读，去它对应的页面（`InboxItem.route`，和推送同一套规则）；没有更具体的页面时打开这条通知自己。
/// - 标已读没网也立即生效（client-core 联网后补发），标回未读、删除要联网。“全部已读”只标到列表最上面那条为止，
///   之后新来的不算。
/// - 未读数（`unread`）变了，页面告诉 `AppModel.inboxUnreadChanged`，抽屉和 App 图标的角标跟着变。
@Observable @MainActor
public final class InboxModel {
    /// 一页多少条。
    public static let pageSize = 30

    public private(set) var items: [InboxItem] = []
    public private(set) var unread = 0
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var isLoadingOlder = false
    /// 更早的都拉完了。
    public private(set) var reachedEnd = false
    public private(set) var error: ClientError?
    /// 标已读 / 未读、删除出的错（页面顶部一条横幅）。
    public private(set) var actionError: ClientError?
    /// 正在标未读、删除的条目。
    public private(set) var working: Set<InboxItemID> = []

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if !hasLoaded { showCached() }
        do {
            let page = try await client.syncInbox(limit: Self.pageSize)
            merge(latest: page.items)
            unread = page.unread
            error = nil
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            // 离线：缓存里有离线时标的已读、删掉的，照缓存显示。
            if failure.isOffline { showCached() }
            self.error = failure
        }
        hasLoaded = true
    }

    /// 往下翻一页（列表滚到底时）。
    public func loadOlder() async {
        guard hasLoaded, !reachedEnd, !isLoadingOlder, let last = items.last else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let older = try await client.olderInbox(before: last.id, limit: Self.pageSize)
            append(older)
            if older.count < Self.pageSize { reachedEnd = true }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isOffline, let cached = try? client.cachedInbox(before: last.id, limit: Self.pageSize),
                !cached.isEmpty
            {
                append(cached)
            } else {
                self.error = failure
            }
        }
    }

    /// 标已读（打开一条时也调）。没网也立即生效。
    public func markRead(_ item: InboxItem) async {
        guard !item.isRead else { return }
        update(item.id) { $0.isRead = true }
        do {
            unread = try await client.markInboxRead(ids: [item.id], upTo: nil)
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            update(item.id) { $0.isRead = false }
            actionError = failure
        }
    }

    /// 全部已读（到列表最上面那条为止）。
    public func markAllRead() async {
        guard let newest = items.first, items.contains(where: { !$0.isRead }) || unread > 0 else { return }
        let before = items
        for i in items.indices { items[i].isRead = true }
        do {
            unread = try await client.markInboxRead(ids: [], upTo: newest.id)
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            items = before
            actionError = failure
        }
    }

    /// 标回未读（要联网）。
    public func markUnread(_ item: InboxItem) async {
        guard item.isRead, !working.contains(item.id) else { return }
        working.insert(item.id)
        defer { working.remove(item.id) }
        do {
            unread = try await client.markInboxUnread(item.id)
            update(item.id) { $0.isRead = false }
        } catch {
            if let failure = ConversationErrors.from(error) { actionError = failure }
        }
    }

    /// 删一条（要联网，缓存里一起删）。
    public func delete(_ item: InboxItem) async {
        guard !working.contains(item.id) else { return }
        working.insert(item.id)
        defer { working.remove(item.id) }
        do {
            try await client.deleteInboxItem(item.id)
            items.removeAll { $0.id == item.id }
            if !item.isRead { unread = max(0, unread - 1) }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            // 已经没有了（别的设备删了）：一样拿掉。
            if failure.isNotFound {
                items.removeAll { $0.id == item.id }
            } else {
                actionError = failure
            }
        }
    }

    public func clearActionError() {
        actionError = nil
    }

    // MARK: 合并

    /// 缓存里的第一页（至少和现在显示的一样多）和未读数。
    private func showCached() {
        // 缓存不全（只有拉到过的），翻到底了没有还得问服务端：`reachedEnd` 不动。
        if let cached = try? client.cachedInbox(before: nil, limit: max(items.count, Self.pageSize)) {
            items = cached
        }
        if let count = try? client.cachedUnread() { unread = count }
    }

    /// 最新一页换掉列表的开头；比它更早的、已经翻出来的留着。不满一页说明一共就这么多。
    ///
    /// 最新一页和现在的列表一条都对不上（离线久了、缓存旧了，新来的超过一页），中间可能还隔着没拉到的：只留最新一页，
    /// 往下翻从它接着拉，不然隔着的那些永远翻不出来。
    private func merge(latest: [InboxItem]) {
        guard latest.count >= Self.pageSize, let oldest = latest.last else {
            items = latest
            reachedEnd = true
            return
        }
        let ids = Set(latest.map(\.id))
        guard items.contains(where: { ids.contains($0.id) }) else {
            items = latest
            reachedEnd = false
            return
        }
        let older = items.filter { !ids.contains($0.id) && Self.isOlder($0, than: oldest) }
        items = latest + older
        if older.isEmpty { reachedEnd = false }
    }

    private func append(_ older: [InboxItem]) {
        let ids = Set(items.map(\.id))
        items += older.filter { !ids.contains($0.id) }
    }

    private func update(_ id: InboxItemID, _ body: (inout InboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    /// 列表的顺序：时间新的在前，同一时间按 id。
    static func isOlder(_ item: InboxItem, than other: InboxItem) -> Bool {
        (item.createdAt, item.id.rawValue) < (other.createdAt, other.id.rawValue)
    }
}

/// 收件箱里的一条（WBS 12.8，`.inboxItem(id)`：推送、深链 `thinktin://inbox/{id}`、收件箱里没有更具体页面的条目进来）：
/// 标题、全文（agent 写的带 AI 生成标识）、时间；打开就标已读；有对应的页面时给一个“查看”按钮；可以标回未读、删除。
@Observable @MainActor
public final class InboxItemModel {
    public let itemID: InboxItemID
    public private(set) var item: InboxItem?
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    /// 没有这一条（删了、不是自己的）。
    public private(set) var isMissing = false
    /// 删掉了（页面该退回去）。
    public private(set) var isDeleted = false
    public private(set) var isWorking = false
    public private(set) var actionError: ClientError?
    /// 标已读 / 未读之后的未读数（页面告诉 `AppModel.inboxUnreadChanged`）。
    public private(set) var unread: Int?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, itemID: InboxItemID, item: InboxItem? = nil) {
        self.client = client
        self.itemID = itemID
        self.item = item?.id == itemID ? item : nil
    }

    /// 拉这一条（同时更新缓存），没读过的标已读。离线时从缓存里找。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            item = try await client.inboxItem(itemID)
            error = nil
            isMissing = false
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound {
                isMissing = true
            } else {
                if failure.isOffline, let cached = cachedItem() { item = cached }
                self.error = failure
            }
        }
        hasLoaded = true
        if let item, !item.isRead { await markRead() }
    }

    /// 标回未读（要联网）。
    public func markUnread() async {
        guard let item, item.isRead, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            unread = try await client.markInboxUnread(item.id)
            self.item?.isRead = false
        } catch {
            if let failure = ConversationErrors.from(error) { actionError = failure }
        }
    }

    public func delete() async {
        guard item != nil, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.deleteInboxItem(itemID)
            isDeleted = true
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isDeleted = true } else { actionError = failure }
        }
    }

    public func clearActionError() {
        actionError = nil
    }

    private func markRead() async {
        item?.isRead = true
        do {
            unread = try await client.markInboxRead(ids: [itemID], upTo: nil)
        } catch {
            guard ConversationErrors.from(error) != nil else { return }
            item?.isRead = false
        }
    }

    /// 缓存里的这一条（离线时；只找最近的几百条）。
    private func cachedItem() -> InboxItem? {
        (try? client.cachedInbox(before: nil, limit: 500))?.first { $0.id == itemID }
    }
}

extension PushPayload {
    /// 收件箱条目对应的“推送”：点开收件箱里的一条和点开推送去同一个地方（`route`）。
    public init(inboxItem item: InboxItem) {
        self.init(
            kind: Kind(rawValue: item.kind.rawValue), subtype: item.subtype, instanceID: item.instanceID,
            runID: item.runID, approvalID: item.approvalID, planID: item.planID, inboxItemID: item.id,
            vaultRequestID: item.vaultRequestID)
    }
}

extension InboxItem {
    /// 点开要去的页面（和推送同一套规则，docs/ios.md 第 6.1 节）；没有更具体的页面时为 nil（打开这条通知自己）。
    public var target: AppRoute? {
        let route = PushPayload(inboxItem: self).route
        return route == .inboxItem(id) || route == .inbox ? nil : route
    }
}
