import Foundation
import Testing

@testable import ThinktinKit

// MockClient：演示数据上的完整流程（和服务端的规则一致：没登录 signedOut、找不到 not_found、状态不对 conflict、
// 参数不对 invalid）。回放不等待（stepDelay: 0），用 `waitForPlayback()` 等脚本播完。

private let writer = DemoData.writerID
private let reviewer = DemoData.reviewerID

private func makeClient(signedIn: Bool = true, autoReply: Bool = true) -> MockClient {
    MockClient(state: DemoData.state(signedIn: signedIn), stepDelay: 0, autoReply: autoReply)
}

/// 抛出的 `ClientError` 的错误码（没抛错或不是 api 错误时为 nil）。
private func apiCode(_ body: () async throws -> Void) async -> APIErrorCode? {
    do {
        try await body()
        return nil
    } catch let e as ClientError {
        return e.apiCode
    } catch {
        return nil
    }
}

/// 收事件流回调（回调在后台线程上）。
private final class Collector: EventListening, Sendable {
    let received = Locked<[EventStreamElement]>([])

    func onEvent(_ event: InstanceEvent) { received.withLock { $0.append(.event(event)) } }
    func onReset(oldestSeq: UInt64, latestSeq: UInt64?) {
        received.withLock { $0.append(.reset(oldestSeq: oldestSeq, latestSeq: latestSeq)) }
    }
    func onStatus(_ status: StreamStatus) { received.withLock { $0.append(.status(status)) } }

    var events: [InstanceEvent] {
        received.value.compactMap {
            if case .event(let e) = $0 { return e }
            return nil
        }
    }

    var statuses: [StreamStatus] {
        received.value.compactMap {
            if case .status(let s) = $0 { return s }
            return nil
        }
    }

    /// 等到满足条件（最多约 5 秒）。
    func wait(until condition: @Sendable ([EventStreamElement]) -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition(received.value) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition(received.value)
    }
}

/// 读事件流直到满足条件，返回读到的全部元素。
private func collect(
    _ stream: AsyncStream<EventStreamElement>, until done: (EventStreamElement) -> Bool
) async -> [EventStreamElement] {
    var out: [EventStreamElement] = []
    for await element in stream {
        out.append(element)
        if done(element) { break }
    }
    return out
}

private func isTerminalState(_ element: EventStreamElement) -> Bool {
    if case .event(let e) = element, let s = e.runStatePayload?.state { return s.isTerminal }
    return false
}

@Suite("MockClient：账号")
struct MockAccountTests {
    @Test("登录 → me → 改语言 → 退出")
    func loginFlow() async throws {
        let client = makeClient(signedIn: false)
        #expect(!client.signedIn())
        await #expect(throws: ClientError.signedOut) { try await client.me() }
        #expect(await apiCode { try await client.sendCode(phone: "12345") } == .invalid)
        try await client.sendCode(phone: "+8613800138000")
        #expect(await apiCode { _ = try await client.login(phone: "+8613800138000", code: "000000") } == .invalid)
        #expect(!client.signedIn())

        let result = try await client.login(phone: "+8613800138000", code: "123456")
        #expect(!result.isNewUser)
        #expect(result.user.id == DemoData.userID)
        #expect(client.signedIn())
        let session = try #require(client.state.session)
        #expect(session.deviceID == DemoData.deviceID)
        #expect(session.accessToken.hasPrefix("mock-access-"))

        let me = try await client.me()
        #expect(me.displayName == "张三")
        #expect(me.nameForDisplay == "张三")
        let changed = try await client.setLocale(.en)
        #expect(changed.locale == .en)
        #expect(try await client.me().locale == .en)
        try await client.setPushToken(.apns(deviceToken: Data([1, 2, 3])))
        #expect(
            await apiCode { try await client.setPushToken(PushRegistration(channel: .apns, token: "")) } == .invalid)

        try await client.logout()
        #expect(!client.signedIn())
        await #expect(throws: ClientError.signedOut) { try await client.agents() }
    }

    @Test("新手机号登录：算新用户")
    func newUser() async throws {
        let client = makeClient(signedIn: false)
        let result = try await client.login(phone: "+8613900139000", code: "123456", push: nil)
        #expect(result.isNewUser)
        #expect(result.user.phone == "+8613900139000")
    }

    @Test("缓存类方法不要求登录")
    func cachedWithoutSession() throws {
        let client = makeClient(signedIn: false)
        #expect(try client.cachedInstances().count == 2)
        #expect(try client.cachedRuns(instanceID: writer, limit: 10).count == 3)
        #expect(try client.cachedUnread() == 3)
        #expect(try client.cachedInbox(before: nil, limit: 2).count == 2)
    }

    @Test("failNext：下一次调用抛排好的错误，之后恢复")
    func failNext() async throws {
        let client = makeClient()
        client.failNext(with: .network(message: "offline"))
        client.failNext(with: .accountFrozen)
        await #expect(throws: ClientError.network(message: "offline")) { try await client.instances() }
        #expect(throws: ClientError.accountFrozen) { try client.cachedInstances() }
        #expect(try await client.instances().count == 2)
    }

    @Test("全部停止：取消运行、暂停计划；下线其他设备")
    func stopAll() async throws {
        let client = makeClient()
        let result = try await client.stopAll()
        // 演示数据里进行中的：等审批的、等保险箱的。
        #expect(result.runsCancelled == 2)
        #expect(result.plansPaused == 2)
        #expect(client.state.runs.filter(\.state.isActive).isEmpty)
        #expect(client.state.plans.allSatisfy { $0.isPaused })
        // 运行结束：未决的审批作废、审批提醒标已读。
        #expect(client.state.approvals.allSatisfy { $0.state == .cancelled })
        #expect(try await client.approvals().isEmpty)
        #expect(client.state.inbox.first { $0.approvalID != nil }?.isRead == true)

        let others = try await client.signOutOtherDevices(stopAgents: false)
        #expect(others.devicesSignedOut == 1)
        #expect(others.stopped == nil)
        let both = try await client.signOutOtherDevices(stopAgents: true)
        #expect(both.stopped?.runsCancelled == 0)
    }
}

