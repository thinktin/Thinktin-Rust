import Foundation
import Testing

@testable import ThinktinKit

// 对话归并（docs/ios.md 第 5 节的表）：每一种 kind 至少一个用例。

private let runA = Fixture.runA
private let runB = Fixture.runB

/// 只有一个运行（runA，运行中）的归并器。
private func reducer(runs: [Run] = [Fixture.run(runA)]) -> ConversationReducer {
    ConversationReducer(runs: runs)
}

/// runA 那一组里 agent 的输出（去掉用户消息和状态行）。
private func output(_ r: ConversationReducer, run: RunID = runA) -> [ConversationItem] {
    r.items.filter { $0.runID == run && $0.content.userMessage == nil && $0.content.runStatus == nil }
}

private func turn(_ r: ConversationReducer, _ run: RunID = runA) throws -> ConversationTurn {
    try #require(r.conversationTurns.first { $0.runID == run })
}

private func statusLine(_ r: ConversationReducer, _ run: RunID = runA) throws -> RunStatusLine {
    let t = try turn(r, run)
    let last = try #require(t.items.last)
    #expect(last.id == "run-\(run.rawValue)-status")
    return try #require(last.content.runStatus)
}

private let options: JSONValue = [
    ["option_id": "ok", "name": "允许一次", "kind": "allow_once"],
    ["option_id": "always", "name": "总是允许", "kind": "allow_always"],
    ["option_id": "no", "name": "拒绝", "kind": "reject_once"],
]

@Suite("对话归并：分组与用户消息")
struct ConversationGroupingTests {
    @Test("每个运行一组：先是用户消息（Run.prompt），组按运行的创建时间排序")
    func groupsByRun() throws {
        let runs = [
            Fixture.run(runB, prompt: "第二个任务", state: .succeeded, createdAt: Fixture.now.addingTimeInterval(600)),
            Fixture.run(runA, prompt: "第一个任务", state: .succeeded, createdAt: Fixture.now),
        ]
        var ev = Events()
        ev.add(.agentMessage, runA, ["text": "A 的回答"])
        ev.add(.agentMessage, runB, ["text": "B 的回答"])
        let turns = Conversation.turns(runs: runs, events: ev.list)
        #expect(turns.map(\.runID) == [runA, runB])
        #expect(turns[0].items.tags == ["user", "text", "status"])
        #expect(turns[0].items[0].content.userMessage?.text == "第一个任务")
        #expect(turns[0].items[0].id == "run-run-a-prompt")
        #expect(turns[1].items[0].content.userMessage?.text == "第二个任务")
        #expect(turns[0].state == .succeeded)
        #expect(turns[0].run?.id == runA)

        let items = Conversation.build(runs: runs, events: ev.list)
        #expect(items.count == 6)
        #expect(Set(items.map(\.id)).count == items.count, "id 要唯一")
    }

    @Test("计划、流水线发起的运行：用户消息带来源")
    func userMessageSource() throws {
        let run = Fixture.run(runA, prompt: "汇总通知", source: .pipeline, planID: "plan-1", stepKey: "digest")
        let r = reducer(runs: [run])
        let message = try #require(r.items.first?.content.userMessage)
        #expect(message.text == "汇总通知")
        #expect(message.source == .pipeline)
        #expect(message.planID == "plan-1")
        #expect(message.stepKey == "digest")
    }

    @Test("运行记录还没加载：先只显示输出，加载后补上用户消息，id 不变")
    func runLoadedLater() throws {
        var r = ConversationReducer()
        var ev = Events()
        r.apply(ev.add(.agentMessage, runA, ["text": "先到的输出"]))
        #expect(r.items.tags == ["text"])
        let textID = r.items[0].id
        r.upsert(run: Fixture.run(runA, prompt: "后到的任务", state: .running))
        #expect(r.items.tags == ["user", "text", "status"])
        #expect(r.items[1].id == textID)
        #expect(r.items[0].content.userMessage?.text == "后到的任务")
        // 运行记录更新（状态变了）原地替换。
        r.upsert(run: Fixture.run(runA, prompt: "后到的任务", state: .succeeded))
        #expect(try statusLine(r).state == .succeeded)
        #expect(r.conversationTurns.count == 1)
    }

    @Test("增量更新时已有项的 id 保持不变")
    func stableIDs() {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.agentMessage, runA, ["text": "一"]))
        r.apply(ev.add(.toolCall, runA, ["tool_call_id": "t1", "title": "读", "status": "pending"]))
        let before = r.items.map(\.id)
        r.apply(ev.add(.toolCallUpdate, runA, ["tool_call_id": "t1", "status": "completed"]))
        r.apply(ev.add(.agentMessage, runA, ["text": "二"]))
        let after = r.items.map(\.id)
        #expect(Array(after.prefix(before.count - 1)) == Array(before.dropLast()), "状态行之前的项 id 不变")
        #expect(after.last == before.last, "状态行的 id 不变")
    }

    @Test("没有运行 id 的系统提示：自成一组，紧挨着的合在一起")
    func eventsWithoutRun() throws {
        var r = reducer(runs: [Fixture.run(runA, state: .succeeded, createdAt: Fixture.now.addingTimeInterval(-60))])
        var ev = Events()
        r.apply(ev.add(.agentError, nil, ["message": "sandbox restarted"]))
        r.apply(ev.add(.agentExited, nil, ["code": 137, "will_restart": true, "restarts": 1]))
        let turns = r.conversationTurns
        #expect(turns.count == 2)
        let none = try #require(turns.last)
        #expect(none.runID == nil)
        #expect(none.id.hasPrefix("none-"))
        #expect(none.items.tags == ["notice", "notice"])
        #expect(none.items.allSatisfy { $0.runID == nil })
    }

    @Test("只有不显示的事件时不出现空的组")
    func noEmptyGroups() {
        var r = reducer(runs: [Fixture.run(runA, state: .succeeded)])
        var ev = Events()
        r.apply(ev.add(.agentReady, nil, ["agent": "claude"]))
        r.apply(ev.add(raw: "agent.hologram", runB, ["x": 1]))
        r.apply(ev.add(.agentUpdate, nil, ["kind": "mode", "raw": [:]]))
        #expect(r.conversationTurns.map(\.runID) == [runA])
        #expect(r.items.tags == ["user", "status"])
    }

    @Test("一次性归并：演示数据")
    func demoData() throws {
        let demo = DemoData.state(now: Fixture.now)
        let runs = demo.runs.filter { $0.instanceID == DemoData.writerID }
        let events = demo.events[DemoData.writerID] ?? []
        let turns = Conversation.turns(runs: runs, events: events, approvals: demo.approvals)
        #expect(turns.map(\.runID) == [DemoData.weeklyRunID, DemoData.digestRunID, DemoData.postRunID])
        #expect(turns[0].items.tags == ["user", "thought", "tool", "text", "artifact", "status"])
        #expect(turns[0].lastUsage?["input_tokens"] == 15_200)
        #expect(turns[1].items.tags == ["user", "tool", "text", "status"])
        #expect(turns[2].items.tags == ["user", "text", "tool", "approval", "status"])
        let card = try #require(turns[2].items[3].content.approval)
        #expect(card.approvalID == DemoData.pendingApprovalID)
        #expect(card.isPending)
        #expect(turns[2].state == .waitingApproval)
        let text = try #require(turns[0].items[3].content.assistantText)
        #expect(text.text.hasPrefix("这周的周报要点整理好了，按项目分了三组：\n\n**Thinktin 后端**"))
        #expect(!text.isStreaming)
    }
}

