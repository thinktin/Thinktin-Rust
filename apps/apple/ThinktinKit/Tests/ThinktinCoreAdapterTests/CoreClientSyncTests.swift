import Foundation
import Testing
import ThinktinCore
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 合 backend-core f9f87b3 带进来的接口（W1 第 1.5 轮）：审批的请求 id / 尝试 / 结果、`getApproval`，计划列表带触发器
/// 和下一次运行（11.8），收件箱的子类型和保险箱请求（10.7）。字段名照 crates/proto/src/domain.rs，路由照
/// crates/gateway/src/routes/mod.rs。
@Suite("合 backend-core：审批、计划列表、收件箱子类型（经真实核心）")
struct CoreClientSyncTests {
    typealias F = AdapterFixture
    typealias R = StubHTTPServer.Response
    typealias H = CoreClientAppAPIHTTPTests

    static let created = H.created
    static let finished = H.finished

    static func approvalJSON(state: String, decided: Bool) -> String {
        let decision = decided ? #""decided_option":"o1","decided_at":"\#(finished)""# : #""decided_option":null"#
        return """
            {"id":"\(F.approvalID)","run_id":"\(F.runID)","instance_id":"\(F.instanceID)","title":"删除 build/",
             "options":[{"option_id":"o1","name":"允许","kind":"allow_once"},
                        {"option_id":"o2","name":"拒绝","kind":"reject_once"}],
             "tool_call":{"title":"rm -rf build"},"state":"\(state)","expires_at":"\(finished)",
             "created_at":"\(created)","request_id":"perm-1","attempt":2,\(decision)}
            """
    }

    // MARK: 转换

    @Test("Approval：请求 id、尝试、选了哪个、什么时候；老数据的默认值")
    func approvalConversion() {
        let decided = ThinktinKit.Approval(
            core: ThinktinCore.Approval(
                id: F.approvalID, runId: F.runID, instanceId: F.instanceID, title: "删除文件",
                options: [ThinktinCore.ApprovalOption(optionId: "o1", name: "允许", kind: "allow_once")],
                toolCallJson: "{}", state: "approved", expiresAtMs: F.finishedMs, createdAtMs: F.createdMs,
                requestId: "perm-1", attempt: 3, decidedOption: "o1", decidedAtMs: F.startedMs))
        #expect(decided.requestID == "perm-1")
        #expect(decided.attempt == 3)
        #expect(decided.decidedOption == "o1")
        #expect(decided.decidedOptionInfo?.name == "允许")
        #expect(decided.decidedAt?.unixMilliseconds == F.startedMs)

        // UniFFI 的默认值（老的服务端没给）。
        let old = ThinktinKit.Approval(
            core: ThinktinCore.Approval(
                id: F.approvalID, runId: F.runID, instanceId: F.instanceID, title: nil, options: [],
                toolCallJson: "{}", state: "pending", expiresAtMs: F.finishedMs, createdAtMs: F.createdMs))
        #expect(old.requestID.isEmpty)
        #expect(old.attempt == 0)
        #expect(old.decidedOption == nil && old.decidedOptionInfo == nil)
        #expect(old.decidedAt == nil)
    }

    @Test("InboxItem：子类型（认识的、等待原因码、不认识的、没有）和保险箱请求 id；新的种类")
    func inboxItemConversion() {
        func item(kind: String, subtype: String?, vault: String? = nil) -> ThinktinKit.InboxItem {
            ThinktinKit.InboxItem(
                core: ThinktinCore.InboxItem(
                    id: F.itemID, instanceId: nil, runId: nil, planId: nil, approvalId: nil, kind: kind, title: "t",
                    body: "b", aiGenerated: false, read: false, createdAtMs: F.createdMs, subtype: subtype,
                    vaultRequestId: vault))
        }
        let vault = item(kind: "vault_request", subtype: nil, vault: F.itemID)
        #expect(vault.kind == .vaultRequest)
        #expect(vault.vaultRequestID == VaultRequestID(F.itemID))
        #expect(vault.subtype == nil)
        #expect(item(kind: "plan_confirm", subtype: nil).kind == .planConfirm)
        #expect(item(kind: "computer_approval", subtype: nil).kind == .computerApproval)
        #expect(item(kind: "info", subtype: "account_restored").subtype == .accountRestored)
        #expect(item(kind: "info", subtype: "trigger_disabled").subtype == .triggerDisabled)
        let waiting = item(kind: "run_failed", subtype: "no_balance")
        #expect(waiting.subtype == .waiting(.noBalance))
        #expect(waiting.subtype?.waitCode == .noBalance)
        #expect(item(kind: "info", subtype: "solar_flare").subtype == .unknown("solar_flare"))
        #expect(item(kind: "info", subtype: nil).vaultRequestID == nil)
    }

