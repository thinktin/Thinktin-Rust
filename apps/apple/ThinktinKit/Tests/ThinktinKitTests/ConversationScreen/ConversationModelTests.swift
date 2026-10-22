import Foundation
import Testing

@testable import ThinktinKit

private let writer = ConversationFixture.writer

@MainActor
@Suite("对话页：加载、事件流、往前翻")
struct ConversationModelTests {
    @Test("打开页面：先显示缓存，再拉运行、订阅事件流；审批卡片查过记录，计划标题拉到了")
    func opens() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        #expect(model.hasLoaded)
        #expect(model.turns.map(\.runID) == [DemoData.weeklyRunID, DemoData.digestRunID, DemoData.postRunID])
        #expect(model.isSubscribed)
        #expect(await eventually { model.streamStatus == .live })
        #expect(model.approvalRecords[DemoData.pendingApprovalID]?.isPending == true)
        #expect(model.plans[DemoData.digestPlanID]?.title == "每日 GitHub 通知汇总")
        #expect(!model.canLoadOlder)
        #expect(model.loadError == nil && !model.isMissing)
        // 回复解析成了块（周报那段有标题和列表）。
        let reply = try #require(model.turn(for: DemoData.weeklyRunID)?.items.first { $0.content.assistantText != nil })
        let blocks = model.markdownBlocks(for: reply).map(\.block)
        #expect(blocks.contains { if case .list = $0 { true } else { false } })
        // 等审批的那一组能滚到审批卡片。
        let approvalItem = try #require(model.pendingApprovalItemID(in: DemoData.postRunID))
        #expect(model.items.first { $0.id == approvalItem }?.content.approval?.approvalID == DemoData.pendingApprovalID)
    }

    @Test("输入框上的默认模型：main 路由的上游模型；没配 main 时提示；去路由页改了，回来再查")
    func mainRoute() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        #expect(model.mainRoute == .unknown)
        await model.start()
        #expect(model.mainRoute == .configured(model: "claude-sonnet-5-5"))
        mock.update { $0.routes[writer] = [] }
        await model.start()
        #expect(model.mainRoute == .missing)
        // 拉不到（离线）时保持原样。
        mock.failNext(with: .network(message: "offline"))
        await model.start()
        #expect(model.mainRoute == .missing)
        // 只看本次过程不查。
        let focus = ConversationModel(client: mock, instanceID: writer, focusRunID: DemoData.weeklyRunID)
        await focus.start()
        #expect(focus.mainRoute == .unknown)
        #expect(ConversationText.modelLabel(.missing, language: .english) == "No model set up")
        #expect(ConversationText.modelLabel(.unknown, language: .chinese) == nil)
    }

    @Test("离线：运行拉不到也照样显示已有的，错误记在 loadError 里，联网后再拉就好了")
    func offline() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.load()
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.turns.count == 3)
        #expect(model.loadError?.isOffline == true)
        await model.load()
        #expect(model.loadError == nil)
    }

    @Test("事件流来的事件：按批归并；没见过的运行拉记录；运行结束拉一次最新记录")
    func streamEvents() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        mock.emit(.agentMessage, payload: ["text": "补充一句"], runID: DemoData.postRunID, instanceID: writer)
        #expect(await eventually { ConversationFixture.replyText(model, DemoData.postRunID).contains("补充一句") })
        // 别的设备发的运行：事件先到，运行记录随后拉到（用户消息补上）。
        let other = Run(
            id: "run-other", instanceID: writer, prompt: "别处发的", state: .running, createdAt: Date())
        mock.update { $0.runs.append(other) }
        mock.emit(.agentMessage, payload: ["text": "你好"], runID: other.id, instanceID: writer)
        #expect(await eventually { model.turn(for: other.id)?.run?.prompt == "别处发的" })
        #expect(model.turn(for: other.id)?.items.first?.content.userMessage?.text == "别处发的")
        // 运行结束：状态马上跟着变，再拉一次记录（摘要）。
        mock.emit(.runState, payload: ["state": "succeeded"], runID: other.id, instanceID: writer)
        #expect(await eventually { model.runs[other.id]?.summary == "你好" })
        #expect(model.turn(for: other.id)?.state == .succeeded)
    }

    @Test("实例状态事件（instance.state）不进时间线，记在 instanceState 里")
    func instanceState() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        let count = model.items.count
        mock.emit(
            InstanceEventKind(rawValue: "instance.state"), payload: ["state": "archived"], runID: nil,
            instanceID: writer)
        #expect(await eventually { model.instanceState == .archived })
        #expect(model.items.count == count)
    }

    @Test("事件流重置：清空后从缓存重新读，运行保留，重新拉运行")
    func reset() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        let before = model.items.map(\.id)
        mock.play(MockEventScript(steps: [.reset(oldestSeq: 1, latestSeq: nil)]), instanceID: writer)
        #expect(await eventually { model.resetCount == 1 })
        #expect(model.items.map(\.id) == before)
        // 重置之后的新事件照常进来。
        mock.emit(.agentMessage, payload: ["text": "重置之后"], runID: DemoData.postRunID, instanceID: writer)
        #expect(await eventually { ConversationFixture.replyText(model, DemoData.postRunID).contains("重置之后") })
    }

    @Test("按批提交：一批事件只归并、刷新一次，顺序和回调一致")
    func batches() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.load()
        var events: [EventStreamElement] = []
        let start = mock.state.lastSeq(of: writer)
        for i in 1...50 {
            events.append(
                .event(
                    InstanceEvent(
                        instanceID: writer, seq: start + UInt64(i), runID: DemoData.postRunID, kind: .agentMessage,
                        payloadJSON: #"{"text":"\#(i),"}"#, createdAt: Date())))
        }
        model.receive(events)
        let text = ConversationFixture.replyText(model, DemoData.postRunID)
        #expect(text.hasSuffix((1...50).map { "\($0)," }.joined()))
        // 重复的（seq 不大于已处理的）丢掉。
        model.receive(Array(events.prefix(5)))
        #expect(ConversationFixture.replyText(model, DemoData.postRunID) == text)
    }

    @Test("进后台停订阅；期间到的事件回前台时从缓存补上，再续订")
    func pauseAndResume() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        model.pause()
        #expect(!model.isSubscribed)
        mock.emit(.agentMessage, payload: ["text": "后台时到的"], runID: DemoData.postRunID, instanceID: writer)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!ConversationFixture.replyText(model, DemoData.postRunID).contains("后台时到的"))
        await model.resume()
        #expect(ConversationFixture.replyText(model, DemoData.postRunID).contains("后台时到的"))
        #expect(model.isSubscribed)
        // 账号解冻后重新订阅。
        model.resubscribe()
        #expect(model.isSubscribed)
        mock.emit(.agentMessage, payload: ["text": "解冻之后"], runID: DemoData.postRunID, instanceID: writer)
        #expect(await eventually { ConversationFixture.replyText(model, DemoData.postRunID).contains("解冻之后") })
    }

    @Test("往前翻：先翻缓存里更早的事件，再往前翻运行；还没翻到的早期运行先不显示")
    func loadOlder() async {
        let mock = ConversationFixture.manyRuns(count: 40, eventsPerRun: 10)
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        // 最后 200 条事件是后 20 个运行的。
        #expect(model.turns.count == 20)
        #expect(model.turns.first?.runID == "run-020")
        #expect(model.canLoadOlder)
        await model.loadOlder()
        #expect(model.turns.count == 40)
        #expect(model.turns.first?.run?.prompt == "任务 0", "更早的运行记录也翻到了")
        #expect(model.turns.allSatisfy { model.historyNote(for: $0) == nil })
        await model.loadOlder()
        #expect(!model.hasOlderEvents)
        #expect(!model.canLoadOlder)
        #expect(model.turns.count == 40)
    }

    @Test("往前翻到的旧事件里的实例状态是旧的：不拿来当页头")
    func olderInstanceState() async {
        let mock = ConversationFixture.manyRuns(count: 40, eventsPerRun: 10)
        mock.update { s in
            guard var list = s.events[writer], let i = list.firstIndex(where: { $0.seq == 3 }) else { return }
            list[i] = InstanceEvent(
                instanceID: writer, seq: 3, runID: nil, kind: InstanceEventKind(rawValue: "instance.state"),
                payloadJSON: #"{"state":"archived"}"#, createdAt: list[i].createdAt)
            s.events[writer] = list
        }
        let model = ConversationModel(client: mock, instanceID: writer)
        await model.start()
        #expect(model.instanceState == nil)
        await model.loadOlder()
        #expect(model.turns.count == 40)
        #expect(model.instanceState == nil, "一个月前归档过，不代表现在是归档的")
    }

    @Test("回前台时重新拉保险箱请求：在后台时过期了的（过期没有事件）卡片显示已过期")
    func resumeRefreshesVaultRequests() async throws {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: ConversationFixture.reviewer)
        await model.start()
        let card = try #require(model.items.compactMap(\.content.vaultRequest).first)
        #expect(model.vaultStatus(for: card) == .pending)
        model.pause()
        mock.update { s in
            if let i = s.vaultRequests.firstIndex(where: { $0.id == card.requestID }) {
                s.vaultRequests[i].status = .expired
            }
        }
        await model.resume()
        #expect(model.vaultStatus(for: card) == .expired)
    }

    @Test("没有过程记录的运行：超过保留期的、本机没缓存的各有说明")
    func historyNotes() async {
        let now = Date()
        var state = DemoData.state(now: now)
        state.runs += [
            Run(
                id: "run-old", instanceID: writer, prompt: "很久以前", state: .succeeded, summary: "做完了",
                createdAt: now.addingTimeInterval(-40 * 86400)),
            Run(
                id: "run-recent", instanceID: writer, prompt: "前天", state: .failed,
                createdAt: now.addingTimeInterval(-2 * 86400)),
        ]
        let model = ConversationModel(client: ConversationFixture.mock(state: state), instanceID: writer, now: { now })
        await model.start()
        let old = model.turn(for: "run-old")
        let recent = model.turn(for: "run-recent")
        #expect(old.flatMap(model.historyNote(for:)) == .expired)
        #expect(recent.flatMap(model.historyNote(for:)) == .notCached)
        #expect(model.turn(for: DemoData.weeklyRunID).flatMap(model.historyNote(for:)) == nil)
        #expect(model.turns.first?.runID == "run-old", "按创建时间排")
        // 只剩任务和结果的运行显示结果（摘要）；有过程记录的、没有摘要的不显示。
        #expect(old.flatMap(model.historySummary(for:)) == "做完了")
        #expect(recent.flatMap(model.historySummary(for:)) == nil)
        #expect(model.turn(for: DemoData.weeklyRunID).flatMap(model.historySummary(for:)) == nil)
    }

    @Test("只看本次过程：只有这个运行的事件，不能发消息")
    func focus() async {
        let mock = ConversationFixture.mock()
        let model = ConversationModel(client: mock, instanceID: writer, focusRunID: DemoData.postRunID)
        await model.start()
        #expect(model.turns.map(\.runID) == [DemoData.postRunID])
        model.draft = "试试"
        #expect(!model.canSend)
        #expect(!model.canLoadOlder)
        mock.emit(.agentMessage, payload: ["text": "别的运行"], runID: DemoData.weeklyRunID, instanceID: writer)
        mock.emit(.agentMessage, payload: ["text": "这个运行"], runID: DemoData.postRunID, instanceID: writer)
        #expect(await eventually { ConversationFixture.replyText(model, DemoData.postRunID).contains("这个运行") })
        #expect(model.turns.count == 1)
    }

    @Test("实例不存在：标成找不到，不订阅")
    func missing() async {
        let model = ConversationModel(client: ConversationFixture.mock(), instanceID: "gone")
        await model.start()
        #expect(model.isMissing)
        #expect(!model.isSubscribed)
        #expect(model.turns.isEmpty)
    }
}