@Suite("对话归并：agent 输出")
struct ConversationOutputTests {
    @Test("agent.message：连续的拼成一段（中间不显示的事件不打断）")
    func messageConcatenation() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.turnStarted, runA, ["run_id": "run-a"]))
        r.apply(ev.add(.agentMessage, runA, ["text": "你好，"]))
        r.apply(ev.add(.agentUsage, runA, ["raw": ["input_tokens": 10]]))
        r.apply(ev.add(.agentMessage, runA, ["text": "世界"]))
        let out = output(r)
        #expect(out.tags == ["text"])
        let text = try #require(out[0].content.assistantText)
        #expect(text.text == "你好，世界")
        #expect(out[0].id == "seq-2")
        #expect(text.isAIGenerated)
        #expect(text.isStreaming)
        #expect(r.isStreaming)
    }

    @Test("agent.message：中间有别的显示项就分成两段")
    func messageSplitByCard() {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.agentMessage, runA, ["text": "先看看文件。"]))
        r.apply(
            ev.add(.toolCall, runA, ["tool_call_id": "t1", "title": "读取 a.md", "kind": "read", "status": "pending"]))
        r.apply(ev.add(.agentMessage, runA, ["text": "看完了。"]))
        let out = output(r)
        #expect(out.tags == ["text", "tool", "text"])
        #expect(out[0].content.assistantText?.text == "先看看文件。")
        #expect(out[2].content.assistantText?.text == "看完了。")
        // 只有最后一段在“输出中”。
        #expect(out[0].content.assistantText?.isStreaming == false)
        #expect(out[2].content.assistantText?.isStreaming == true)
    }

    @Test("agent.message：不同运行的不拼在一起")
    func messageAcrossRuns() throws {
        let runs = [Fixture.run(runA), Fixture.run(runB, createdAt: Fixture.now.addingTimeInterval(1))]
        var r = ConversationReducer(runs: runs)
        var ev = Events()
        r.apply(ev.add(.agentMessage, runA, ["text": "A"]))
        r.apply(ev.add(.agentMessage, runB, ["text": "B"]))
        #expect(output(r, run: runA).compactMap(\.content.assistantText?.text) == ["A"])
        #expect(output(r, run: runB).compactMap(\.content.assistantText?.text) == ["B"])
    }

    @Test("agent.thought：可折叠的思考块，连续的拼成一段，和回答分开")
    func thought() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.agentThought, runA, ["text": "先想想，"]))
        r.apply(ev.add(.agentThought, runA, ["text": "再动手。"]))
        r.apply(ev.add(.agentMessage, runA, ["text": "好的。"]))
        r.apply(ev.add(.agentThought, runA, ["text": "还有一步。"]))
        let out = output(r)
        #expect(out.tags == ["thought", "text", "thought"])
        let first = try #require(out[0].content.thought)
        #expect(first.text == "先想想，再动手。")
        #expect(first.isAIGenerated)
        #expect(out[2].content.thought?.text == "还有一步。")
    }

    @Test("agent.turn_ended：结束“输出中”")
    func turnEnded() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.turnStarted, runA))
        r.apply(ev.add(.agentMessage, runA, ["text": "完成"]))
        #expect(r.isStreaming)
        r.apply(ev.add(.turnEnded, runA, ["stop_reason": "end_turn"]))
        #expect(!r.isStreaming)
        #expect(output(r)[0].content.assistantText?.isStreaming == false)
        #expect(try turn(r).isStreaming == false)
        // 下一轮开始又是输出中。
        r.apply(ev.add(.turnStarted, runA))
        #expect(r.isStreaming)
    }

    @Test("ai_generated 标识按事件透传")
    func aiGeneratedPassThrough() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.agentMessage, runA, ["text": "服务端说这条不是 AI 生成的"], aiGenerated: false))
        r.apply(ev.add(.agentThought, runA, ["text": "思考"]))
        r.apply(ev.add(.agentPlan, runA, ["entries": [["content": "一", "status": "pending"]]], aiGenerated: false))
        let out = output(r)
        #expect(out[0].content.assistantText?.isAIGenerated == false)
        #expect(out[1].content.thought?.isAIGenerated == true)
        #expect(out[2].content.agentPlan?.isAIGenerated == false)
    }

    @Test("agent.tool_call 与 agent.tool_call_update 按 tool_call_id 合并")
    func toolCallMerge() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(
                .toolCall, runA,
                [
                    "tool_call_id": "t1", "title": "读取 notes.md", "kind": "read", "status": "pending",
                    "raw": ["toolCallId": "t1", "rawInput": ["path": "notes.md"]],
                ]))
        r.apply(ev.add(.toolCall, runA, ["tool_call_id": "t2", "title": "搜索", "kind": "search", "status": "pending"]))
        r.apply(
            ev.add(
                .toolCallUpdate, runA,
                ["tool_call_id": "t1", "status": "in_progress", "raw": ["status": "in_progress"]]))
        r.apply(
            ev.add(
                .toolCallUpdate, runA,
                ["tool_call_id": "t1", "status": "completed", "raw": ["content": [["type": "text", "text": "412 行"]]]]))
        // raw 为 null 的更新不会冲掉合并好的内容。
        r.apply(ev.add(.toolCallUpdate, runA, ["tool_call_id": "t1", "raw": nil]))
        r.apply(ev.add(.toolCallUpdate, runA, ["tool_call_id": "t2", "status": "failed", "raw": ["title": "搜索（超时）"]]))
        let out = output(r)
        #expect(out.tags == ["tool", "tool"])
        let t1 = try #require(out[0].content.toolCall)
        #expect(out[0].id == "tool-run-a-t1")
        #expect(t1.toolCallID == "t1")
        #expect(t1.title == "读取 notes.md")
        #expect(t1.kind == "read")
        #expect(t1.status == .completed)
        #expect(t1.raw?["rawInput"]?["path"] == "notes.md")
        #expect(t1.raw?["content"]?[0]?["text"] == "412 行")
        #expect(t1.raw?["status"] == "in_progress")
        #expect(!t1.isPlatformTool)
        let t2 = try #require(out[1].content.toolCall)
        #expect(t2.status == .failed)
        #expect(t2.title == "搜索（超时）")
    }

    @Test("只收到更新（调用本身过了保留期）：也建卡片")
    func toolCallUpdateWithoutCall() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.toolCallUpdate, runA, ["tool_call_id": "t9", "status": "completed", "raw": ["title": "写入"]]))
        let card = try #require(output(r).first?.content.toolCall)
        #expect(card.title == "写入")
        #expect(card.status == .completed)
        // 新的调用没有状态时按 pending。
        r.apply(ev.add(.toolCall, runA, ["tool_call_id": "t10", "title": "x"]))
        #expect(output(r).last?.content.toolCall?.status == .pending)
    }

    @Test("agent.platform_tool_call：平台工具卡片，同一个 call_id 原地更新")
    func platformToolCall() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(
                .platformToolCall, runA,
                ["call_id": "pc1", "name": "schedule_create", "arguments": ["title": "晨报", "cron": "0 8 * * *"]]))
        r.apply(ev.add(.platformToolCall, runA, ["call_id": "pc2", "name": "delegate", "arguments": ["to": "审查"]]))
        r.apply(
            ev.add(
                .platformToolCall, runA, ["call_id": "pc1", "name": "schedule_create", "arguments": ["title": "晨报 v2"]])
        )
        let out = output(r)
        #expect(out.tags == ["tool", "tool"])
        let card = try #require(out[0].content.toolCall)
        #expect(card.isPlatformTool)
        #expect(card.platformCategory == .plan)
        #expect(card.title == "schedule_create")
        #expect(card.status == nil)
        #expect(card.raw?["title"] == "晨报 v2")
        #expect(out[1].content.toolCall?.platformCategory == .delegate)
        // 和 agent 自己的同名工具调用不冲突。
        r.apply(ev.add(.toolCall, runA, ["tool_call_id": "pc1", "title": "agent 自己的", "status": "pending"]))
        #expect(output(r).count == 3)
    }

    @Test("agent.plan：待办清单卡片，每次是完整清单，原地替换")
    func agentPlan() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(
                .agentPlan, runA,
                [
                    "entries": [
                        ["content": "读代码", "priority": "high", "status": "in_progress"],
                        ["content": "写测试", "status": "pending"],
                    ]
                ]))
        r.apply(ev.add(.agentMessage, runA, ["text": "开始。"]))
        r.apply(
            ev.add(
                .agentPlan, runA,
                ["entries": [["content": "读代码", "status": "completed"], ["content": "写测试", "status": "in_progress"]]]))
        let out = output(r)
        #expect(out.tags == ["plan", "text"])
        let card = try #require(out[0].content.agentPlan)
        #expect(card.entries.map(\.content) == ["读代码", "写测试"])
        #expect(card.entries[0].status == .completed)
        #expect(card.completedCount == 1)
        #expect(card.isAIGenerated)
        #expect(out[0].id == "plan-run-a")
    }

    @Test("artifact.published：产出物卡片")
    func artifactPublished() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(.artifactPublished, runA, ["artifact_id": "art-1", "name": "报告.md", "version": 2, "size": 2048]))
        let card = try #require(output(r).first?.content.artifact)
        #expect(card.artifactID == "art-1")
        #expect(card.name == "报告.md")
        #expect(card.version == 2)
        #expect(card.size == 2048)
    }

    @Test("pipeline.step_started：子运行卡片（流水线的一步）")
    func pipelineStepStarted() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.pipelineStepStarted, runA, ["step": "build", "run_id": "child-1", "instance_id": "inst-2"]))
        let card = try #require(output(r).first?.content.childRun)
        #expect(card.runID == "child-1")
        #expect(card.instanceID == "inst-2")
        #expect(card.title == "build")
        #expect(card.origin == .pipelineStep("build"))
    }

    @Test("delegate.started：子运行卡片（委派），没有标题时用对方的名字")
    func delegateStarted() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(
                .delegateStarted, runA,
                ["child_run_id": "child-2", "instance_id": "inst-3", "to": "代码审查", "title": "看看 PR"]))
        r.apply(
            ev.add(
                .delegateStarted, runA,
                ["child_run_id": "child-3", "instance_id": "inst-3", "to": "代码审查", "title": nil]))
        let out = output(r)
        let first = try #require(out[0].content.childRun)
        #expect(first.runID == "child-2")
        #expect(first.title == "看看 PR")
        #expect(first.origin == .delegate(to: "代码审查"))
        #expect(out[1].content.childRun?.title == "代码审查")
    }

    @Test("plan.needs_confirmation / plan.cancelled：计划卡片")
    func planActivity() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.planNeedsConfirmation, runA, ["plan_id": "plan-9", "title": "每周依赖检查", "change": "created"]))
        r.apply(ev.add(.planNeedsConfirmation, runA, ["plan_id": "plan-9", "title": "每周依赖检查", "change": "updated"]))
        r.apply(ev.add(.planCancelled, runA, ["plan_id": "plan-8", "title": "旧计划"]))
        let out = output(r)
        #expect(out.tags == ["planActivity", "planActivity", "planActivity"])
        let card = try #require(out[0].content.planActivity)
        #expect(card.planID == "plan-9")
        #expect(card.title == "每周依赖检查")
        #expect(card.activity == .needsConfirmation(.created))
        #expect(out[1].content.planActivity?.activity == .needsConfirmation(.updated))
        #expect(out[2].content.planActivity?.activity == .cancelled)
    }

    @Test("系统提示行：agent.error、session_lost、exited、run.log_truncated、vault.used")
    func systemNotices() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.agentError, runA, ["message": "model gateway: rate limited"]))
        r.apply(ev.add(.agentSessionLost, runA, ["previous_session_id": "s1", "reason": "session expired"]))
        r.apply(ev.add(.agentExited, runA, ["code": 1, "will_restart": true, "restarts": 1]))
        r.apply(ev.add(.agentExited, runA, ["code": nil, "will_restart": false, "restarts": 3]))
        r.apply(ev.add(.runLogTruncated, runA, ["limit_bytes": 1_048_576]))
        r.apply(ev.add(.vaultUsed, runA, ["names": ["github", "npm"]]))
        let notices = output(r).compactMap(\.content.systemNotice)
        #expect(notices.count == 6)
        #expect(notices[0] == SystemNotice(kind: .agentError, message: "model gateway: rate limited"))
        #expect(notices[1] == SystemNotice(kind: .sessionLost, message: "session expired"))
        #expect(notices[2] == SystemNotice(kind: .agentExited(willRestart: true), message: "exit code 1"))
        #expect(notices[3] == SystemNotice(kind: .agentExited(willRestart: false), message: nil))
        #expect(notices[4] == SystemNotice(kind: .logTruncated, message: "limit 1048576 bytes"))
        #expect(notices[5].kind == .vaultUsed(["github", "npm"]))
    }

    @Test("不显示的 kind 被忽略：usage、turn_started、turn_ended、ready、update、vault_reveal")
    func hiddenKinds() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.agentReady, runA, ["agent": "claude"]))
        r.apply(ev.add(.turnStarted, runA, ["run_id": "run-a"]))
        r.apply(ev.add(.agentUpdate, runA, ["kind": "current_mode_update", "raw": ["mode": "plan"]]))
        r.apply(ev.add(.vaultReveal, runA, ["call_id": "c", "refs": ["github"]]))
        r.apply(ev.add(.agentUsage, runA, ["raw": ["input_tokens": 120, "output_tokens": 30]]))
        r.apply(ev.add(.turnEnded, runA, ["stop_reason": "end_turn"]))
        #expect(output(r).isEmpty)
        // usage 进运行详情。
        #expect(try turn(r).lastUsage == ["input_tokens": 120, "output_tokens": 30])
    }

    @Test("不认识的 kind、载荷不对的事件：安全忽略")
    func unknownKinds() {
        var r = reducer()
        var ev = Events()
        let usedUnknown = r.apply(ev.add(raw: "agent.hologram", runA, ["anything": [1, 2, 3]]))
        let usedEmpty = r.apply(ev.add(raw: "", runA))
        #expect(usedUnknown && usedEmpty, "不认识的事件也算处理过（推进 seq）")
        r.apply(
            InstanceEvent(
                instanceID: Fixture.instanceID, seq: 99, runID: runA, kind: .agentMessage, payloadJSON: "not json",
                createdAt: Fixture.now))
        r.apply(
            InstanceEvent(
                instanceID: Fixture.instanceID, seq: 100, runID: runA, kind: .permissionRequested,
                payloadJSON: #"{"title":"没有 request_id"}"#, createdAt: Fixture.now))
        #expect(output(r).isEmpty)
        #expect(r.lastSeq == 100)
    }
}

@Suite("对话归并：审批")
struct ConversationApprovalTests {
    @Test("agent.permission_requested → agent.permission_resolved")
    func requestedThenResolved() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(
                .permissionRequested, runA,
                [
                    "request_id": "r1", "title": "删除 build/", "options": options,
                    "tool_call": ["toolCallId": "t1", "kind": "delete"],
                ]))
        var card = try #require(output(r).first?.content.approval)
        // 没有 attempt（老的服务端）也没有 run.state 时尝试不知道（0）；id 带上尝试，不同尝试的 perm-1 不会撞。
        #expect(output(r).first?.id == "approval-run-a-0-r1")
        #expect(card.attempt == 0)
        #expect(card.isPending)
        #expect(card.title == "删除 build/")
        #expect(card.options.map(\.id) == ["ok", "always", "no"])
        #expect(card.toolCall?["kind"] == "delete")
        #expect(r.pendingApprovals.map(\.requestID) == ["r1"])

        r.apply(ev.add(.permissionResolved, runA, ["request_id": "r1", "option_id": "always", "by": "user"]))
        card = try #require(output(r).first?.content.approval)
        let resolution = try #require(card.resolution)
        #expect(resolution.optionID == "always")
        #expect(resolution.optionName == "总是允许")
        #expect(resolution.by == .user)
        #expect(resolution.isApproved)
        #expect(r.pendingApprovals.isEmpty)
        #expect(output(r).count == 1, "结果更新原来的卡片，不新加")
    }

    @Test("拒绝、超时放弃作答")
    func rejectedAndTimedOut() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r1", "title": "a", "options": options]))
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r2", "title": "b", "options": options]))
        r.apply(ev.add(.permissionResolved, runA, ["request_id": "r1", "option_id": "no", "by": "user"]))
        r.apply(ev.add(.permissionResolved, runA, ["request_id": "r2", "option_id": nil, "by": "timeout"]))
        let cards = output(r).compactMap(\.content.approval)
        #expect(cards[0].resolution?.isApproved == false)
        #expect(cards[0].resolution?.optionName == "拒绝")
        #expect(cards[1].resolution?.by == .timeout)
        #expect(cards[1].resolution?.optionID == nil)
        #expect(cards[1].resolution?.isApproved == false)
    }

    @Test("按预授权策略直接决定的：只有 resolved，也显示一张已决的卡片")
    func resolvedByPolicy() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.permissionResolved, runA, ["request_id": "r0", "option_id": "ok", "by": "policy"]))
        let card = try #require(output(r).first?.content.approval)
        #expect(card.resolution?.by == .policy)
        #expect(card.options.isEmpty)
        #expect(!card.isPending)
    }

    @Test("关联审批记录后，approval.decided 更新卡片")
    func linkThenDecided() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r1", "title": "发布", "options": options]))
        r.link(approvals: [approval("ap-1", title: "发布")])
        var card = try #require(output(r).first?.content.approval)
        #expect(card.approvalID == "ap-1")
        #expect(card.isPending)
        #expect(r.pendingApprovals.first?.approvalID == "ap-1")

        r.apply(ev.add(.approvalDecided, runA, ["approval_id": "ap-1", "state": "approved", "option_id": "ok"]))
        card = try #require(output(r).first?.content.approval)
        #expect(card.resolution?.by == .user)
        #expect(card.resolution?.optionName == "允许一次")
        #expect(card.resolution?.isApproved == true)
        // 之后 agent 那边的 resolved 再来，以先到的为准。
        r.apply(ev.add(.permissionResolved, runA, ["request_id": "r1", "option_id": "ok", "by": "user"]))
        #expect(output(r).first?.content.approval?.resolution?.optionID == "ok")
        #expect(output(r).count == 1)
    }

    @Test("approval.decided：没关联过、这一组只有一张未决卡片时也能对上")
    func decidedWithoutLink() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r1", "title": "发布", "options": options]))
        r.apply(ev.add(.approvalDecided, runA, ["approval_id": "ap-1", "state": "rejected", "option_id": "no"]))
        let card = try #require(output(r).first?.content.approval)
        #expect(card.approvalID == "ap-1")
        #expect(card.resolution?.isApproved == false)
        #expect(card.resolution?.optionName == "拒绝")
    }

    @Test("approval.decided：对不上（多张未决、或者不认识的审批）时不乱改")
    func decidedAmbiguous() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r1", "title": "a", "options": options]))
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r2", "title": "b", "options": options]))
        r.apply(ev.add(.approvalDecided, runA, ["approval_id": "ap-x", "state": "approved", "option_id": "ok"]))
        #expect(r.pendingApprovals.count == 2)
        // 别的运行的决定不影响这一组。
        r.apply(ev.add(.approvalDecided, runB, ["approval_id": "ap-y", "state": "approved", "option_id": "ok"]))
        #expect(r.pendingApprovals.count == 2)
    }

    @Test("关联：未决的审批只配未决的卡片，标题相同的优先，按创建顺序")
    func linkMatching() throws {
        var r = reducer()
        var ev = Events()
        // 先有一张按策略决定的卡片（没有审批记录），再有两张未决的。
        r.apply(ev.add(.permissionResolved, runA, ["request_id": "r0", "option_id": "ok", "by": "policy"]))
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r1", "title": "甲", "options": options]))
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r2", "title": "乙", "options": options]))
        r.link(approvals: [
            approval("ap-yi", title: "乙", createdAt: Fixture.now.addingTimeInterval(1)),
            approval("ap-jia", title: "甲", createdAt: Fixture.now.addingTimeInterval(2)),
        ])
        let cards = output(r).compactMap(\.content.approval)
        #expect(cards.map(\.requestID) == ["r0", "r1", "r2"])
        #expect(cards[0].approvalID == nil, "按策略决定的卡片没有审批记录")
        #expect(cards[1].approvalID == "ap-jia")
        #expect(cards[2].approvalID == "ap-yi")
        // 再关联一次不变。
        r.link(approvals: [approval("ap-yi", title: "乙"), approval("ap-jia", title: "甲")])
        #expect(output(r).compactMap(\.content.approval).map(\.approvalID) == [nil, "ap-jia", "ap-yi"])
    }

    @Test("关联：审批记录已经有结果、卡片还没有时补上；没有选项时用记录里的")
    func linkFillsResolution() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.permissionRequested, runA, ["request_id": "r1", "title": "甲", "options": []]))
        r.link(approvals: [approval("ap-1", title: "甲", state: .expired)])
        let card = try #require(output(r).first?.content.approval)
        #expect(card.approvalID == "ap-1")
        #expect(card.resolution?.by == .timeout)
        #expect(card.resolution?.isApproved == false)
        #expect(card.options.map(\.id) == ["allow", "allow_always", "reject"])
        // 不同运行的审批不会配到这一组。
        var other = reducer()
        other.apply(ev.add(.permissionRequested, runA, ["request_id": "r9", "title": "甲", "options": options]))
        other.link(approvals: [approval("ap-2", run: runB, title: "甲")])
        #expect(output(other).first?.content.approval?.approvalID == nil)
    }

    private func approval(
        _ id: ApprovalID, run: RunID = runA, title: String, state: ApprovalState = .pending,
        createdAt: Date = Fixture.now
    ) -> Approval {
        Approval(
            id: id, runID: run, instanceID: Fixture.instanceID, title: title, options: DemoData.approvalOptions,
            state: state, expiresAt: createdAt.addingTimeInterval(3600), createdAt: createdAt)
    }
}