@Suite("MockClient：agent 与实例")
struct MockInstanceTests {
    @Test("agent 目录 → 领养 → 实例列表")
    func adopt() async throws {
        let client = makeClient()
        let agents = try await client.agents()
        #expect(agents.map(\.id) == [DemoData.claudeAgentID, DemoData.codexAgentID, DemoData.hermesAgentID])
        let instance = try await client.adopt(agentID: DemoData.hermesAgentID, name: "  研究助手 ", harness: nil)
        #expect(instance.name == "研究助手")
        #expect(instance.harness == "acp")
        #expect(instance.agentVersion == "0.19.0")
        #expect(instance.state == .running)
        let list = try await client.instances()
        #expect(list.count == 3)
        #expect(list.last?.id == instance.id)
        let cli = try await client.adopt(agentID: DemoData.claudeAgentID, name: "命令行", harness: "cli")
        #expect(cli.harness == "cli")

        #expect(await apiCode { _ = try await client.adopt(agentID: "nope", name: "x", harness: nil) } == .notFound)
        #expect(
            await apiCode { _ = try await client.adopt(agentID: DemoData.claudeAgentID, name: " ", harness: nil) }
                == .invalid)
        #expect(
            await apiCode { _ = try await client.adopt(agentID: DemoData.codexAgentID, name: "x", harness: "cli") }
                == .invalid)
    }

    @Test("改名、升级 / 回滚、模型路由、删除")
    func manage() async throws {
        let client = makeClient()
        #expect(try await client.renameInstance(writer, name: "写作").name == "写作")
        #expect(await apiCode { _ = try await client.renameInstance(writer, name: "") } == .invalid)
        #expect(await apiCode { _ = try await client.renameInstance("missing", name: "x") } == .notFound)

        // 代码审查是 2.2.1，最新是 2.2.2。
        #expect(try await client.setInstanceVersion(reviewer, version: nil).agentVersion == "2.2.2")
        #expect(try await client.setInstanceVersion(reviewer, version: "2.1.0").agentVersion == "2.1.0")
        #expect(await apiCode { _ = try await client.setInstanceVersion(reviewer, version: "9.9.9") } == .invalid)

        let routes = try await client.modelRoutes(instanceID: writer)
        #expect(routes.map(\.alias) == ["main", "fast"])
        #expect(routes[0].fallbacks.count == 1)
        let replaced = [
            ModelRoute(alias: "main", credentialID: DemoData.deepseekCredentialID, upstreamModel: "deepseek-v4-pro")
        ]
        try await client.setModelRoutes(instanceID: writer, routes: replaced)
        #expect(try await client.modelRoutes(instanceID: writer) == replaced)
        let duplicate = replaced + replaced
        #expect(await apiCode { try await client.setModelRoutes(instanceID: writer, routes: duplicate) } == .invalid)
        let unknownKey = [ModelRoute(alias: "main", credentialID: "nope", upstreamModel: "m")]
        #expect(await apiCode { try await client.setModelRoutes(instanceID: writer, routes: unknownKey) } == .invalid)
        let tooMany = [
            ModelRoute(
                alias: "main", credentialID: DemoData.claudeCredentialID, upstreamModel: "m",
                fallbacks: Array(
                    repeating: RouteFallback(credentialID: DemoData.deepseekCredentialID, upstreamModel: "m"), count: 4)
            )
        ]
        #expect(await apiCode { try await client.setModelRoutes(instanceID: writer, routes: tooMany) } == .invalid)

        try await client.deleteInstance(reviewer)
        #expect(try await client.instances().map(\.id) == [writer])
        #expect(try await client.plans(instanceID: nil).allSatisfy { $0.instanceID == writer })
        #expect(await apiCode { _ = try await client.modelRoutes(instanceID: reviewer) } == .notFound)
    }
}

@Suite("MockClient：运行与事件流")
struct MockRunTests {
    @Test("createRun：自动回放 agent 的回答，运行结束、写收件箱、记 token")
    func createRunPlaysReply() async throws {
        let client = makeClient()
        let unreadBefore = client.state.unreadCount
        let run = try await client.createRun(instanceID: writer, prompt: "  整理一下会议纪要  ")
        #expect(run.prompt == "整理一下会议纪要")
        #expect(run.state == .queued)
        #expect(run.source == .user)
        await client.waitForPlayback()

        let finished = try await client.getRun(run.id)
        #expect(finished.state == .succeeded)
        #expect(finished.startedAt != nil)
        #expect(finished.finishedAt != nil)
        #expect(finished.tokensUsed == 2_780)
        #expect(finished.summary?.hasPrefix("收到：「整理一下会议纪要」。") == true)
        #expect(try await client.runs(instanceID: writer, limit: 1).first?.id == run.id)

        let events = (client.state.events[writer] ?? []).filter { $0.runID == run.id }
        #expect(events.first?.kind == .runState)
        #expect(events.last?.runStatePayload?.state == .succeeded)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.seq + 1 == $1.seq }, "seq 连续递增")

        // 归并成对话：用户消息、思考、工具调用、回答、状态行。
        let turn = try #require(
            Conversation.turns(runs: client.state.runs, events: client.state.events[writer] ?? []).first {
                $0.runID == run.id
            })
        #expect(turn.items.tags == ["user", "thought", "tool", "text", "status"])
        #expect(turn.items[2].content.toolCall?.status == .completed)
        #expect(turn.items[3].content.assistantText?.text.contains("要点三") == true)

