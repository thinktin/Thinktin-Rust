import Foundation
import Testing

@testable import ThinktinKit

// 应用框架接上 backend-core f9f87b3（W1 第 1.5 轮）：推送的子类型（账号冻结、解冻、全部停止，docs/push.md 第 4 节）、
// 事件流以 upgradeRequired 结束、ObservedClient 转发 getApproval。

@MainActor
@Suite("应用框架：推送的子类型、事件流说要升级")
struct AppModelPushTests {
    private func make() -> (MockClient, AppModel) {
        let mock = makeShellMock()
        return (mock, AppModel(client: mock, defaults: nil))
    }

    @Test("account_frozen：显示冻结页，点开的推送等解冻后再跳")
    func accountFrozenPush() async {
        let (mock, model) = make()
        await model.start()
        let push = PushPayload(
            kind: .info, subtype: .accountFrozen, inboxItemID: "0192f3a0-0000-7000-8000-000000001009")
        mock.update { $0.user.status = .frozen }
        await model.open(push: push)
        #expect(model.phase == .frozen)
        #expect(model.router.pendingRoute?.route == .inboxItem("0192f3a0-0000-7000-8000-000000001009"))
        #expect(model.router.path.isEmpty)

        // 解冻的推送：重查账号，回到正常，记下的页面跳过去，页面重新订阅。
        let before = model.resubscribeRequest
        mock.update { $0.user.status = .active }
        await model.receive(push: PushPayload(kind: .info, subtype: .accountRestored))
        #expect(model.phase == .signedIn)
        #expect(model.resubscribeRequest == before + 1)
        #expect(model.router.path == [.inboxItem("0192f3a0-0000-7000-8000-000000001009")])
        #expect(model.instances.count == 2)
    }

    @Test("account_frozen：没登录、已经冻结时不动；晚到的旧推送回到前台时重查掉")
    func staleFrozenPush() async {
        let (_, model) = make()
        await model.start()
        await model.receive(push: PushPayload(kind: .info, subtype: .accountFrozen))
        #expect(model.phase == .frozen)
        // 服务端说没冻结（推送晚到了）：回到前台时重查，回到正常。
        await model.sceneDidBecomeActive()
        #expect(model.phase == .signedIn)

        let signedOut = AppModel(client: makeShellMock(signedIn: false), defaults: nil)
        await signedOut.receive(push: PushPayload(kind: .info, subtype: .accountFrozen))
        #expect(signedOut.phase == .signedOut)
    }

    @Test("account_restored：已经在正常状态时确认账号、让页面重新订阅、刷新实例和角标（同步收件箱）")
    func accountRestoredWhileSignedIn() async {
        let (mock, model) = make()
        await model.start()
        #expect(model.badges.inboxUnread == 3)
        mock.update { s in
            s.inbox.insert(
                InboxItem(
                    id: "0192f3a0-0000-7000-8000-000000001010", kind: .info, subtype: .accountRestored,
                    title: "账号已恢复", body: "", createdAt: Date()), at: 0)
        }
        let before = model.resubscribeRequest
        await model.receive(push: PushPayload(kind: .info, subtype: .accountRestored))
        #expect(model.phase == .signedIn)
        #expect(model.resubscribeRequest == before + 1)
        #expect(model.badges.inboxUnread == 4, "同步了收件箱")

        // 还冻着：留在冻结页。
        mock.update { $0.user.status = .frozen }
        model.handle(ClientError.accountFrozen)
        #expect(model.phase == .frozen)
        await model.receive(push: PushPayload(kind: .info, subtype: .accountRestored))
        #expect(model.phase == .frozen)
    }

    @Test("stopped_all：刷新角标；别的子类型不动账号状态")
    func stoppedAllPush() async {
        let (mock, model) = make()
        await model.start()
        #expect(model.badges.activeRuns == 2)
        mock.update { s in
            for i in s.runs.indices where s.runs[i].state.isActive { s.runs[i].state = .cancelled }
        }
        await model.receive(push: PushPayload(kind: .info, subtype: .stoppedAll))
        #expect(model.badges.activeRuns == 0)
        await model.receive(push: PushPayload(kind: .info, subtype: .triggerDisabled, planID: DemoData.digestPlanID))
        #expect(model.phase == .signedIn)
        // 点开：直接跳（不经过账号处理）。
        await model.open(push: PushPayload(kind: .planConfirm, planID: DemoData.agentPlanID))
        #expect(model.router.path == [.confirmPlan(DemoData.agentPlanID)])
    }

    @Test("事件流以 upgradeRequired 结束：进升级页，所有事件流停掉，之后不能再订阅")
    func streamEndsWithUpgradeRequired() async throws {
        let (mock, model) = make()
        await model.start()
        let writer = StatusCollector()
        let reviewer = StatusCollector()
        let handles = [
            try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: writer),
            try model.client.subscribe(instanceID: DemoData.reviewerID, afterSeq: nil, listener: reviewer),
        ]
        #expect(await writer.wait(for: .live))
        #expect(await reviewer.wait(for: .live))
        // 不改 Mock 的 isUpgradeRequired：只凭事件流的状态就要进升级页（不再从 stopped + upgradeRequired() 推断）。
        mock.play(MockEventScript(steps: [.status(.upgradeRequired)]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await eventually { model.phase == .upgradeRequired })
        #expect(await reviewer.wait(for: .upgradeRequired))
        #expect((model.client as? ObservedClient)?.activeStreamCount == 0)
        #expect(model.client.upgradeRequired())
        #expect(throws: ClientError.upgradeRequired) {
            try model.client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: StatusCollector())
        }
        #expect(model.connection == .idle)
        // 升级页是终点：推送也不再切换。
        await model.receive(push: PushPayload(kind: .info, subtype: .accountRestored))
        #expect(model.phase == .upgradeRequired)
        for handle in handles { handle.stop() }
    }

    @Test("ObservedClient 转发 getApproval；不存在的是 not_found，照样报出去")
    func forwardsGetApproval() async throws {
        let mock = makeShellMock()
        let log = ActivityLog()
        let client = ObservedClient(mock) { log.record($0) }
        let approval = try await client.getApproval(DemoData.pendingApprovalID)
        #expect(approval == (try await mock.getApproval(DemoData.pendingApprovalID)))
        #expect(approval.requestID == DemoData.pendingPermissionRequestID)
        #expect(approval.attempt == 1)
        do {
            _ = try await client.getApproval("0192f3a0-0000-7000-8000-00000000ffff")
            Issue.record("应该抛 not_found")
        } catch let error as ClientError {
            #expect(error.isNotFound)
        }
        #expect(log.failures.last?.isNotFound == true)
    }
}