@Suite("对话归并：审批按尝试认（11.8，docs/agent-integration.md 第 6 节）")
struct ConversationApprovalAttemptTests {
    /// 一次尝试的开始（`run.state` 带 attempt）。
    private func start(_ ev: inout Events, attempt: Int, _ run: RunID = runA) -> InstanceEvent {
        ev.add(.runState, run, ["state": "running", "attempt": .number(Double(attempt))])
    }

    private func requested(
        _ ev: inout Events, _ requestID: String, attempt: Int?, approvalID: String?, title: String = "删除 build/"
    ) -> InstanceEvent {
        var payload: [String: JSONValue] = [
            "request_id": .string(requestID), "title": .string(title), "options": options,
        ]
        if let attempt { payload["attempt"] = .number(Double(attempt)) }
        if let approvalID { payload["approval_id"] = .string(approvalID) }
        return ev.add(.permissionRequested, runA, .object(payload))
    }

    private func cards(_ r: ConversationReducer) -> [ApprovalCard] {
        output(r).compactMap(\.content.approval)
    }

    @Test("两次尝试各一个 perm-1：两张卡片，不并到一起；第 1 次的作废，决定只落在第 2 次的卡片上")
    func samePermIDInTwoAttempts() throws {
        var r = reducer()
        var ev = Events()
        r.apply(start(&ev, attempt: 1))
        r.apply(requested(&ev, "perm-1", attempt: 1, approvalID: "ap-1"))
        // 第 1 次尝试崩了，退避后第 2 次尝试；shim 重新从 perm-1 编号。
        r.apply(ev.add(.runState, runA, ["state": "backoff", "attempt": 1]))
        r.apply(start(&ev, attempt: 2))
        r.apply(requested(&ev, "perm-1", attempt: 2, approvalID: "ap-2", title: "再删一次"))

        var list = cards(r)
        try #require(list.count == 2)
        #expect(list.map(\.attempt) == [1, 2])
        #expect(list.map(\.approvalID) == ["ap-1", "ap-2"])
        #expect(list[0].resolution?.outcome == .cancelled, "旧尝试没处理的审批被平台取消了")
        #expect(list[1].isPending)
        #expect(list[1].title == "再删一次")
        #expect(r.pendingApprovals.map(\.approvalID) == ["ap-2"])
        let ids = output(r).filter { $0.content.approval != nil }.map(\.id)
        #expect(ids == ["approval-run-a-1-perm-1", "approval-run-a-2-perm-1"])

        r.apply(
            ev.add(
                .approvalDecided, runA,
                ["approval_id": "ap-2", "state": "approved", "option_id": "ok", "request_id": "perm-1", "attempt": 2]))
        r.apply(
            ev.add(
                .permissionResolved, runA,
                [
                    "request_id": "perm-1", "option_id": "ok", "by": "user", "attempt": 2, "approval_id": "ap-2",
                    "approval_state": "approved",
                ]))
        list = cards(r)
        #expect(list.count == 2)
        #expect(list[0].resolution?.outcome == .cancelled, "第 1 次的卡片不受影响")
        #expect(list[1].resolution?.outcome == .approvedByUser)
        #expect(list[1].resolution?.optionName == "允许一次")
        #expect(r.pendingApprovals.isEmpty)
    }