        let inbox = try await client.syncInbox(limit: 10)
        #expect(inbox.items.first?.kind == .runFinished)
        #expect(inbox.items.first?.runID == run.id)
        #expect(inbox.items.first?.isAIGenerated == true)
        #expect(inbox.unread == unreadBefore + 1)

        #expect(await apiCode { _ = try await client.createRun(instanceID: writer, prompt: "   ") } == .invalid)
        #expect(await apiCode { _ = try await client.createRun(instanceID: "missing", prompt: "x") } == .notFound)
        #expect(await apiCode { _ = try await client.getRun("missing") } == .notFound)
    }

    @Test("sendMessage → 事件脚本经事件流实时推送", .timeLimit(.minutes(1)))
    func liveStream() async throws {
        let client = makeClient()
        let stream = try client.events(instanceID: writer, afterSeq: client.state.lastSeq(of: writer))
        let run = try await client.sendMessage(instanceID: writer, text: "写一首诗")
        let received = await collect(stream, until: isTerminalState)
        #expect(received.prefix(2) == [.status(.connecting), .status(.live)], "已经显示过的历史不再补发")
        let events = received.compactMap { element -> InstanceEvent? in
            if case .event(let e) = element { return e }
            return nil
        }
        #expect(events.allSatisfy { $0.runID == run.id })
        #expect(
            events.map(\.kind) == [
                .runState, .runState, .turnStarted, .agentThought, .agentThought, .toolCall, .toolCallUpdate,
                .toolCallUpdate,
                .agentMessage, .agentMessage, .agentMessage, .agentUsage, .turnEnded, .runState,
            ])
        #expect(events.map(\.runStatePayload?.state).compactMap { $0 } == [.starting, .running, .succeeded])
        #expect(events.filter { $0.kind == .agentMessage }.allSatisfy { $0.isAIGenerated })
    }

    @Test("订阅：先补发 afterSeq 之后的历史，再回放设定的脚本（状态、重置）", .timeLimit(.minutes(1)))
    func scriptedSubscription() async throws {
        let client = makeClient()
        let history = client.state.events[writer] ?? []
        client.setScript(
            MockEventScript(
                runID: DemoData.postRunID,
                steps: [
                    .status(.reconnecting(retryIn: 2)), .status(.live), .wait(5),
                    .event(.agentMessage, payload: ["text": "补一句"]),
                    .event(.agentError, payload: ["message": "late"], runID: DemoData.weeklyRunID),
                    .reset(oldestSeq: 3, latestSeq: 40),
                ]), for: writer)
        let collector = Collector()
        let handle = try client.subscribe(instanceID: writer, afterSeq: 5, listener: collector)
        let done = await collector.wait { list in
            list.contains { if case .reset = $0 { return true } else { return false } }
        }
        #expect(done)
        #expect(collector.statuses == [.connecting, .live, .reconnecting(retryIn: 2), .live])
        let events = collector.events
        #expect(events.prefix(history.count - 5).map(\.seq) == history.dropFirst(5).map(\.seq))
        let scripted = Array(events.dropFirst(history.count - 5))
        #expect(scripted.map(\.kind) == [.agentMessage, .agentError])
        #expect(scripted[0].runID == DemoData.postRunID)
        #expect(scripted[1].runID == DemoData.weeklyRunID)
        #expect(scripted[0].seq == UInt64(history.count + 1))
        #expect(collector.received.value.last == .reset(oldestSeq: 3, latestSeq: 40))

        // 脚本只用一次；停止后不再收到事件。
        handle.stop()
        handle.stop()
        #expect(handle.isStopped)
        let countAfterStop = collector.received.value.count
        client.emit(.agentMessage, payload: ["text": "没人听"], runID: DemoData.postRunID, instanceID: writer)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(collector.received.value.count == countAfterStop)
    }

    @Test("订阅：没登录、实例不存在时给最终状态并结束", .timeLimit(.minutes(1)))
    func subscriptionFailures() async throws {
        let signedOut = makeClient(signedIn: false)
        let s1 = try signedOut.events(instanceID: writer)
        var r1: [EventStreamElement] = []
        for await e in s1 { r1.append(e) }
        #expect(r1 == [.status(.connecting), .status(.signedOut)])

        let client = makeClient()
        let s2 = try client.events(instanceID: "missing")
        var r2: [EventStreamElement] = []
        for await e in s2 { r2.append(e) }
        #expect(r2 == [.status(.connecting), .status(.notFound)])
    }

    @Test("缓存的事件：afterSeq 之后、按 limit")
    func cachedEvents() throws {
        let client = makeClient()
        let all = client.state.events[writer] ?? []
        #expect(try client.cachedEvents(instanceID: writer, afterSeq: 0, limit: 1000).count == all.count)
        let page = try client.cachedEvents(instanceID: writer, afterSeq: 3, limit: 2)
        #expect(page.map(\.seq) == [4, 5])
        #expect(try client.cachedEvents(instanceID: writer, afterSeq: 0, limit: -1).isEmpty)
    }

    @Test("cancelRun：取消、重复取消冲突")
    func cancel() async throws {
        let client = makeClient(autoReply: false)
        let run = try await client.createRun(instanceID: writer, prompt: "长任务")
        let cancelled = try await client.cancelRun(run.id)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.stateReason == "cancelled by user")
        #expect(cancelled.finishedAt != nil)
        let last = try #require(client.state.events[writer]?.last)
        #expect(last.runID == run.id)
        #expect(last.runStatePayload == RunStatePayload(state: .cancelled, reason: "cancelled by user"))
        #expect(await apiCode { _ = try await client.cancelRun(run.id) } == .conflict)
        // 取消不写收件箱。
        #expect(client.state.inbox.allSatisfy { $0.runID != run.id })
        // 取消之后再播这个运行的脚本（取消和播放赛跑时晚到的那几步）：不出新事件，运行不会被“复活”。
        let count = client.state.events[writer]?.count
        client.play(DemoData.replyScript(for: run), instanceID: writer)
        await client.waitForPlayback()
        #expect(client.state.events[writer]?.count == count)
        #expect(try await client.getRun(run.id).state == .cancelled)
    }

    @Test("cancelRun：播放中的回答停下，之后不会被“复活”")
    func cancelDuringPlayback() async throws {
        let client = MockClient(state: DemoData.state(), stepDelay: 0.01)
        let run = try await client.createRun(instanceID: writer, prompt: "写报告")
        try await Task.sleep(nanoseconds: 30_000_000)
        _ = try await client.cancelRun(run.id)
        await client.waitForPlayback()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(try await client.getRun(run.id).state == .cancelled)
        let last = try #require(client.state.events[writer]?.last { $0.runID == run.id })
        #expect(last.runStatePayload?.state == .cancelled)
    }

    @Test("cancelRun wholeTree：停掉整棵运行树")
    func cancelTree() async throws {
        let client = makeClient(autoReply: false)
        let root: RunID = "tree-root"
        client.update { s in
            let now = Date()
            s.runs += [
                Run(
                    id: root, kind: .pipeline, instanceID: writer, source: .user, prompt: "流水线",
                    state: .waitingChildren, createdAt: now),
                Run(
                    id: "tree-a", instanceID: writer, parentRunID: root, rootRunID: root, stepKey: "a",
                    source: .pipeline,
                    prompt: "第一步", state: .succeeded, createdAt: now.addingTimeInterval(1)),
                Run(
                    id: "tree-b", instanceID: reviewer, parentRunID: root, rootRunID: root, stepKey: "b",
                    source: .pipeline,
                    prompt: "第二步", state: .running, createdAt: now.addingTimeInterval(2)),
            ]
        }
        #expect(try await client.runTree("tree-b").map(\.id) == [root, "tree-a", "tree-b"])
        let stopped = try await client.cancelRun("tree-b", wholeTree: true)
        #expect(stopped.state == .cancelled)
        let states = try await client.runTree(root).map(\.state)
        #expect(states == [.cancelled, .succeeded, .cancelled])
        let treeEvent = try #require(client.state.events[reviewer]?.last)
        #expect(treeEvent.runStatePayload?.tree == true)
    }

    @Test("产出物：列表、内容")
    func artifacts() async throws {
        let client = makeClient()
        let list = try await client.runArtifacts(DemoData.weeklyRunID)
        #expect(list.map(\.id) == [DemoData.weeklyArtifactID])
        let data = try await client.artifactContent(DemoData.weeklyArtifactID)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("# 本周周报要点"))
        #expect(await apiCode { _ = try await client.artifactContent("missing") } == .notFound)
        // agent 发布新的产出物：事件同时记进状态。
        client.emit(
            .artifactPublished, payload: ["artifact_id": "art-new", "name": "图.png", "version": 1, "size": 10],
            runID: DemoData.weeklyRunID, instanceID: writer)
        let updated = try await client.runArtifacts(DemoData.weeklyRunID)
        #expect(updated.last?.contentType == "image/png")
        #expect(try await client.artifactContent("art-new").isEmpty == false)
    }
}

