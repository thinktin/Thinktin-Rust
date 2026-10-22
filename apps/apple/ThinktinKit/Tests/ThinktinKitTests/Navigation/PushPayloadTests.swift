import Foundation
import Testing

@testable import ThinktinKit

// 推送的 userInfo（crates/notify/src/apns.rs 的 payload：自定义数据在 tt 下，只有种类和 id）。

@Suite("推送数据")
struct PushPayloadTests {
    @Test("解析服务端测试里的那份载荷（apns.rs sends_signed_request_with_payload）")
    func serverPayload() throws {
        // 走一遍 JSON，和 APNs 交给 App 的 userInfo 一样（嵌套的是 Foundation 的字典）。
        let json = """
            {"aps": {"alert": {"title": "写作助手", "body": "等你审批"}, "category": "APPROVAL",
                     "interruption-level": "time-sensitive", "thread-id": "run-1"},
             "tt": {"kind": "approval", "instance": "inst-1", "run": "run-1", "approval": "appr-9"}}
            """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let userInfo = try #require(object as? [AnyHashable: Any])
        let payload = try #require(PushPayload(userInfo: userInfo))
        #expect(payload.kind == .approval)
        #expect(payload.instanceID == "inst-1")
        #expect(payload.runID == "run-1")
        #expect(payload.approvalID == "appr-9")
        #expect(payload.planID == nil)
        #expect(payload.inboxItemID == nil)
        #expect(payload.route == .approval("appr-9"))
    }

    @Test("tt 是 [AnyHashable: Any] 也认；没有 tt 不是我们的推送")
    func shapes() throws {
        let anyHashable: [AnyHashable: Any] = ["tt": ["kind": "run_finished", "run": "r1"] as [AnyHashable: Any]]
        #expect(PushPayload(userInfo: anyHashable)?.route == .run("r1"))
        #expect(PushPayload(userInfo: ["aps": ["alert": "hi"]]) == nil)
        #expect(PushPayload(userInfo: ["tt": "run"]) == nil)
        // 种类缺了、认不出：按“其他提醒”处理。
        let unknown = try #require(PushPayload(userInfo: ["tt": ["kind": "new_kind", "plan": "p1"]]))
        #expect(unknown.kind == .unknown("new_kind"))
        #expect(unknown.route == .plan("p1"))
        #expect(PushPayload(userInfo: ["tt": [String: Any]()])?.route == .inbox)
    }

    @Test("不像 id 的 id 当作没有")
    func invalidIDs() throws {
        let payload = try #require(
            PushPayload(userInfo: ["tt": ["kind": "run_failed", "run": "../etc", "instance": 42, "inbox": "i1"]]))
        #expect(payload.runID == nil)
        #expect(payload.instanceID == nil)
        #expect(payload.inboxItemID == "i1")
        #expect(payload.route == .inboxItem("i1"))
    }

    @Test("点开通知去哪")
    func routes() {
        typealias P = PushPayload
        // 审批：审批详情 → 运行详情 → 审批中心。
        #expect(P(kind: .approval, runID: "r", approvalID: "a").route == .approval("a"))
        #expect(P(kind: .approval, instanceID: "i", runID: "r").route == .run("r"))
        #expect(P(kind: .approval, instanceID: "i").route == .approvals)
        #expect(P(kind: .computerApproval, approvalID: "a").route == .approval("a"))
        #expect(P(kind: .computerApproval, runID: "r").route == .approvals)
        // 运行结束：运行详情 → 实例的对话 → 收件箱的这一条 → 收件箱。
        #expect(P(kind: .runFinished, instanceID: "i", runID: "r", inboxItemID: "x").route == .run("r"))
        #expect(P(kind: .runFailed, instanceID: "i", inboxItemID: "x").route == .conversation("i"))
        #expect(P(kind: .runFailed, inboxItemID: "x").route == .inboxItem("x"))
        #expect(P(kind: .runFinished).route == .inbox)
        // 其他提醒：计划 → 运行 → 实例的对话 → 收件箱的这一条 → 收件箱。
        #expect(P(kind: .info, instanceID: "i", runID: "r", planID: "p").route == .plan("p"))
        #expect(P(kind: .info, instanceID: "i", runID: "r").route == .run("r"))
        #expect(P(kind: .info, instanceID: "i").route == .conversation("i"))
        #expect(P(kind: .info, inboxItemID: "x").route == .inboxItem("x"))
        #expect(P(kind: .info).route == .inbox)
    }

    @Test("种类的取值和服务端 PushKind::as_str 一致")
    func kinds() {
        #expect(
            PushPayload.Kind.knownCases.map(\.rawValue) == [
                "run_finished", "run_failed", "approval", "computer_approval", "info",
            ])
    }
}