    @Test("事件没带 approval_id（建审批失败、老的服务端）：按审批记录的 (attempt, request_id) 关联")
    func linkByAttemptAndRequestID() throws {
        var r = reducer()
        var ev = Events()
        r.apply(start(&ev, attempt: 1))
        r.apply(requested(&ev, "perm-1", attempt: 1, approvalID: nil))
        r.apply(start(&ev, attempt: 2))
        r.apply(requested(&ev, "perm-1", attempt: 2, approvalID: nil))
        r.link(approvals: [
            approval("ap-2", requestID: "perm-1", attempt: 2),
            approval("ap-1", requestID: "perm-1", attempt: 1, state: .cancelled),
        ])
        let list = cards(r)
        #expect(list.map(\.approvalID) == ["ap-1", "ap-2"])
        #expect(list[0].resolution?.outcome == .cancelled)
        #expect(list[1].isPending)
        // approval.decided 带了请求 id 和尝试：没关联过也对得上第 2 次的卡片（不会因为“只有一张未决”的猜测弄错）。
        var other = reducer()
        var ev2 = Events()
        other.apply(start(&ev2, attempt: 1))
        other.apply(requested(&ev2, "perm-1", attempt: 1, approvalID: nil))
        other.apply(start(&ev2, attempt: 2))
        other.apply(requested(&ev2, "perm-1", attempt: 2, approvalID: nil))
        other.apply(
            ev2.add(
                .approvalDecided, runA,
                ["approval_id": "ap-9", "state": "rejected", "option_id": "no", "request_id": "perm-1", "attempt": 2]))
        let decided = cards(other)
        #expect(decided[1].approvalID == "ap-9")
        #expect(decided[1].resolution?.outcome == .rejectedByUser)
        #expect(decided[0].approvalID == nil)
    }