@Suite("MockClient：审批")
struct MockApprovalTests {
    @Test("发消息要审批 → 列出 → 决定（批准）→ 接着播完")
    func approveFlow() async throws {
        let client = makeClient()
        let run = try await client.sendMessage(instanceID: writer, text: "部署到预发环境")
        await client.waitForPlayback()
        #expect(try await client.getRun(run.id).state == .waitingApproval)
        let pending = try await client.approvals().filter { $0.runID == run.id }
        let approval = try #require(pending.first)
        #expect(approval.title == "执行：部署到预发环境")
        #expect(approval.toolCall?.toolCallID.hasPrefix("tc-perm-") == true)
        let inboxItem = try #require(client.state.inbox.first { $0.approvalID == approval.id })
        #expect(!inboxItem.isRead)

        let decided = try await client.decideApproval(approval.id, optionID: "allow")
        #expect(decided.state == .approved)
        await client.waitForPlayback()
        #expect(try await client.getRun(run.id).state == .succeeded)
        #expect(client.state.inbox.first { $0.approvalID == approval.id }?.isRead == true)
        #expect(try await client.approvals().allSatisfy { $0.id != approval.id })

        // 对话里：审批卡片已决（用户批准），工具调用完成。
        let turn = try #require(
            Conversation.turns(
                runs: client.state.runs, events: client.state.events[writer] ?? [], approvals: [approval]
            )
            .first { $0.runID == run.id })
        let card = try #require(turn.items.compactMap(\.content.approval).first)
        #expect(card.approvalID == approval.id)
        #expect(card.resolution?.by == .user)
        #expect(card.resolution?.isApproved == true)
        #expect(turn.items.compactMap(\.content.toolCall).first?.status == .completed)
        #expect(turn.state == .succeeded)

