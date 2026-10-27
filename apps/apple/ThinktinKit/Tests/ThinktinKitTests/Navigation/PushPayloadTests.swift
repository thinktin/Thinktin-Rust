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

    @Test("10.7：保险箱请求、计划待确认、子类型（docs/push.md 第 3、4 节的载荷）")
    func pushDetails() throws {
        let json = """
            {"aps": {"alert": {"title": "代码审查", "body": "需要 npm 的账号密码"}, "category": "VAULT_REQUEST",
                     "interruption-level": "time-sensitive", "badge": 3},
             "tt": {"kind": "vault_request", "instance": "inst-1", "run": "run-1", "inbox": "in-1",
                    "vault_request": "vreq-1"}}
            """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let userInfo = try #require(object as? [AnyHashable: Any])
        let vault = try #require(PushPayload(userInfo: userInfo))
        #expect(vault.kind == .vaultRequest)
        #expect(vault.vaultRequestID == "vreq-1")
        #expect(vault.subtype == nil)
        #expect(vault.route == .vaultRequest("vreq-1"))

        let confirm = try #require(PushPayload(userInfo: ["tt": ["kind": "plan_confirm", "plan": "p1"]]))
        #expect(confirm.kind == .planConfirm)
        #expect(confirm.route == .confirmPlan("p1"))

        let restored = try #require(PushPayload(userInfo: ["tt": ["kind": "info", "subtype": "account_restored"]]))
        #expect(restored.subtype == .accountRestored)
        #expect(restored.subtype?.changesAccountState == true)
        let waiting = try #require(
            PushPayload(userInfo: ["tt": ["kind": "run_failed", "subtype": "invalid", "run": "r1"]]))
        #expect(waiting.subtype == .waiting(.invalid))
        #expect(waiting.route == .run("r1"))
        // 不认识的子类型原样保留、按种类跳；空的、不是字符串的当作没有。
        let future = try #require(
            PushPayload(userInfo: ["tt": ["kind": "info", "subtype": "quota_soon", "plan": "p1"]]))
        #expect(future.subtype == .unknown("quota_soon"))
        #expect(future.route == .plan("p1"))
        #expect(PushPayload(userInfo: ["tt": ["kind": "info", "subtype": " "]])?.subtype == nil)
        #expect(PushPayload(userInfo: ["tt": ["kind": "info", "subtype": 7]])?.subtype == nil)
        // 不像 id 的保险箱请求 id 当作没有。
        #expect(
            PushPayload(userInfo: ["tt": ["kind": "vault_request", "vault_request": "a/b"]])?.vaultRequestID == nil)
    }

    @Test("10.7 的种类和子类型去哪")
    func detailRoutes() {
        typealias P = PushPayload
        // 保险箱请求：填写请求页 → 运行详情 → 实例的对话 → 收件箱的这一条 → 收件箱。
        #expect(P(kind: .vaultRequest, runID: "r", vaultRequestID: "v").route == .vaultRequest("v"))
        #expect(P(kind: .vaultRequest, instanceID: "i", runID: "r").route == .run("r"))
        #expect(P(kind: .vaultRequest, instanceID: "i").route == .conversation("i"))
        #expect(P(kind: .vaultRequest, inboxItemID: "x").route == .inboxItem("x"))
        // 计划待确认：确认页；没有计划 id 时去计划列表（那里有“待确认”分区）。
        #expect(P(kind: .planConfirm, instanceID: "i", planID: "p").route == .confirmPlan("p"))
        #expect(P(kind: .planConfirm, instanceID: "i").route == .plans)
        // 子类型：审批超时跳过的进运行详情（不是计划），IM 渠道停用的进 IM 渠道设置，触发规则失效的进计划详情。
        #expect(P(kind: .info, subtype: .approvalSkipped, runID: "r", approvalID: "a", planID: "p").route == .run("r"))
        #expect(P(kind: .info, subtype: .approvalSkipped, approvalID: "a").route == .approval("a"))
        #expect(P(kind: .info, subtype: .imChannelDisabled, inboxItemID: "x").route == .imChannels)
        #expect(P(kind: .info, subtype: .triggerDisabled, planID: "p").route == .plan("p"))
        #expect(P(kind: .info, subtype: .accountFrozen, inboxItemID: "x").route == .inboxItem("x"))
        // 确认页属于计划（12.6），压栈打开，离线时没有缓存。
        #expect(AppRoute.confirmPlan("p").feature == .plans)
        #expect(AppRoute.confirmPlan("p").presentation == .push)
        #expect(AppRoute.confirmPlan("p").offlinePolicy == .unavailable)
        #expect(AppRoute.confirmPlan("p").title(.chinese) == "确认计划")
        #expect(AppRoute.confirmPlan("p").title(.english) == "Review plan")
    }

    @Test("子类型的取值和 docs/push.md 第 4 节一致")
    func subtypes() {
        #expect(
            NotificationSubtype.knownCases.map(\.rawValue) == [
                "account_frozen", "account_restored", "stopped_all", "approval_skipped", "trigger_disabled",
                "im_channel_disabled", "report_handled", "invalid", "no_balance", "unavailable", "rate_limited",
                "overloaded", "device_offline",
            ])
        for subtype in NotificationSubtype.knownCases {
            #expect(NotificationSubtype(rawValue: subtype.rawValue) == subtype)
        }
        #expect(NotificationSubtype(rawValue: "device_offline").waitCode == .deviceOffline)
        #expect(NotificationSubtype.accountFrozen.waitCode == nil)
        #expect(!NotificationSubtype.stoppedAll.changesAccountState)
    }

    @Test("种类的取值和服务端 PushKind::as_str 一致")
    func kinds() {
        #expect(
            PushPayload.Kind.knownCases.map(\.rawValue) == [
                "run_finished", "run_failed", "approval", "computer_approval", "vault_request", "plan_confirm", "info",
            ])
        // 收件箱条目的种类和推送一样（docs/push.md 第 2 节）。
        #expect(InboxKind.knownCases.map(\.rawValue) == PushPayload.Kind.knownCases.map(\.rawValue))
    }
}