    @Test("平台判的超时：shim 回 by: user，approval_state 是 expired，显示已过期而不是“你拒绝了”")
    func expiredByPlatform() throws {
        var r = reducer()
        var ev = Events()
        r.apply(start(&ev, attempt: 1))
        r.apply(requested(&ev, "perm-1", attempt: 1, approvalID: "ap-1"))
        r.apply(requested(&ev, "perm-2", attempt: 1, approvalID: "ap-2"))
        r.apply(
            ev.add(
                .permissionResolved, runA,
                [
                    "request_id": "perm-1", "by": "user", "attempt": 1, "approval_id": "ap-1",
                    "approval_state": "expired",
                ]
            ))
        r.apply(
            ev.add(
                .permissionResolved, runA,
                [
                    "request_id": "perm-2", "option_id": "no", "by": "user", "attempt": 1, "approval_id": "ap-2",
                    "approval_state": "rejected",
                ]))
        let list = cards(r)
        let expired = try #require(list[0].resolution)
        #expect(expired.outcome == .expired)
        #expect(expired.by == .timeout)
        #expect(expired.state == .expired)
        #expect(!expired.isApproved)
        #expect(list[1].resolution?.outcome == .rejectedByUser)
        #expect(list[1].resolution?.state == .rejected)
        // 没有 approval_state 的老事件：照 shim 说的（这里是用户拒绝）；之后审批记录说过期了，补成已过期。
        var old = reducer()
        var ev2 = Events()
        old.apply(requested(&ev2, "perm-1", attempt: nil, approvalID: nil))
        old.apply(ev2.add(.permissionResolved, runA, ["request_id": "perm-1", "by": "user"]))
        #expect(cards(old)[0].resolution?.outcome == .rejectedByUser)
        old.link(approvals: [approval("ap-1", requestID: "perm-1", attempt: 0, state: .expired)])
        #expect(cards(old)[0].resolution?.outcome == .expired)
    }