        #expect(await apiCode { _ = try await client.decideApproval(approval.id, optionID: "allow") } == .conflict)
        #expect(await apiCode { _ = try await client.decideApproval("missing", optionID: "allow") } == .notFound)
    }

    @Test("演示数据里的审批：拒绝后收尾")
    func rejectDemo() async throws {
        let client = makeClient()
        #expect(
            await apiCode { _ = try await client.decideApproval(DemoData.pendingApprovalID, optionID: "maybe") }
                == .invalid)
        let decided = try await client.decideApproval(DemoData.pendingApprovalID, optionID: "reject")
        #expect(decided.state == .rejected)
        await client.waitForPlayback()
        let run = try await client.getRun(DemoData.postRunID)
        #expect(run.state == .succeeded)
        let resolved = try #require(client.state.events[writer]?.first { $0.kind == .permissionResolved })
        guard case .permissionResolved(let p) = resolved.payload else {
            Issue.record("不是 permission_resolved")
            return
        }
        #expect(p.requestID == DemoData.pendingPermissionRequestID)
        #expect(p.optionID == "reject")
        #expect(p.by == .user)
        let toolUpdate = try #require(client.state.events[writer]?.last { $0.kind == .toolCallUpdate })
        #expect(toolUpdate.toolCallPayload?.status == .failed)
    }

    @Test("运行取消后审批作废，不能再决定")
    func cancelledRunApproval() async throws {
        let client = makeClient()
        _ = try await client.cancelRun(DemoData.postRunID)
        #expect(client.state.approvals.first { $0.id == DemoData.pendingApprovalID }?.state == .cancelled)
        #expect(
            await apiCode { _ = try await client.decideApproval(DemoData.pendingApprovalID, optionID: "allow") }
                == .conflict)
    }
}

@Suite("MockClient：计划")
struct MockPlanTests {
    @Test("新建 → 列表（没有触发器）→ 详情 → 暂停 / 恢复 → 删除")
    func createAndManage() async throws {
        let client = makeClient()
        let at = Date().addingTimeInterval(3600)
        let plan = try await client.createPlan(
            NewPlan(
                instanceID: writer, title: "晨报", goal: "每天早上汇总新闻",
                triggers: [.cron(expression: "0 8 * * *", timeZone: "Asia/Shanghai"), .once(at)]))
        #expect(plan.createdBy == .user)
        #expect(!plan.awaitingConfirmation)
        #expect(plan.revision == 1)
        #expect(plan.triggers.count == 2)
        #expect(plan.nextFireAt == at)
        #expect(plan.policy == PlanPolicy())

        let list = try await client.plans(instanceID: writer)
        let listed = try #require(list.first { $0.id == plan.id })
        #expect(listed.triggers.isEmpty, "列表接口里没有触发器")
        #expect(try await client.plans(instanceID: reviewer).allSatisfy { $0.instanceID == reviewer })
        #expect(try await client.plans(instanceID: nil).count == 3)
        #expect(try await client.getPlan(plan.id).triggers.count == 2)

        #expect(try await client.setPlanPaused(plan.id, paused: true).isPaused)
        #expect(try await client.setPlanPaused(plan.id, paused: false).isPaused == false)
        try await client.deletePlan(plan.id)
        #expect(await apiCode { _ = try await client.getPlan(plan.id) } == .notFound)
        #expect(await apiCode { try await client.deletePlan(plan.id) } == .notFound)
    }

    @Test("新建的校验：标题、触发器、实例")
    func validation() async {
        let client = makeClient()
        let cron = Schedule.cron(expression: "0 8 * * *", timeZone: "Asia/Shanghai")
        #expect(
            await apiCode {
                _ = try await client.createPlan(NewPlan(instanceID: writer, title: " ", goal: "g", triggers: [cron]))
            } == .invalid)
        #expect(
            await apiCode {
                _ = try await client.createPlan(NewPlan(instanceID: writer, title: "t", goal: "g", triggers: []))
            } == .invalid)
        #expect(
            await apiCode {
                _ = try await client.createPlan(NewPlan(instanceID: "missing", title: "t", goal: "g", triggers: [cron]))
            } == .notFound)
        let badStep = PlanStep(key: "a", instanceID: "missing", prompt: "p")
        #expect(
            await apiCode {
                _ = try await client.createPlan(
                    NewPlan(instanceID: writer, title: "t", goal: "g", triggers: [cron], steps: [badStep]))
            } == .notFound)
    }

    @Test("agent 建的计划：确认前不能恢复，按版本确认")
    func confirm() async throws {
        let client = makeClient()
        let plan = try await client.getPlan(DemoData.agentPlanID)
        #expect(plan.createdBy == .agent)
        #expect(plan.awaitingConfirmation)
        #expect(await apiCode { _ = try await client.setPlanPaused(plan.id, paused: false) } == .conflict)
        // 暂停总是可以的。
        #expect(try await client.setPlanPaused(plan.id, paused: true).isPaused)
        #expect(await apiCode { _ = try await client.confirmPlan(plan.id, revision: 1) } == .conflict)
        let confirmed = try await client.confirmPlan(plan.id, revision: plan.revision)
        #expect(!confirmed.awaitingConfirmation)
        #expect(await apiCode { _ = try await client.confirmPlan(plan.id, revision: plan.revision) } == .conflict)
        #expect(try await client.setPlanPaused(plan.id, paused: false).isPaused == false)
    }
}

