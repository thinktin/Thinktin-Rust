import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("审批中心与审批详情（12.15）")
struct ApprovalCenterTests {
    private func mock(_ state: MockState = DemoData.state()) -> MockClient {
        MockClient(state: state, stepDelay: 0)
    }

    private var pendingID: ApprovalID { DemoData.pendingApprovalID }

    @Test("列出待处理的：实例名、快过期的在前；页面开着时到期的不再显示")
    func list() async throws {
        var state = DemoData.state()
        var soon = try #require(state.approvals.first)
        soon.id = "approval-soon"
        soon.instanceID = DemoData.reviewerID
        soon.expiresAt = Date().addingTimeInterval(600)
        var done = soon
        done.id = "approval-done"
        done.state = .approved
        state.approvals += [soon, done]
        let model = ApprovalCenterModel(client: mock(state))
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.visible().map(\.id) == ["approval-soon", pendingID])
        #expect(model.instanceName(DemoData.writerID) == "写作助手")
        #expect(model.instanceName(DemoData.reviewerID) == "代码审查")
        #expect(model.visible(now: Date().addingTimeInterval(3600)).map(\.id) == [pendingID])
    }

    @Test("批准先过本机验证，决定后从列表拿掉、提示一句")
    func approve() async throws {
        let client = mock()
        let gate = ScriptedBiometricGate()
        let model = ApprovalCenterModel(client: client, biometricGate: gate)
        await model.load()
        let approval = try #require(model.visible().first)
        let allow = try #require(approval.options.first { $0.kind == .allowOnce })
        await model.decide(approval, option: allow, reason: "批准：发消息")
        #expect(gate.reasons == ["批准：发消息"])
        #expect(model.visible().isEmpty)
        guard case .decided(let record, let option)? = model.notice else {
            Issue.record("没有提示：\(String(describing: model.notice))")
            return
        }
        #expect(record.state == .approved && option == allow)
        #expect(try await client.getApproval(pendingID).state == .approved)
        #expect(ApprovalsText.notice(model.notice!, language: .chinese).hasPrefix("已批准"))
    }

    @Test("拒绝不用本机验证")
    func reject() async throws {
        let client = mock()
        let gate = ScriptedBiometricGate()
        let model = ApprovalCenterModel(client: client, biometricGate: gate)
        await model.load()
        let approval = try #require(model.visible().first)
        let reject = try #require(approval.options.first { $0.kind.isReject })
        await model.decide(approval, option: reject, reason: "")
        #expect(gate.reasons.isEmpty)
        #expect(try await client.getApproval(pendingID).state == .rejected)
    }

    @Test("本机验证取消了什么都不做；没通过提示一句、不批准")
    func verification() async throws {
        let client = mock()
        let gate = ScriptedBiometricGate(result: .cancelled)
        let model = ApprovalCenterModel(client: client, biometricGate: gate)
        await model.load()
        let approval = try #require(model.visible().first)
        await model.decide(approval, option: approval.options[0], reason: "批准")
        #expect(model.errors.isEmpty && model.notice == nil)
        gate.result = .failed
        await model.decide(approval, option: approval.options[0], reason: "批准")
        #expect(model.errors[pendingID] == .verificationFailed)
        #expect(model.visible().count == 1)
        #expect(try await client.getApproval(pendingID).isPending)
    }

    @Test("别处已经处理过：拿掉、说一声，不算出错；接口出错留在列表上")
    func handledElsewhere() async throws {
        let client = mock()
        let model = ApprovalCenterModel(client: client)
        await model.load()
        let approval = try #require(model.visible().first)
        client.failNext("decideApproval(_:optionID:)", with: .network(message: "offline"))
        await model.decide(approval, option: approval.options[0], reason: "")
        #expect(model.errors[pendingID] == .client(.network(message: "offline")))
        #expect(model.visible().count == 1)
        _ = try await client.decideApproval(pendingID, optionID: "reject")
        await model.decide(approval, option: approval.options[0], reason: "")
        #expect(model.visible().isEmpty)
        #expect(model.errors.isEmpty)
        guard case .alreadyHandled(let latest)? = model.notice else {
            Issue.record("没有提示：\(String(describing: model.notice))")
            return
        }
        #expect(latest.state == .rejected)
    }

    @Test("详情：待处理的能决定；处理完显示结论")
    func detail() async throws {
        let client = mock()
        let model = ApprovalDetailModel(client: client, approvalID: pendingID)
        await model.load()
        #expect(model.instanceName == "写作助手")
        #expect(model.canDecide && model.outcome == nil)
        let allow = try #require(model.approval?.options.first { $0.kind.isAllow })
        await model.decide(option: allow, reason: "")
        #expect(!model.canDecide)
        #expect(model.outcome == .approvedByUser)
        #expect(model.approval?.decidedOptionInfo == allow)
    }

    @Test("决定冲突后查最新状态断网，保留待审批项以便重试")
    func conflictThenOffline() async throws {
        let client = mock()
        let model = ApprovalCenterModel(client: client)
        await model.load()
        let pending = try #require(model.visible().first)
        let option = try #require(pending.options.first { $0.kind.isReject })
        client.failNext(
            "decideApproval(_:optionID:)", with: .api(status: 409, code: .conflict, message: "", retryAfterSecs: nil))
        client.failNext("getApproval(_:)", with: .network(message: "offline"))
        await model.decide(pending, option: option, reason: "")
        #expect(model.visible().contains { $0.id == pending.id })
        #expect(model.errors[pending.id] == .client(.network(message: "offline")))
        #expect(model.notice == nil)
    }

    @Test("详情：推送进来时已经处理过、过期了的显示结论；不存在的说找不到")
    func detailStates() async throws {
        let client = mock()
        _ = client.expireApproval(pendingID)
        let expired = ApprovalDetailModel(client: client, approvalID: pendingID)
        await expired.load()
        #expect(!expired.canDecide)
        #expect(expired.outcome == .expired)
        #expect(expired.error == nil)

        let missing = ApprovalDetailModel(client: client, approvalID: "approval-gone")
        await missing.load()
        #expect(missing.isMissing)

        // 打开时还待处理，决定前在别处处理了。
        let fresh = mock()
        let model = ApprovalDetailModel(client: fresh, approvalID: pendingID)
        await model.load()
        _ = try await fresh.decideApproval(pendingID, optionID: "allow")
        await model.decide(option: try #require(model.approval?.options.last), reason: "")
        #expect(model.handledElsewhere)
        #expect(model.outcome == .approvedByUser)
        #expect(model.decideError == nil)

        // 决定时冲突、再查已经查不到：说找不到，不留一条还能点的待处理。
        let gone = mock()
        let vanished = ApprovalDetailModel(client: gone, approvalID: pendingID)
        await vanished.load()
        gone.failNext(
            "decideApproval(_:optionID:)", with: .api(status: 409, code: .conflict, message: "", retryAfterSecs: nil))
        gone.failNext("getApproval(_:)", with: .api(status: 404, code: .notFound, message: "", retryAfterSecs: nil))
        await vanished.decide(option: try #require(vanished.approval?.options.first), reason: "")
        #expect(vanished.isMissing)
        #expect(vanished.decideError == nil)
    }
}