    @Test("旧尝试的待处理卡片作废：运行记录已经是第 2 次（先显示缓存）、run.state 进到第 2 次；运行结束时也作废")
    func staleAttemptsSuperseded() throws {
        // 运行记录说已经是第 2 次尝试，缓存里第 1 次的请求一出现就作废；第 2 次的照常待处理。
        var run = Fixture.run(runA)
        run.attempt = 2
        var r = reducer(runs: [run])
        var ev = Events()
        r.apply(start(&ev, attempt: 1))
        r.apply(requested(&ev, "perm-1", attempt: 1, approvalID: "ap-1"))
        #expect(cards(r)[0].resolution?.outcome == .cancelled)
        #expect(r.pendingApprovals.isEmpty)
        r.apply(start(&ev, attempt: 2))
        r.apply(requested(&ev, "perm-1", attempt: 2, approvalID: "ap-2"))
        #expect(r.pendingApprovals.map(\.approvalID) == ["ap-2"])
        // 推断出的“作废”会被真正的结果换掉（比如缓存里稍后就有 shim 的结果）。
        r.apply(
            ev.add(
                .permissionResolved, runA,
                [
                    "request_id": "perm-1", "by": "user", "attempt": 1, "approval_id": "ap-1",
                    "approval_state": "expired",
                ]
            ))
        #expect(cards(r)[0].resolution?.outcome == .expired)

        // 尝试不知道（0）的卡片不按尝试作废；运行结束了，所有待处理的都作废。
        var legacy = reducer()
        var ev2 = Events()
        legacy.apply(requested(&ev2, "r1", attempt: nil, approvalID: nil))
        legacy.apply(start(&ev2, attempt: 3))
        #expect(legacy.pendingApprovals.map(\.requestID) == ["r1"])
        legacy.apply(ev2.add(.runState, runA, ["state": "failed", "attempt": 3]))
        #expect(legacy.pendingApprovals.isEmpty)
        #expect(cards(legacy)[0].resolution?.outcome == .cancelled)
        // 运行记录先到、事件后到也一样：upsert 之后作废。
        var late = reducer()
        var ev3 = Events()
        late.apply(start(&ev3, attempt: 1))
        late.apply(requested(&ev3, "perm-1", attempt: 1, approvalID: "ap-1"))
        #expect(late.pendingApprovals.count == 1)
        var retried = Fixture.run(runA)
        retried.attempt = 2
        late.upsert(run: retried)
        #expect(late.pendingApprovals.isEmpty)
    }

