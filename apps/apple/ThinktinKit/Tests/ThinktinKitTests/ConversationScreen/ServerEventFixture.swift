import Foundation
import Testing

@testable import ThinktinKit

/// 照服务端写运行日志的原样摆的一串事件（WBS 12.5 “与安卓共用的事件夹具”的草稿）：
///
/// - `agent.*` 是 `proto::shim::ShimEvent` 序列化的（带 `type`、`run_id`，crates/orchestrator/src/executor.rs 的
///   `persist`），审批事件另外带 `attempt`、`approval_id`、`approval_state`（`join_keys`）；文字是攒过的
///   `{type: message_chunk, text}`（`flush`）；
/// - `run.state`（executor.rs、pipeline.rs、gateway 的 routes/runs.rs）、`approval.decided`（routes/approvals.rs）、
///   `vault.*`（orchestrator/src/vault.rs、gateway 的 routes/vault.rs）、`artifact.published`、`delegate.started`、
///   `pipeline.step_started`、`plan.*`（orchestrator/src/tools.rs）、`instance.state`（crates/control）照各自的
///   `append_event` 写；
/// - 还有一条服务端以后才会有的种类（`agent.future_thing`）：要安全忽略。
///
/// 以后 crates/e2e 导出真实的夹具（docs/ios-packages.md 审查结论二.7）时换成读那个文件，这里的断言照用。
enum ServerEventFixture {
    static let instance: InstanceID = "inst-fixture"
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// 一行一条：`seq`、`run_id`、`kind`、`payload`（服务端的 JSON 原样）。
    static let lines = #"""
        {"seq":1,"run_id":null,"kind":"instance.state","payload":{"state":"provisioning"}}
        {"seq":2,"run_id":"r1","kind":"run.state","payload":{"state":"starting","reason":null,"attempt":1}}
        {"seq":3,"run_id":"r1","kind":"agent.ready","payload":{"type":"ready","protocol_version":1,"agent_id":"claude","harness":"claude-code","agent_info":null,"session_id":"s1","session_restored":false}}
        {"seq":4,"run_id":"r1","kind":"agent.turn_started","payload":{"type":"turn_started","run_id":"r1"}}
        {"seq":5,"run_id":"r1","kind":"run.state","payload":{"state":"running","reason":null,"attempt":1}}
        {"seq":6,"run_id":"r1","kind":"agent.thought","payload":{"type":"thought_chunk","text":"先看看笔记。"}}
        {"seq":7,"run_id":"r1","kind":"agent.plan","payload":{"type":"plan","run_id":"r1","entries":[{"content":"读笔记","priority":"high","status":"in_progress"},{"content":"写周报","priority":"medium","status":"pending"}]}}
        {"seq":8,"run_id":"r1","kind":"agent.tool_call","payload":{"type":"tool_call","run_id":"r1","tool_call_id":"call_1","title":"Read notes/weekly.md","kind":"read","status":"pending","raw":{"toolCallId":"call_1","title":"Read notes/weekly.md","kind":"read","status":"pending","rawInput":{"path":"notes/weekly.md"},"locations":[{"path":"notes/weekly.md"}]}}}
        {"seq":9,"run_id":"r1","kind":"agent.tool_call_update","payload":{"type":"tool_call_update","run_id":"r1","tool_call_id":"call_1","status":"completed","raw":{"toolCallId":"call_1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"# 周报草稿"}}]}}}
        {"seq":10,"run_id":"r1","kind":"agent.message","payload":{"type":"message_chunk","text":"## 本周\n\n- 事件流续传做完了\n"}}
        {"seq":11,"run_id":"r1","kind":"agent.platform_tool_call","payload":{"type":"platform_tool_call","run_id":"r1","call_id":"pc_1","name":"schedule_create","arguments":{"title":"每周一提醒","prompt":"整理周报","cron":"0 9 * * 1"}}}
        {"seq":12,"run_id":"r1","kind":"plan.needs_confirmation","payload":{"plan_id":"p1","title":"每周一提醒","change":"created"}}
        {"seq":13,"run_id":"r1","kind":"artifact.published","payload":{"artifact_id":"a1","name":"weekly.md","version":1,"size":2048}}
        {"seq":14,"run_id":"r1","kind":"agent.usage","payload":{"type":"usage","run_id":"r1","raw":{"input_tokens":1200,"output_tokens":340}}}
        {"seq":15,"run_id":"r1","kind":"agent.message","payload":{"type":"message_chunk","text":"- 发版说明还没写\n"}}
        {"seq":16,"run_id":"r1","kind":"agent.turn_ended","payload":{"type":"turn_ended","run_id":"r1","stop_reason":"end_turn"}}
        {"seq":17,"run_id":"r1","kind":"run.state","payload":{"state":"succeeded","reason":null,"attempt":1}}
        {"seq":18,"run_id":"r2","kind":"run.state","payload":{"state":"running","reason":null,"attempt":1}}
        {"seq":19,"run_id":"r2","kind":"agent.permission_requested","payload":{"type":"permission_requested","run_id":"r2","request_id":"perm-1","title":"运行 git push","options":[{"option_id":"allow","name":"允许","kind":"allow_once"},{"option_id":"always","name":"总是允许","kind":"allow_always"},{"option_id":"reject","name":"拒绝","kind":"reject_once"}],"tool_call":{"toolCallId":"call_9","title":"git push","kind":"execute","rawInput":{"command":["git","push"]}},"attempt":1,"approval_id":"ap1"}}
        {"seq":20,"run_id":"r2","kind":"run.state","payload":{"state":"waiting_approval","reason":"运行 git push","attempt":1}}
        {"seq":21,"run_id":"r2","kind":"approval.decided","payload":{"approval_id":"ap1","state":"approved","option_id":"allow","request_id":"perm-1","attempt":1}}
        {"seq":22,"run_id":"r2","kind":"agent.permission_resolved","payload":{"type":"permission_resolved","run_id":"r2","request_id":"perm-1","option_id":"allow","by":"user","attempt":1,"approval_id":"ap1","approval_state":"approved"}}
        {"seq":23,"run_id":"r2","kind":"run.state","payload":{"state":"running","reason":null,"attempt":1}}
        {"seq":24,"run_id":"r2","kind":"agent.error","payload":{"type":"error","run_id":"r2","message":"connection reset by peer"}}
        {"seq":25,"run_id":"r2","kind":"agent.exited","payload":{"type":"agent_exited","code":137,"will_restart":true,"restarts":1}}
        {"seq":26,"run_id":"r2","kind":"agent.session_lost","payload":{"type":"session_lost","previous_session_id":"s-old","reason":"session not found"}}
        {"seq":27,"run_id":"r2","kind":"run.state","payload":{"state":"backoff","reason":"agent exited","attempt":1}}
        {"seq":28,"run_id":"r2","kind":"run.state","payload":{"state":"running","reason":null,"attempt":2}}
        {"seq":29,"run_id":"r2","kind":"agent.permission_requested","payload":{"type":"permission_requested","run_id":"r2","request_id":"perm-1","title":"运行 git push","options":[{"option_id":"allow","name":"允许","kind":"allow_once"},{"option_id":"reject","name":"拒绝","kind":"reject_once"}],"tool_call":{"toolCallId":"call_9","title":"git push","kind":"execute"},"attempt":2,"approval_id":"ap2"}}
        {"seq":30,"run_id":"r2","kind":"run.state","payload":{"state":"waiting_approval","reason":"运行 git push","attempt":2}}
        {"seq":31,"run_id":"r3","kind":"run.state","payload":{"state":"waiting_quota","reason":"DeepSeek 的 key 无效，请换一把","attempt":1,"wait_code":"invalid"}}
        {"seq":32,"run_id":"r4","kind":"run.state","payload":{"state":"running","reason":null,"attempt":1}}
        {"seq":33,"run_id":"r4","kind":"vault.requested","payload":{"request_id":"vr1","name":"npm","purpose":"发布到 npm","fields":["username","password"]}}
        {"seq":34,"run_id":"r4","kind":"vault.fulfilled","payload":{"request_id":"vr1","name":"npm"}}
        {"seq":35,"run_id":"r4","kind":"agent.vault_reveal","payload":{"type":"vault_reveal","run_id":"r4","call_id":"vc1","refs":["npm"]}}
        {"seq":36,"run_id":"r4","kind":"vault.used","payload":{"names":["npm"]}}
        {"seq":37,"run_id":"r4","kind":"delegate.started","payload":{"child_run_id":"r5","instance_id":"inst-2","to":"写作助手","title":"写发布说明"}}
        {"seq":38,"run_id":"r4","kind":"plan.cancelled","payload":{"plan_id":"p0","title":"旧的发布提醒"}}
        {"seq":39,"run_id":"r4","kind":"run.log_truncated","payload":{"limit_bytes":4194304}}
        {"seq":40,"run_id":"r4","kind":"agent.update","payload":{"type":"agent_update","run_id":"r4","kind":"current_mode_update","raw":{}}}
        {"seq":41,"run_id":"r4","kind":"agent.future_thing","payload":{"whatever":1}}
        {"seq":42,"run_id":"r4","kind":"agent.message","payload":{"type":"message_chunk"}}
        {"seq":43,"run_id":"r4","kind":"run.state","payload":{"state":"cancelled","reason":"stopped by user","tree":true}}
        {"seq":44,"run_id":"r6","kind":"run.state","payload":{"state":"waiting_children","steps":2}}
        {"seq":45,"run_id":"r6","kind":"pipeline.step_started","payload":{"step":"draft","run_id":"r7","instance_id":"inst-2"}}
        {"seq":46,"run_id":"r6","kind":"pipeline.step_started","payload":{"step":"review","run_id":"r8","instance_id":"inst-3"}}
        {"seq":47,"run_id":null,"kind":"instance.state","payload":{"state":"running"}}
        """#

    /// 解析成 client-core 交给 App 的事件（`ai_generated` 按 kind，和服务端 `proto::labels` 一样）。
    static var events: [InstanceEvent] {
        lines.split(separator: "\n").compactMap { line -> InstanceEvent? in
            guard let value = JSONValue.parse(String(decoding: line.utf8, as: UTF8.self)),
                let seq = value["seq"]?.intValue,
                let kind = value["kind"]?.stringValue, let payload = value["payload"]
            else { return nil }
            return InstanceEvent(
                instanceID: instance, seq: UInt64(seq), runID: value["run_id"]?.stringValue.map { RunID($0) },
                kind: InstanceEventKind(rawValue: kind), payloadJSON: payload.compactString(),
                createdAt: base.addingTimeInterval(Double(seq)))
        }
    }

    /// 这些事件对应的运行记录（服务端 `runs()` 给的，用户消息取自 `prompt`）。
    static var runs: [Run] {
        func at(_ seq: Int) -> Date { base.addingTimeInterval(Double(seq) - 0.5) }
        return [
            Run(
                id: "r1", instanceID: instance, prompt: "整理这周的周报", state: .succeeded, tokensUsed: 1540,
                summary: "周报整理好了。", createdAt: at(2), startedAt: at(5), finishedAt: at(17)),
            Run(
                id: "r2", instanceID: instance, prompt: "把改动推上去", state: .waitingApproval,
                stateReason: "运行 git push", attempt: 2, createdAt: at(18), startedAt: at(18)),
            Run(
                id: "r3", instanceID: instance, prompt: "检查依赖", state: .waitingQuota,
                stateReason: "DeepSeek 的 key 无效，请换一把", createdAt: at(31), waitCode: .invalid),
            Run(
                id: "r4", instanceID: instance, prompt: "发布 0.4.0", state: .cancelled, createdAt: at(32),
                startedAt: at(32), finishedAt: at(43)),
            Run(
                id: "r6", kind: .pipeline, instanceID: instance, planID: "p2", source: .plan, prompt: "每周发版流水线",
                state: .waitingChildren, createdAt: at(44)),
        ]
    }

    /// 时间线里一项的简写（断言用）。
    static func tag(_ item: ConversationItem) -> String {
        switch item.content {
        case .userMessage(let m): "user:\(m.source.rawValue)"
        case .assistantText: "text"
        case .thought: "thought"
        case .toolCall(let card):
            card.platformCategory.map { "platform:\($0.rawValue)" } ?? "tool:\(card.kind ?? "")"
        case .agentPlan: "todo"
        case .approval(let card):
            "approval:\(card.attempt):" + (card.resolution.map { "\($0.outcome)" } ?? "pending")
        case .vaultRequest(let card): "vault:\(card.status.rawValue)"
        case .runStatus(let line): "status:\(line.state.rawValue)"
        case .artifact: "artifact"
        case .childRun(let card): "child:\(card.runID.rawValue)"
        case .planActivity(let card):
            switch card.activity {
            case .needsConfirmation(let change): "plan:\(change.rawValue)"
            case .cancelled: "plan:cancelled"
            }
        case .systemNotice(let notice): "notice:\(notice.kind)"
        }
    }
}

@Suite("服务端原样的事件（和安卓共用的夹具）")
struct ServerEventFixtureTests {
    func tags(_ turns: [ConversationTurn], _ runID: RunID) -> [String] {
        (turns.first { $0.runID == runID }?.items ?? []).map(ServerEventFixture.tag)
    }

    @Test("每一种 kind 都认得：归并成对应的界面项，不显示的、不认识的、载荷不全的安全忽略")
    func reduces() throws {
        let events = ServerEventFixture.events
        #expect(events.count == 47, "每一行都解析出来了")
        let turns = Conversation.turns(runs: ServerEventFixture.runs, events: events)
        #expect(turns.map(\.runID) == ["r1", "r2", "r3", "r4", "r6"], "instance.state 不进时间线")
        #expect(
            tags(turns, "r1") == [
                "user:user", "thought", "todo", "tool:read", "text", "platform:plan", "plan:created", "artifact",
                "text", "status:succeeded",
            ])
        #expect(
            tags(turns, "r2") == [
                "user:user", "approval:1:approvedByUser", "notice:agentError", "notice:agentExited(willRestart: true)",
                "notice:sessionLost", "approval:2:pending", "status:waiting_approval",
            ])
        #expect(tags(turns, "r3") == ["user:user", "status:waiting_quota"])
        #expect(
            tags(turns, "r4") == [
                "user:user", "vault:fulfilled", "notice:vaultUsed([\"npm\"])", "child:r5", "plan:cancelled",
                "notice:logTruncated", "status:cancelled",
            ])
        #expect(tags(turns, "r6") == ["user:plan", "child:r7", "child:r8", "status:waiting_children"])

        // 细节：工具调用合并了更新，审批卡片关联了审批记录，状态行带着尝试次数和等待原因码，用量记下了。
        let r1 = try #require(turns.first { $0.runID == "r1" })
        let tool = try #require(r1.items.compactMap(\.content.toolCall).first { !$0.isPlatformTool })
        #expect(tool.status == .completed && tool.title == "Read notes/weekly.md")
        let presentation = ToolCallPresentation(tool, language: .chinese)
        #expect(presentation.summary == "notes/weekly.md")
        #expect(presentation.output == "# 周报草稿")
        #expect(r1.lastUsage?["input_tokens"]?.intValue == 1200)
        let texts = r1.items.compactMap(\.content.assistantText)
        #expect(texts.count == 2 && texts.allSatisfy { $0.isAIGenerated })
        let r2 = try #require(turns.first { $0.runID == "r2" })
        let cards = r2.items.compactMap(\.content.approval)
        #expect(cards.map(\.approvalID) == ["ap1", "ap2"])
        #expect(cards.last?.options.map(\.kind) == [.allowOnce, .rejectOnce])
        let status = try #require(r2.items.last?.content.runStatus)
        #expect(status.attempt == 2 && status.nextStep == .approve)
        let r3 = try #require(turns.first { $0.runID == "r3" }?.items.last?.content.runStatus)
        #expect(r3.waitCode == .invalid && r3.nextStep == .configureKey)
        let presentationR3 = RunStatusPresentation(line: r3, language: .english)
        #expect(presentationR3.action == .openModelRoutes)
        #expect(presentationR3.detail == "DeepSeek 的 key 无效，请换一把", "服务端按用户语言写的说明当正文")
    }

    @MainActor
    @Test("对话页读到这些事件：实例状态取最新的一条，审批卡片能直接决定，等 key 的运行给“去处理”")
    func conversationModel() async throws {
        var state = DemoData.state()
        let base = ServerEventFixture.base
        state.instances.append(
            Instance(
                id: ServerEventFixture.instance, agentID: "claude", agentVersion: "1.0.0", harness: "claude-code",
                name: "夹具", state: .running, createdAt: base, lastActiveAt: base))
        state.runs += ServerEventFixture.runs
        state.events[ServerEventFixture.instance] = ServerEventFixture.events
        let mock = MockClient(state: state, stepDelay: 0, autoReply: false)
        let model = ConversationModel(client: mock, instanceID: ServerEventFixture.instance)
        await model.start()
        #expect(model.instanceState == .running)
        #expect(model.turns.map(\.runID) == ["r1", "r2", "r3", "r4", "r6"])
        #expect(model.activeRunID == "r2", "等审批的是最早开始的、没结束的")
        #expect(model.pendingApprovalItemID(in: "r2") != nil)
        #expect(model.canRetry(try #require(model.turn(for: "r1"))))
        #expect(!model.canRetry(try #require(model.turn(for: "r6"))), "计划的流水线不在对话里重发")
    }
}