    // MARK: 接口

    @Test("getApproval：GET /v1/approvals/{id}，什么状态都能查；不存在的是 not_found")
    func getApproval() async throws {
        let missing = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5aff"
        let server = try StubHTTPServer(routes: [
            "GET /v1/approvals/\(F.approvalID)": R(200, json: Self.approvalJSON(state: "approved", decided: true)),
            "GET /v1/approvals/\(missing)": R(404, json: #"{"code":"not_found","message":"no such approval"}"#),
        ])
        defer { server.stop() }
        let client = try H.client(server)

        let approval = try await client.getApproval(ApprovalID(F.approvalID))
        #expect(approval.id == ApprovalID(F.approvalID))
        #expect(approval.state == .approved)
        #expect(approval.requestID == "perm-1")
        #expect(approval.attempt == 2)
        #expect(approval.decidedOption == "o1")
        #expect(approval.decidedOptionInfo?.kind == .allowOnce)
        #expect(approval.decidedAt != nil)
        #expect(approval.options.map(\.id) == ["o1", "o2"])

        let error = await #expect(throws: ThinktinKit.ClientError.self) {
            _ = try await client.getApproval(ApprovalID(missing))
        }
        #expect(error?.isNotFound == true)
        #expect(H.routes(server) == ["GET /v1/approvals/\(F.approvalID)", "GET /v1/approvals/\(missing)"])
    }

    @Test("plans：列表也带触发器、步骤、下一次运行和失效的触发器数（11.8），停用的原因认得出来")
    func planList() async throws {
        let list = """
            {"plans":[{"id":"\(F.planID)","instance_id":"\(F.instanceID)","title":"晨报","goal":"汇总新闻",
             "policy":{"preauthorized_tools":[],"approval_timeout_secs":86400,"on_approval_timeout":"pause_plan",
                       "budget":{"max_tokens":null,"max_duration_secs":21600,"max_steps":null},
                       "daily_token_limit":null,"wait_timeout_secs":86400},
             "catch_up":"once","paused":false,"created_by":"user","created_at":"\(Self.created)","revision":1,
             "awaiting_confirmation":false,
             "triggers":[{"id":"\(F.triggerID)","plan_id":"\(F.planID)",
                          "spec":{"kind":"cron","expr":"0 8 * * *","tz":"Asia/Shanghai"},"enabled":true,
                          "next_fire_at":"\(Self.finished)","last_fire_at":null,"disabled_reason":null},
                         {"id":"\(F.itemID)","plan_id":"\(F.planID)",
                          "spec":{"kind":"cron","expr":"0 9 * * *","tz":"Mars/Olympus"},"enabled":false,
                          "next_fire_at":null,"last_fire_at":null,"disabled_reason":"invalid_rule"}],
             "steps":[{"key":"fetch","instance_id":"\(F.instanceID)","prompt":"抓新闻","depends_on":[]}],
             "next_fire_at":"\(Self.finished)","invalid_triggers":1}]}
            """
        let server = try StubHTTPServer(routes: ["GET /v1/plans": R(200, json: list)])
        defer { server.stop() }
        let client = try H.client(server)

        let plans = try await client.plans(instanceID: nil)
        let plan = try #require(plans.first)
        #expect(plan.triggers.count == 2)
        #expect(plan.triggers[0].disabledReason == nil)
        #expect(plan.triggers[1].disabledReason == .invalidRule)
        #expect(plan.triggers[1].isInvalid && !plan.triggers[1].isEnabled)
        #expect(plan.steps.map(\.key) == ["fetch"])
        #expect(plan.nextFireAt?.unixMilliseconds == F.finishedMs)
        #expect(plan.invalidTriggers == 1)
        #expect(plan.hasInvalidTriggers)
    }
}