    @Test("没带 attempt 的事件取这之前最近一条 run.state 的；带了 attempt 的 resolved 也对得上")
    func attemptFromRunState() throws {
        var r = reducer()
        var ev = Events()
        r.apply(start(&ev, attempt: 2))
        r.apply(requested(&ev, "perm-1", attempt: nil, approvalID: nil))
        #expect(cards(r)[0].attempt == 2)
        r.apply(
            ev.add(.permissionResolved, runA, ["request_id": "perm-1", "option_id": "ok", "by": "user", "attempt": 2]))
        #expect(cards(r).count == 1)
        #expect(cards(r)[0].resolution?.outcome == .approvedByUser)
        // 尝试不知道的卡片，带了 attempt 的结果也认（老数据和新数据混着）。
        var mixed = reducer()
        var ev2 = Events()
        mixed.apply(requested(&ev2, "perm-1", attempt: nil, approvalID: nil))
        mixed.apply(
            ev2.add(.permissionResolved, runA, ["request_id": "perm-1", "option_id": "ok", "by": "user", "attempt": 1]))
        #expect(cards(mixed).count == 1)
        #expect(cards(mixed)[0].resolution?.outcome == .approvedByUser)
    }

    @Test("事件带 approval_id：多张未决卡片时 approval.decided 也落在对的卡片上；之前猜错的关联让位")
    func approvalIDFromEvents() throws {
        var r = reducer()
        var ev = Events()
        r.apply(start(&ev, attempt: 1))
        r.apply(requested(&ev, "perm-1", attempt: 1, approvalID: "ap-1", title: "甲"))
        r.apply(requested(&ev, "perm-2", attempt: 1, approvalID: "ap-2", title: "乙"))
        r.apply(ev.add(.approvalDecided, runA, ["approval_id": "ap-2", "state": "approved", "option_id": "ok"]))
        let list = cards(r)
        #expect(list[0].isPending)
        #expect(list[1].resolution?.outcome == .approvedByUser)
        // 已经按事件关联的不被审批记录改掉。
        r.link(approvals: [approval("ap-1", requestID: "perm-1", attempt: 1)])
        #expect(cards(r).map(\.approvalID) == ["ap-1", "ap-2"])

        // 老数据先按标题猜着关联，事件里的 approval_id 说的为准。
        var guessed = reducer()
        var ev2 = Events()
        guessed.apply(requested(&ev2, "r1", attempt: nil, approvalID: nil, title: "同名"))
        guessed.apply(requested(&ev2, "r2", attempt: nil, approvalID: nil, title: "同名"))
        guessed.link(approvals: [approval("ap-x", requestID: "", attempt: 0, title: "同名")])
        #expect(cards(guessed).map(\.approvalID) == ["ap-x", nil])
        guessed.apply(
            ev2.add(
                .permissionResolved, runA, ["request_id": "r2", "option_id": "ok", "by": "user", "approval_id": "ap-x"])
        )
        #expect(cards(guessed).map(\.approvalID) == [nil, "ap-x"])
    }

    @Test("结论：用户 / 策略 / 超时 / 取消")
    func outcomes() {
        typealias Res = ApprovalCard.Resolution
        #expect(Res(optionID: "ok", optionName: nil, by: .user, isApproved: true).outcome == .approvedByUser)
        #expect(Res(optionID: "no", optionName: nil, by: .user, isApproved: false).outcome == .rejectedByUser)
        #expect(Res(optionID: "ok", optionName: nil, by: .policy, isApproved: true).outcome == .approvedByPolicy)
        #expect(Res(optionID: nil, optionName: nil, by: .policy, isApproved: false).outcome == .rejectedByPolicy)
        #expect(Res(optionID: nil, optionName: nil, by: .timeout, isApproved: false).outcome == .expired)
        #expect(Res(optionID: nil, optionName: nil, by: .user, isApproved: false, state: .expired).outcome == .expired)
        #expect(Res(optionID: nil, optionName: nil, by: .cancelled, isApproved: false).outcome == .cancelled)
        #expect(
            Res(optionID: nil, optionName: nil, by: .unknown(""), isApproved: false, state: .cancelled).outcome
                == .cancelled)
    }

    private func approval(
        _ id: ApprovalID, requestID: String, attempt: Int, title: String = "删除 build/",
        state: ApprovalState = .pending
    ) -> Approval {
        Approval(
            id: id, runID: runA, instanceID: Fixture.instanceID, title: title, options: DemoData.approvalOptions,
            state: state, expiresAt: Fixture.now.addingTimeInterval(3600), createdAt: Fixture.now, requestID: requestID,
            attempt: attempt)
    }
}

@Suite("对话归并：保险箱请求")
struct ConversationVaultTests {
    @Test("vault.requested → vault.fulfilled")
    func fulfilled() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(
                .vaultRequested, runA,
                ["request_id": "vr-1", "name": "npm", "purpose": "发布 0.4.0", "fields": ["username", "password"]]))
        var card = try #require(output(r).first?.content.vaultRequest)
        #expect(output(r).first?.id == "vault-vr-1")
        #expect(card.requestID == "vr-1")
        #expect(card.name == "npm")
        #expect(card.purpose == "发布 0.4.0")
        #expect(card.purposeIsAIGenerated)
        #expect(card.fields == [.username, .password])
        #expect(card.status == .pending)
        r.apply(ev.add(.vaultFulfilled, runA, ["request_id": "vr-1", "name": "npm"]))
        card = try #require(output(r).first?.content.vaultRequest)
        #expect(card.status == .fulfilled)
        #expect(output(r).count == 1)
    }

    @Test("vault.requested → vault.declined")
    func declined() throws {
        var r = reducer()
        var ev = Events()
        r.apply(
            ev.add(
                .vaultRequested, runA, ["request_id": "vr-2", "name": "oss", "purpose": "上传", "fields": ["password"]]))
        r.apply(ev.add(.vaultDeclined, runA, ["request_id": "vr-2", "name": "oss"]))
        let card = try #require(output(r).first?.content.vaultRequest)
        #expect(card.status == .declined)
        #expect(card.fields == [.password])
    }

    @Test("请求事件已经过了保留期：只显示结果")
    func resultOnly() throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.vaultFulfilled, runA, ["request_id": "vr-3", "name": "github"]))
        let card = try #require(output(r).first?.content.vaultRequest)
        #expect(card.status == .fulfilled)
        #expect(card.name == "github")
        #expect(card.fields.isEmpty)
    }
}

