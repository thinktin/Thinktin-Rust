import Foundation
import Testing

@testable import ThinktinKit

// 12.5 给对话归并补的几处（ConversationReducer 的增量修改）：状态行带等待原因码、提前结束的一轮显示提示行、
// 审批记录补到已经按事件关联上的卡片上、没有文字的分片不建空的一项。

private let runA = Fixture.runA

private func statusLine(_ r: ConversationReducer) throws -> RunStatusLine {
    let turn = try #require(r.conversationTurns.first { $0.runID == runA })
    return try #require(turn.items.last?.content.runStatus)
}

@Suite("对话归并：12.5 的补充")
struct ReducerAdditionsTests {
    @Test("等 key：状态行带 run.state 的 wait_code，限流、繁忙的下一步是“稍后自动继续”")
    func waitCodeFromEvent() throws {
        var r = ConversationReducer(runs: [Fixture.run(runA)])
        var ev = Events()
        r.apply(ev.add(.runState, runA, ["state": "waiting_quota", "reason": "额度用完了", "wait_code": "no_balance"]))
        var line = try statusLine(r)
        #expect(line.waitCode == .noBalance)
        #expect(line.nextStep == .configureKey)
        r.apply(ev.add(.runState, runA, ["state": "waiting_quota", "wait_code": "rate_limited"]))
        line = try statusLine(r)
        #expect(line.waitCode == .rateLimited)
        #expect(line.nextStep == .waitForRetry)
        // 回到运行中：原因码不再显示。
        r.apply(ev.add(.runState, runA, ["state": "running"]))
        #expect(try statusLine(r).waitCode == nil)
    }

    @Test("事件没带 wait_code（先显示缓存的运行记录）：同一个状态时用运行记录里的；电脑不在线")
    func waitCodeFromRun() throws {
        var run = Fixture.run(runA, state: .waitingDevice)
        run.waitCode = .deviceOffline
        let r = ConversationReducer(runs: [run])
        let line = try statusLine(r)
        #expect(line.waitCode == .deviceOffline)
        #expect(line.nextStep == .waitForComputer)
        // 状态不对应的原因码不带。
        #expect(RunStatusLine(state: .running, waitCode: .invalid).waitCode == nil)
    }

    @Test("没有文字的分片（载荷里缺 text、是空串）：不建空的一项，也不打断前后的文字")
    func emptyChunks() {
        var r = ConversationReducer(runs: [Fixture.run(runA)])
        var ev = Events()
        r.apply(ev.add(.agentMessage, runA, ["type": "message_chunk"]))
        r.apply(ev.add(.agentThought, runA, ["text": ""]))
        #expect(r.items.compactMap(\.content.assistantText).isEmpty)
        #expect(r.items.compactMap(\.content.thought).isEmpty)
        r.apply(ev.add(.agentMessage, runA, ["text": "前半"]))
        r.apply(ev.add(.agentMessage, runA, ["text": ""]))
        r.apply(ev.add(.agentMessage, runA, ["text": "后半"]))
        #expect(r.items.compactMap(\.content.assistantText).map(\.text) == ["前半后半"])
    }

    @Test("agent.turn_ended：拒绝回答、输出到上限、步数到上限显示提示行；正常结束、取消不显示")
    func turnStopped() {
        var r = ConversationReducer(runs: [Fixture.run(runA)])
        var ev = Events()
        for reason in ["end_turn", "cancelled", "refusal", "max_tokens", "max_turn_requests"] {
            r.apply(ev.add(.turnEnded, runA, ["stop_reason": .string(reason)]))
        }
        let notices = r.items.compactMap(\.content.systemNotice).map(\.kind)
        #expect(notices == [.turnStopped(.refusal), .turnStopped(.maxTokens), .turnStopped(.maxTurnRequests)])
    }

    @Test("审批记录补到已经按 approval_id 关联上的卡片：getApproval 说已过期，卡片显示已过期")
    func recordForLinkedCard() throws {
        var r = ConversationReducer(runs: [Fixture.run(runA, state: .waitingApproval)])
        var ev = Events()
        r.apply(ev.add(.runState, runA, ["state": "running", "attempt": 1]))
        r.apply(
            ev.add(
                .permissionRequested, runA,
                [
                    "request_id": "perm-1", "title": "删除文件", "attempt": 1, "approval_id": "ap-1",
                    "options": [["option_id": "ok", "name": "允许", "kind": "allow_once"]],
                ]))
        var card = try #require(r.items.compactMap(\.content.approval).first)
        #expect(card.isPending && card.approvalID == "ap-1")
        let expired = Approval(
            id: "ap-1", runID: runA, instanceID: Fixture.instanceID, title: "删除文件", options: [],
            state: .expired, expiresAt: Fixture.now, createdAt: Fixture.now, requestID: "perm-1", attempt: 1)
        r.link(approvals: [expired])
        card = try #require(r.items.compactMap(\.content.approval).first)
        #expect(card.resolution?.outcome == .expired)
        // 再来一次（重复查到同一条）不出错、结论不变。
        r.link(approvals: [expired])
        #expect(r.items.compactMap(\.content.approval).first?.resolution?.outcome == .expired)
    }

    @Test("审批记录补到已关联的卡片：卡片已经有用户的结论时只补上记录的结果，不改结论")
    func recordKeepsDecision() throws {
        var r = ConversationReducer(runs: [Fixture.run(runA)])
        var ev = Events()
        r.apply(
            ev.add(
                .permissionRequested, runA,
                [
                    "request_id": "perm-1", "attempt": 1, "approval_id": "ap-1",
                    "options": [["option_id": "ok", "name": "允许", "kind": "allow_once"]],
                ]))
        r.apply(
            ev.add(
                .permissionResolved, runA,
                ["request_id": "perm-1", "option_id": "ok", "by": "user", "attempt": 1, "approval_id": "ap-1"]))
        let approved = Approval(
            id: "ap-1", runID: runA, instanceID: Fixture.instanceID, title: nil, options: [], state: .approved,
            expiresAt: Fixture.now, createdAt: Fixture.now, requestID: "perm-1", attempt: 1, decidedOption: "ok")
        r.link(approvals: [approved])
        let card = try #require(r.items.compactMap(\.content.approval).first)
        #expect(card.resolution?.outcome == .approvedByUser)
        #expect(card.resolution?.state == .approved)
    }
}