@Suite("MockClient：收件箱")
struct MockInboxTests {
    @Test("同步、分页、已读计数")
    func readCounts() async throws {
        let client = makeClient()
        let page = try await client.syncInbox(limit: 10)
        #expect(page.items.count == 5)
        #expect(page.unread == 3)
        #expect(try client.cachedUnread() == 3)

        let older = try await client.olderInbox(before: "0192f3a0-0000-7000-8000-000000001002", limit: 2)
        #expect(
            older.map(\.id.rawValue) == [
                "0192f3a0-0000-7000-8000-000000001003", "0192f3a0-0000-7000-8000-000000001004",
            ])
        #expect(try await client.olderInbox(before: "0192f3a0-0000-7000-8000-000000001005", limit: 5).isEmpty)
        #expect(try await client.syncInbox(limit: 2).items.count == 2)

        #expect(try await client.markInboxRead(ids: ["0192f3a0-0000-7000-8000-000000001001"], upTo: nil) == 2)
        // 全部已读到某一条为止：那一条和更早的。
        #expect(try await client.markInboxRead(ids: [], upTo: "0192f3a0-0000-7000-8000-000000001003") == 1)
        #expect(client.state.inbox.first { $0.id == "0192f3a0-0000-7000-8000-000000001002" }?.isRead == false)
        #expect(try await client.markInboxRead(ids: [], upTo: nil) == 0)
        #expect(try client.cachedUnread() == 0)
        #expect(try await client.syncInbox(limit: 10).unread == 0)
    }
}

@Suite("MockClient：保险箱与密码拦截")
struct MockVaultTests {
    @Test("保险箱条目：新建、详情、修改、删除")
    func crud() async throws {
        let client = makeClient()
        #expect(try await client.vaultItems().map(\.name) == ["github", "aliyun-oss"])
        let created = try await client.createVaultItem(
            NewVaultItem(name: "npm", purpose: "发布包", username: "", password: "npm_token", instanceIDs: [reviewer]))
        #expect(created.name == "npm")
        #expect(!created.hasUsername)
        #expect(created.instanceIDs == [reviewer])
        #expect(try await client.vaultItems().count == 3)

        #expect(
            await apiCode {
                _ = try await client.createVaultItem(NewVaultItem(name: "npm", purpose: "", password: "x"))
            } == .conflict)
        #expect(
            await apiCode {
                _ = try await client.createVaultItem(NewVaultItem(name: "NPM Token", purpose: "", password: "x"))
            } == .invalid)
        #expect(
            await apiCode {
                _ = try await client.createVaultItem(NewVaultItem(name: "pypi", purpose: "", password: ""))
            } == .invalid)

        let detail = try await client.vaultItem(DemoData.githubVaultID)
        #expect(detail.username == "zhangsan")
        #expect(detail.id == DemoData.githubVaultID)

        let updated = try await client.updateVaultItem(
            created.id, change: VaultItemUpdate(purpose: "发布 @thinktin/sdk", username: "bot", instanceIDs: []))
        #expect(updated.purpose == "发布 @thinktin/sdk")
        #expect(updated.hasUsername)
        #expect(updated.isAvailableToAllInstances)
        #expect(updated.updatedAt >= created.updatedAt)
        #expect(try await client.vaultItem(created.id).username == "bot")

        // 校验失败时什么都不改。
        let failed = await apiCode {
            _ = try await client.updateVaultItem(created.id, change: VaultItemUpdate(purpose: "不该生效", password: ""))
        }
        #expect(failed == .invalid)
        #expect(try await client.vaultItem(created.id).item.purpose == "发布 @thinktin/sdk")

        try await client.deleteVaultItem(created.id)
        #expect(try await client.vaultItems().count == 2)
        #expect(await apiCode { try await client.deleteVaultItem(created.id) } == .notFound)
        #expect(await apiCode { _ = try await client.vaultItem(created.id) } == .notFound)
    }

    @Test("agent 请填的表单：填写后存进保险箱、运行接着播完")
    func fulfillRequest() async throws {
        let client = makeClient()
        let pending = try await client.vaultRequests(all: false)
        #expect(pending.map(\.id) == [DemoData.npmVaultRequestID])
        #expect(
            await apiCode {
                _ = try await client.fulfillVaultRequest(
                    DemoData.npmVaultRequestID, username: "", password: "", purpose: nil)
            } == .invalid)

        let done = try await client.fulfillVaultRequest(
            DemoData.npmVaultRequestID, username: "", password: "npm_abc", purpose: nil)
        #expect(done.status == .fulfilled)
        #expect(done.resolvedAt != nil)
        let item = try #require(try await client.vaultItems().first { $0.id == done.itemID })
        #expect(item.name == "npm")
        #expect(item.purpose == "发布 @thinktin/sdk 0.4.0 到 npm")
        #expect(item.instanceIDs == [reviewer])
        #expect(client.state.events[reviewer]?.contains { $0.kind == .vaultFulfilled } == true)
        await client.waitForPlayback()
        #expect(try await client.getRun(DemoData.publishRunID).state == .succeeded)

        #expect(try await client.vaultRequests(all: false).isEmpty)
        #expect(try await client.vaultRequests(all: true).count == 1)
        #expect(
            await apiCode {
                _ = try await client.fulfillVaultRequest(
                    DemoData.npmVaultRequestID, username: "", password: "x", purpose: nil)
            } == .conflict)
    }

    @Test("agent 请填的表单：重名时换个名字；拒绝")
    func declineRequest() async throws {
        let client = makeClient()
        // agent 又要一个叫 github 的（已经有了）。
        client.emit(
            .vaultRequested,
            payload: [
                "request_id": "vr-gh", "name": "github", "purpose": "推送到另一个仓库", "fields": ["username", "password"],
            ],
            runID: DemoData.publishRunID, instanceID: reviewer)
        let request = try #require(try await client.vaultRequests(all: false).first { $0.id == "vr-gh" })
        #expect(request.needsUsername)
        let filled = try await client.fulfillVaultRequest("vr-gh", username: "me", password: "pw", purpose: "另一个仓库")
        let item = try #require(try await client.vaultItems().first { $0.id == filled.itemID })
        #expect(item.name == "github_2")
        #expect(item.purpose == "另一个仓库")
        #expect(item.hasUsername)
        await client.waitForPlayback()

        client.emit(
            .vaultRequested, payload: ["request_id": "vr-oss", "name": "oss", "purpose": "上传", "fields": ["password"]],
            runID: nil, instanceID: reviewer)
        let declined = try await client.declineVaultRequest("vr-oss")
        #expect(declined.status == .declined)
        #expect(client.state.events[reviewer]?.last?.kind == .vaultDeclined)
        #expect(await apiCode { _ = try await client.declineVaultRequest("vr-oss") } == .conflict)
        #expect(await apiCode { _ = try await client.declineVaultRequest("missing") } == .notFound)
    }

    @Test("sendMessage 遇到像密码的内容抛 containsSecrets，allowSecrets 时照发")
    func containsSecrets() async throws {
        let client = makeClient(autoReply: false)
        let runsBefore = client.state.runs.count
        let text = "帮我配一下：key 是 sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv，密码：hunter2pass"
        await #expect(throws: ClientError.containsSecrets(count: 2)) {
            _ = try await client.sendMessage(instanceID: writer, text: text)
        }
        #expect(client.state.runs.count == runsBefore, "拦下的消息没有发出去")
        let error = ClientError.containsSecrets(count: 2)
        #expect(error.recovery == .interceptSecrets(count: 2))
        #expect(error.secretCount == 2)

        let run = try await client.sendMessage(instanceID: writer, text: text, allowSecrets: true)
        #expect(run.prompt == text)
        #expect(client.state.runs.count == runsBefore + 1)
        // 普通消息照常发。
        _ = try await client.sendMessage(instanceID: writer, text: "今天天气怎么样")
        // 没登录时先报没登录。
        try await client.logout()
        await #expect(throws: ClientError.signedOut) {
            _ = try await client.sendMessage(instanceID: writer, text: text)
        }
    }

    @Test("把拦下的值存进保险箱，消息换成引用")
    func saveSecretFromMessage() async throws {
        let client = makeClient()
        let message =
            "用这个 token：ghp_abcdefghijklmnopqrstuvwxyz0123456789 推送，别用 ghp_abcdefghijklmnopqrstuvwxyz0123456789 以外的"
        let secrets = client.detectSecrets(in: message)
        #expect(secrets.count == 2)
        let first = try #require(secrets.first)
        #expect(first.kind == .token)
        #expect(first.service == "github")
        let name = client.secretDetector.uniqueVaultName(
            base: first.suggestedName, taken: try await client.vaultItems().map(\.name))
        #expect(name == "github_2")
        let saved = try await client.saveSecretFromMessage(
            message: message, value: first.value, item: NewVaultItem(name: name, purpose: "推送", password: first.value))
        #expect(saved.item.name == "github_2")
        #expect(saved.message == "用这个 token：[vault:github_2] 推送，别用 [vault:github_2] 以外的")
        #expect(client.detectSecrets(in: saved.message).isEmpty)
        // 重名时抛 conflict。
        #expect(
            await apiCode {
                _ = try await client.saveSecretFromMessage(
                    message: message, value: first.value, item: NewVaultItem(name: "github", purpose: "", password: "x")
                )
            } == .conflict)
    }
}