@Suite("对话归并：运行状态")
struct ConversationRunStateTests {
    @Test(
        "等待类状态显示原因和下一步",
        arguments: [
            ("waiting_approval", RunState.waitingApproval, RunNextStep.approve),
            ("waiting_quota", .waitingQuota, .configureKey),
            ("waiting_device", .waitingDevice, .waitForComputer),
            ("waiting_children", .waitingChildren, .waitForSubtasks),
        ])
    func waiting(raw: String, state: RunState, next: RunNextStep) throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.runState, runA, ["state": "running"]))
        r.apply(ev.add(.agentMessage, runA, ["text": "等一下"]))
        r.apply(ev.add(.runState, runA, ["state": .string(raw), "reason": "原因", "attempt": 1]))
        let line = try statusLine(r)
        #expect(line.state == state)
        #expect(line.reason == "原因")
        #expect(line.attempt == 1)
        #expect(line.nextStep == next)
        #expect(!r.isStreaming, "等待时没在输出")
        #expect(try turn(r).state == state)
    }

    @Test("终态：成功、失败、取消", arguments: [RunState.succeeded, .failed, .cancelled])
    func terminal(state: RunState) throws {
        var r = reducer()
        var ev = Events()
        r.apply(ev.add(.runState, runA, ["state": "running"]))
        r.apply(ev.add(.turnStarted, runA))
        r.apply(ev.add(.agentMessage, runA, ["text": "做完了"]))
        #expect(r.isStreaming)
        r.apply(ev.add(.runState, runA, ["state": .string(state.rawValue), "reason": "done"]))
        let line = try statusLine(r)
        #expect(line.state == state)
        #expect(line.nextStep == nil)
        #expect(!r.isStreaming)
        #expect(output(r).first?.content.assistantText?.isStreaming == false)
        // 结束后迟到的输出不会让它重新变成“输出中”。
        r.apply(ev.add(.agentMessage, runA, ["text": "（迟到的一段）"]))
        #expect(!r.isStreaming)
    }

    @Test("排队、启动中、退避、重试")
    func lifecycle() throws {
        var r = reducer(runs: [Fixture.run(runA, state: .queued)])
        #expect(try statusLine(r).state == .queued)
        var ev = Events()
        r.apply(ev.add(.runState, runA, ["state": "starting"]))
        #expect(try statusLine(r).state == .starting)
        r.apply(ev.add(.runState, runA, ["state": "running", "attempt": 1]))
        #expect(r.isStreaming)
        r.apply(ev.add(.runState, runA, ["state": "backoff", "reason": "upstream rate limited", "attempt": 1]))
        var line = try statusLine(r)
        #expect(line.state == .backoff)
        #expect(line.reason == "upstream rate limited")
        #expect(!r.isStreaming)
        r.apply(ev.add(.runState, runA, ["state": "running", "attempt": 2]))
        line = try statusLine(r)
        #expect(line.state == .running)
        #expect(line.attempt == 2)
        #expect(r.isStreaming)
        // 不认识的状态照样显示，不当作结束。
        r.apply(ev.add(.runState, runA, ["state": "hibernating"]))
        #expect(try statusLine(r).state == .unknown("hibernating"))
    }

    @Test("状态行总在这一组最后；运行记录已结束时以它为准")
    func runRecordWins() throws {
        var run = Fixture.run(runA, state: .running)
        var r = reducer(runs: [run])
        var ev = Events()
        r.apply(ev.add(.runState, runA, ["state": "running"]))
        r.apply(ev.add(.agentMessage, runA, ["text": "…"]))
        #expect(try turn(r).items.tags == ["user", "text", "status"])
        // 事件流断了，刷新运行记录拿到了终态。
        run.state = .failed
        run.stateReason = "sandbox crashed"
        run.error = "exit 137"
        run.tokensUsed = 1_234
        r.upsert(run: run)
        let line = try statusLine(r)
        #expect(line.state == .failed)
        #expect(line.reason == "sandbox crashed")
        #expect(line.error == "exit 137")
        #expect(line.tokensUsed == 1_234)
        #expect(!r.isStreaming)
    }

    @Test("没有运行记录也没有 run.state：不显示状态行")
    func noStatus() {
        var r = ConversationReducer()
        var ev = Events()
        r.apply(ev.add(.agentMessage, runA, ["text": "x"]))
        #expect(r.items.tags == ["text"])
    }
}

@Suite("对话归并：去重与重置")
struct ConversationDedupTests {
    @Test("同一 seq 重复喂、比已处理的旧的：丢掉")
    func duplicates() {
        var r = reducer()
        var ev = Events()
        let first = ev.add(.agentMessage, runA, ["text": "一"])
        let second = ev.add(.agentMessage, runA, ["text": "二"])
        let results = [r.apply(first), r.apply(second), r.apply(second), r.apply(first)]
        #expect(results == [true, true, false, false])
        #expect(r.lastSeq == 2)
        #expect(output(r).first?.content.assistantText?.text == "一二")
    }

    @Test("批量喂：先按 seq 排序，重叠的部分不重复")
    func batch() {
        var ev = Events()
        ev.add(.agentMessage, runA, ["text": "a"])
        ev.add(.agentMessage, runA, ["text": "b"])
        ev.add(.agentMessage, runA, ["text": "c"])
        var r = reducer()
        r.apply(Array(ev.list.reversed()))
        #expect(output(r).first?.content.assistantText?.text == "abc")
        // 缓存和事件流补发有重叠。
        r.apply(Array(ev.list.suffix(2)))
        #expect(output(r).first?.content.assistantText?.text == "abc")
    }

    @Test("reset 清空事件，保留运行记录；之后重新喂得到同样的结果")
    func reset() throws {
        var ev = Events()
        ev.add(.runState, runA, ["state": "running"])
        ev.add(.agentMessage, runA, ["text": "回答"])
        ev.add(.permissionRequested, runA, ["request_id": "r1", "title": "t", "options": options])
        var r = reducer()
        r.apply(ev.list)
        r.link(approvals: [
            Approval(
                id: "ap-1", runID: runA, instanceID: Fixture.instanceID, title: "t", options: [],
                expiresAt: Fixture.now,
                createdAt: Fixture.now)
        ])
        let before = r.items
        r.reset()
        #expect(r.lastSeq == nil)
        #expect(r.items.tags == ["user", "status"])
        #expect(r.pendingApprovals.isEmpty)
        #expect(!r.isStreaming)
        r.apply(ev.list)
        #expect(r.items.map(\.id) == before.map(\.id))
        // 关联也一并清掉了（要重新 link）。
        #expect(r.pendingApprovals.first?.approvalID == nil)
        let again = r.apply(ev.list[0])
        #expect(!again)
    }
}
