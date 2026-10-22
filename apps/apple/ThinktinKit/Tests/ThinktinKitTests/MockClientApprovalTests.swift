import Foundation
import Testing

@testable import ThinktinKit

// MockClient 照平台的规则给审批事件加键（11.8，docs/agent-integration.md 第 6 节）：permission_requested 带 attempt、
// approval_id，permission_resolved 带 attempt、approval_id、approval_state，approval.decided 带 request_id、attempt；
// 旧尝试没处理的审批作废；getApproval 什么状态都能查。归并器拿这些事件对得上卡片。

@Suite("MockClient：审批的请求 id、尝试和结果（11.8）")
struct MockClientApprovalTests {
    private let writer = DemoData.writerID
    private let run = DemoData.postRunID

    private func makeClient() -> MockClient {
        MockClient(state: DemoData.state(), stepDelay: 0, autoReply: false)
    }

    private func requested(_ mock: MockClient, _ requestID: String, title: String) -> InstanceEvent {
        mock.emit(
            .permissionRequested,
            payload: [
                "request_id": .string(requestID), "title": .string(title),
                "options": [["option_id": "ok", "name": "允许", "kind": "allow_once"]],
            ], runID: run, instanceID: writer)
    }

    @Test("演示数据：等审批的那条带请求 id、第 1 次尝试；事件里带着审批 id")
    func demoData() async throws {
        let mock = makeClient()
        let approval = try await mock.getApproval(DemoData.pendingApprovalID)
        #expect(approval.requestID == DemoData.pendingPermissionRequestID)
        #expect(approval.attempt == 1)
        #expect(approval.isPending)
        #expect(approval.decidedOption == nil && approval.decidedAt == nil)
        let event = try #require(
            mock.state.events[writer]?.last { $0.kind == .permissionRequested && $0.runID == run })
        guard case .permissionRequested(let p) = event.payload else {
            Issue.record("载荷没解析出来")
            return
        }
        #expect(p.approvalID == DemoData.pendingApprovalID)
        #expect(p.attempt == 1)
        let inbox = mock.state.inbox
        #expect(inbox.contains { $0.kind == .vaultRequest && $0.vaultRequestID == DemoData.npmVaultRequestID })
        #expect(inbox.contains { $0.kind == .planConfirm && $0.planID == DemoData.agentPlanID })
    }

    @Test("permission_requested：先建审批（带请求 id 和尝试），事件带上 attempt、approval_id")
    func requestedCarriesKeys() async throws {
        let mock = makeClient()
        let event = requested(mock, "perm-7", title: "删除 dist/")
        guard case .permissionRequested(let p) = event.payload else {
            Issue.record("载荷没解析出来")
            return
        }
        let id = try #require(p.approvalID)
        #expect(p.attempt == 1)
        let approval = try await mock.getApproval(id)
        #expect(approval.requestID == "perm-7")
        #expect(approval.attempt == 1)
        #expect(approval.title == "删除 dist/")
        #expect(mock.state.inbox.first?.approvalID == id)
    }

    @Test("决定：记下选了哪个、什么时候；approval.decided 带请求 id 和尝试，之后的 resolved 带 approval_state")
    func decide() async throws {
        let mock = makeClient()
        let decided = try await mock.decideApproval(DemoData.pendingApprovalID, optionID: "allow")
        #expect(decided.state == .approved)
        #expect(decided.decidedOption == "allow")
        #expect(decided.decidedAt != nil)
        #expect(decided.decidedOptionInfo?.kind == .allowOnce)
        // getApproval 什么状态都能查（approvals() 只列待处理的）。
        #expect(try await mock.getApproval(DemoData.pendingApprovalID) == decided)
        #expect(try await mock.approvals().isEmpty)
        await mock.waitForPlayback()

        let events = mock.state.events[writer] ?? []
        let decision = try #require(events.last { $0.kind == .approvalDecided })
        guard case .approvalDecided(let d) = decision.payload else {
            Issue.record("载荷没解析出来")
            return
        }
        #expect(d.requestID == DemoData.pendingPermissionRequestID)
        #expect(d.attempt == 1)
        let resolved = try #require(events.last { $0.kind == .permissionResolved })
        guard case .permissionResolved(let r) = resolved.payload else {
            Issue.record("载荷没解析出来")
            return
        }
        #expect(r.approvalID == DemoData.pendingApprovalID)
        #expect(r.attempt == 1)
        #expect(r.approvalState == .approved)

        let reducer = Conversation.build(runs: mock.state.runs, events: events)
        let card = try #require(
            reducer.compactMap { item -> ApprovalCard? in
                if case .approval(let c) = item.content, c.approvalID == DemoData.pendingApprovalID { return c }
                return nil
            }.first)
        #expect(card.resolution?.outcome == .approvedByUser)
        #expect(await code { _ = try await mock.getApproval("0192f3a0-0000-7000-8000-00000000ffff") } == .notFound)
    }

    @Test("平台判的超时：审批过期、提醒标已读，resolved 是 by: user + approval_state: expired，卡片显示已过期")
    func expire() async throws {
        let mock = makeClient()
        let expired = try #require(mock.expireApproval(DemoData.pendingApprovalID))
        #expect(expired.state == .expired)
        #expect(expired.decidedOption == nil)
        #expect(expired.decidedAt != nil)
        #expect(mock.expireApproval(DemoData.pendingApprovalID) == nil, "已经不是待处理的")
        #expect(mock.state.inbox.first { $0.approvalID == DemoData.pendingApprovalID }?.isRead == true)
        #expect(await code { _ = try await mock.decideApproval(DemoData.pendingApprovalID, optionID: "allow") } == .conflict)

        let events = mock.state.events[writer] ?? []
        let resolved = try #require(events.last { $0.kind == .permissionResolved })
        guard case .permissionResolved(let r) = resolved.payload else {
            Issue.record("载荷没解析出来")
            return
        }
        #expect(r.by == .user)
        #expect(r.approvalState == .expired)
        let card = try #require(
            Conversation.build(runs: mock.state.runs, events: events).compactMap { item -> ApprovalCard? in
                if case .approval(let c) = item.content { return c }
                return nil
            }.last)
        #expect(card.resolution?.outcome == .expired)
    }

    @Test("新的尝试开始：旧尝试没处理的审批作废；两次尝试各一个 perm-1，归并成两张卡片")
    func retryCancelsOldAttempt() async throws {
        let mock = makeClient()
        mock.emit(.runState, payload: ["state": "running", "attempt": 1], runID: run, instanceID: writer)
        let first = requested(mock, "perm-1", title: "第一次")
        mock.emit(.runState, payload: ["state": "backoff", "attempt": 1], runID: run, instanceID: writer)
        mock.emit(.runState, payload: ["state": "running", "attempt": 2], runID: run, instanceID: writer)
        let second = requested(mock, "perm-1", title: "第二次")
        guard case .permissionRequested(let p1) = first.payload, case .permissionRequested(let p2) = second.payload
        else {
            Issue.record("载荷没解析出来")
            return
        }
        let id1 = try #require(p1.approvalID)
        let id2 = try #require(p2.approvalID)
        #expect(id1 != id2)
        #expect(p2.attempt == 2)
        #expect(try await mock.getApproval(id1).state == .cancelled)
        #expect(try await mock.getApproval(id2).state == .pending)
        #expect(try await mock.approvals().map(\.id).contains(id2))
        #expect(!(try await mock.approvals().map(\.id).contains(id1)))

        let cards = Conversation.build(runs: mock.state.runs, events: mock.state.events[writer] ?? []).compactMap {
            item -> ApprovalCard? in
            if case .approval(let c) = item.content, c.requestID == "perm-1" { return c }
            return nil
        }
        #expect(cards.map(\.approvalID) == [id1, id2])
        #expect(cards.map(\.attempt) == [1, 2])
        #expect(cards[0].resolution?.outcome == .cancelled)
        #expect(cards[1].isPending)
    }

    private func code(_ body: () async throws -> Void) async -> APIErrorCode? {
        do {
            try await body()
            return nil
        } catch let error as ClientError {
            return error.apiCode
        } catch {
            return nil
        }
    }
}