@Suite("Mock 的密码检查")
struct MockSecretDetectorTests {
    let detector = MockSecretDetector()

    @Test("认出各种 key、令牌、私钥、带标签的密码")
    func detect() throws {
        let text = """
            anthropic: sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA
            openai: sk-proj-BBBBBBBBBBBBBBBBBBBBBBBB
            github: gho_CCCCCCCCCCCCCCCCCCCCCCCC
            -----BEGIN OPENSSH PRIVATE KEY-----
            password = s3cr3tvalue
            """
        let found = detector.detectSecrets(in: text)
        #expect(found.map(\.kind) == [.apiKey, .apiKey, .token, .privateKey, .labeled])
        #expect(found.map(\.suggestedName) == ["anthropic", "openai", "github", "private_key", "password"])
        #expect(found[3].isStorable == false)
        #expect(found[4].value == "s3cr3tvalue", "带标签的只取值，不含标签")
        for secret in found {
            let range = try #require(secret.range(in: text))
            #expect(String(text[range]) == secret.value)
        }
        #expect(detector.detectSecrets(in: "普通的一句话，sk-短的不算").isEmpty)
        #expect(detector.detectSecrets(in: "密码：123").isEmpty, "太短的不算")
    }

    @Test("同一处只报一次（anthropic 的 key 不会再被当成 openai 的）")
    func noOverlap() {
        let found = detector.detectSecrets(in: "sk-ant-api03-ZZZZZZZZZZZZZZZZZZZZZZZZZZ")
        #expect(found.count == 1)
        #expect(found.first?.service == "anthropic")
    }

