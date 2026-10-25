import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("收件箱（12.8）")
struct InboxModelTests {
    private func mock(_ state: MockState = DemoData.state()) -> MockClient {
        MockClient(state: state, stepDelay: 0, autoReply: false)
    }

    /// 一共 `count` 条，最新的在前，单数的读过。
    private func state(count: Int) -> MockState {
        var state = DemoData.state()
        let now = Date()
        state.inbox = (0..<count).map { i in
            InboxItem(
                id: InboxItemID(String(format: "0192f3a0-0000-7000-8000-%012d", 900_000 - i)), kind: .info,
                title: "第 \(i) 条", body: "", isRead: i % 2 == 1, createdAt: now.addingTimeInterval(Double(-i * 60)))
        }
        return state
    }

    @Test("同步：最新的在前、未读数；不满一页就是到底了")
    func load() async {
        let model = InboxModel(client: mock())
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.items.count == 5)
        #expect(model.unread == 3)
        #expect(model.reachedEnd)
        #expect(model.error == nil)
    }

    @Test("往下翻：一页一页拉到底；再同步时已经翻出来的留着")
    func paging() async {
        let client = mock(state(count: 70))
        let model = InboxModel(client: client)
        await model.load()
        #expect(model.items.count == InboxModel.pageSize)
        #expect(!model.reachedEnd)
        await model.loadOlder()
        #expect(model.items.count == 60)
        await model.loadOlder()
        #expect(model.items.count == 70)
        #expect(model.reachedEnd)
        await model.loadOlder()
        #expect(model.items.count == 70)

        // 新来一条：同步后在最上面，下面翻出来的都还在。
        client.update { s in
            s.inbox.insert(
                InboxItem(
                    id: "0192f3a0-0000-7000-8000-000000999999", kind: .runFinished, title: "新的", body: "",
                    createdAt: Date().addingTimeInterval(60)), at: 0)
        }
        await model.load()
        #expect(model.items.count == 71)
        #expect(model.items.first?.title == "新的")
        #expect(Set(model.items.map(\.id)).count == 71)
    }

    @Test("标已读、全部已读、标回未读、删除：未读数跟着变")
    func actions() async throws {
        let client = mock()
        let model = InboxModel(client: client)
        await model.load()
        let first = try #require(model.items.first { !$0.isRead })
        await model.markRead(first)
        #expect(model.unread == 2)
        #expect(model.items.first { $0.id == first.id }?.isRead == true)

        let read = try #require(model.items.first { $0.id == first.id })
        await model.markUnread(read)
        #expect(model.unread == 3)
        #expect(model.items.first { $0.id == first.id }?.isRead == false)

        await model.markAllRead()
        #expect(model.unread == 0)
        #expect(model.items.allSatisfy { $0.isRead })

        let victim = try #require(model.items.last)
        await model.delete(victim)
        #expect(model.items.count == 4)
        #expect(try await client.syncInbox(limit: 10).items.count == 4)
    }

    @Test("出错：标已读失败退回去、提示一句；删一条已经没有的照样拿掉")
    func failures() async throws {
        let client = mock()
        let model = InboxModel(client: client)
        await model.load()
        let item = try #require(model.items.first { !$0.isRead })
        client.failNext("markInboxRead(ids:upTo:)", with: .internal(message: "boom"))
        await model.markRead(item)
        #expect(model.items.first { $0.id == item.id }?.isRead == false)
        #expect(model.actionError == .internal(message: "boom"))
        model.clearActionError()

        try await client.deleteInboxItem(item.id)
        await model.delete(item)
        #expect(!model.items.contains { $0.id == item.id })
        #expect(model.actionError == nil)
    }

    @Test("离线：先显示缓存，同步失败时照缓存显示")
    func offline() async {
        let client = mock()
        client.failNext("syncInbox(limit:)", with: .network(message: "offline"))
        let model = InboxModel(client: client)
        await model.load()
        #expect(model.items.count == 5)
        #expect(model.unread == 3)
        #expect(model.error?.isOffline == true)
    }

    @Test("点一条去哪：和推送同一套规则；没有更具体的页面就打开它自己")
    func targets() throws {
        let inbox = DemoData.state().inbox
        let approval = try #require(inbox.first { $0.kind == .approval })
        #expect(approval.target == .approval(DemoData.pendingApprovalID))
        let vault = try #require(inbox.first { $0.kind == .vaultRequest })
        #expect(vault.target == .vaultRequest(DemoData.npmVaultRequestID))
        let finished = try #require(inbox.first { $0.kind == .runFinished })
        #expect(finished.target == .run(DemoData.digestRunID))
        let plan = try #require(inbox.first { $0.kind == .planConfirm })
        #expect(plan.target == .confirmPlan(DemoData.agentPlanID))
        let bare = InboxItem(
            id: "0192f3a0-0000-7000-8000-000000001099", kind: .info, title: "t", body: "b", createdAt: Date())
        #expect(bare.target == nil)
        var skipped = bare
        skipped.subtype = .imChannelDisabled
        #expect(skipped.target == .imChannels)
    }

    @Test("一条：打开就标已读；能标回未读、删除；不存在的说找不到")
    func item() async throws {
        let client = mock()
        let id: InboxItemID = "0192f3a0-0000-7000-8000-000000001001"
        let model = InboxItemModel(client: client, itemID: id)
        await model.load()
        #expect(model.item?.isRead == true)
        #expect(model.unread == 2)
        #expect(try await client.inboxItem(id).isRead)

        await model.markUnread()
        #expect(model.item?.isRead == false)
        #expect(model.unread == 3)

        await model.delete()
        #expect(model.isDeleted)

        let missing = InboxItemModel(client: client, itemID: id)
        await missing.load()
        #expect(missing.isMissing)
    }
}