    @Test("换成引用、取不重复的名字、规范名字")
    func helpers() {
        let refs = [SecretReference(value: "AAA", name: "a"), SecretReference(value: "", name: "empty")]
        #expect(detector.redactMessage("x AAA y AAA", references: refs) == "x [vault:a] y [vault:a]")
        #expect(detector.uniqueVaultName(base: "github", taken: []) == "github")
        #expect(detector.uniqueVaultName(base: "github", taken: ["github", "github_2"]) == "github_3")
        #expect(detector.uniqueVaultName(base: "My Token!", taken: []) == "my_token")
        #expect(MockSecretDetector.sanitizeName("__Aliyun--OSS__") == "aliyun--oss")
        #expect(MockSecretDetector.sanitizeName("中文名") == "secret")
        #expect(MockSecretDetector.sanitizeName(String(repeating: "a", count: 80)).count == 64)
    }
}

@Suite("MockClient：模型 key、用量、IM 渠道")
struct MockSettingsTests {
    @Test("模型 key：添加、删除；厂商")
    func credentials() async throws {
        let client = makeClient()
        #expect(try await client.vendors().map(\.id).contains("deepseek"))
        let added = try await client.addCredential(
            NewCredential(vendor: "openai", label: "", apiKey: "  sk-test-12345678  "))
        #expect(added.last4 == "5678")
        #expect(added.label == "OpenAI")
        #expect(try await client.credentials().count == 4)
        #expect(
            await apiCode {
                _ = try await client.addCredential(NewCredential(vendor: "openai", label: "x", apiKey: "short"))
            } == .invalid)
        #expect(
            await apiCode {
                _ = try await client.addCredential(NewCredential(vendor: "acme", label: "x", apiKey: "12345678"))
            } == .invalid)
        let custom = try await client.addCredential(
            NewCredential(
                vendor: NewCredential.customVendor, label: "自建", apiKey: "abcdefgh",
                openaiBase: "https://llm.example.com/v1"))
        #expect(custom.vendor == "custom")
        try await client.deleteCredential(added.id)
        #expect(await apiCode { try await client.deleteCredential(added.id) } == .notFound)
    }

    @Test("用量：按天、按实例、按模型、按 key；总数一致")
    func usage() async throws {
        let client = makeClient()
        let byDay = try await client.usage(group: .day)
        #expect(byDay.buckets.count == 7)
        #expect(byDay.total.chargedTokens == byDay.buckets.map(\.chargedTokens).reduce(0, +))
        let byInstance = try await client.usage(group: .instance)
        #expect(byInstance.buckets.map(\.key) == [writer.rawValue, reviewer.rawValue])
        let byModel = try await client.usage(group: .model)
        #expect(byModel.buckets.count == 2)
        let byKey = try await client.usage(group: .credential)
        #expect(byKey.buckets.count == 2, "停用的 key 不算")
        #expect(byKey.total == byDay.total)
    }

    @Test("IM 渠道：绑定、修改、换地址、测试、删除")
    func imChannels() async throws {
        let client = makeClient()
        #expect(try await client.imChannels().count == 1)
        let channel = try await client.addImChannel(
            NewImChannel(webhookURL: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abcd1234", label: "运维群"))
        #expect(channel.vendor == .wecom)
        #expect(channel.hint == "1234")
        #expect(!channel.hasSecret)
        #expect(channel.events == ImEvent.knownCases)
        #expect(
            await apiCode { _ = try await client.addImChannel(NewImChannel(webhookURL: "http://x.com", label: "x")) }
                == .invalid)
        #expect(
            await apiCode {
                _ = try await client.addImChannel(NewImChannel(webhookURL: "https://example.com/hook", label: "x"))
            } == .invalid)

        let updated = try await client.updateImChannel(channel.id, label: "运维", events: [.runFailed], enabled: false)
        #expect(updated.label == "运维")
        #expect(updated.events == [.runFailed])
        #expect(!updated.isEnabled)
        #expect(
            await apiCode { _ = try await client.updateImChannel(channel.id, label: nil, events: [], enabled: nil) }
                == .invalid)
        #expect(await apiCode { try await client.testImChannel(channel.id) } == .conflict)
        _ = try await client.updateImChannel(channel.id, label: nil, events: nil, enabled: true)
        try await client.testImChannel(channel.id)
        #expect(try await client.imChannels().last?.lastSentAt != nil)

        let moved = try await client.replaceImWebhook(
            channel.id, webhookURL: "https://oapi.dingtalk.com/robot/send?access_token=zz99", secret: "SEC")
        #expect(moved.vendor == .dingtalk)
        #expect(moved.hasSecret)
        try await client.deleteImChannel(channel.id)
        #expect(try await client.imChannels().count == 1)
    }
}

@Suite("客户端的辅助类型")
struct ClientSupportTests {
    @Test("订阅句柄：stop 可以重复调用，释放时自动停止")
    func subscriptionHandle() {
        let count = Locked(0)
        let handle = EventSubscriptionHandle { count.withLock { $0 += 1 } }
        #expect(!handle.isStopped)
        handle.stop()
        handle.stop()
        #expect(handle.isStopped)
        #expect(count.value == 1)

        let released = Locked(false)
        do {
            let temporary = EventSubscriptionHandle { released.withLock { $0 = true } }
            _ = temporary
        }
        #expect(released.value)
    }

    @Test("内存里的会话存储")
    func sessionStore() {
        let store = InMemorySessionStore()
        #expect(store.load() == nil)
        store.save(DemoData.demoSession)
        #expect(store.load() == DemoData.demoSession)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test("便捷方法：login(phone:code:)、cancelRun(_:)、usage(group:)")
    func protocolDefaults() async throws {
        let client = makeClient(signedIn: false, autoReply: false)
        _ = try await client.login(phone: "+8613800138000", code: "123456")
        let run = try await client.sendMessage(instanceID: writer, text: "hi")
        #expect(try await client.cancelRun(run.id).state == .cancelled)
        #expect(try await client.usage(group: .day).buckets.count == 7)
    }
}
