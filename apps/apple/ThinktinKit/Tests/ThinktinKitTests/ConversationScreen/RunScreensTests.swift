import Foundation
import Testing

@testable import ThinktinKit

private let writer = ConversationFixture.writer
private let reviewer = ConversationFixture.reviewer

@MainActor
@Suite("运行详情、运行树、进行中")
struct RunScreensTests {
    @Test("运行详情：状态、来源、产出物、只看本次过程；没有子运行时没有运行树入口")
    func detail() async throws {
        let mock = ConversationFixture.mock()
        let model = RunDetailModel(client: mock, runID: DemoData.weeklyRunID)
        await model.load()
        let run = try #require(model.run)
        #expect(run.prompt.hasPrefix("帮我把这周的周报"))
        #expect(model.state == .succeeded)
        #expect(!model.canStop)
        #expect(model.artifacts?.map(\.id) == [DemoData.weeklyArtifactID])
        #expect(model.tree?.count == 1 && !model.hasTree)
        #expect(!model.promptIsAIGenerated)
        let process = try #require(model.process)
        #expect(process.focusRunID == DemoData.weeklyRunID)
        #expect(process.turns.map(\.runID) == [DemoData.weeklyRunID])
        let usage = try #require(model.lastUsage)
        #expect(usage.input == 15_200 && usage.output == 3_220)
        #expect(model.statusLine?.state == .succeeded)
        #expect(abs((model.duration ?? 0) - 90) < 0.01)
    }

    @Test("等审批的运行：待处理的审批卡片直接放在运行详情里，在这里就能批")
    func pendingApprovalsInDetail() async throws {
        let mock = ConversationFixture.mock()
        let model = RunDetailModel(client: mock, runID: DemoData.postRunID)
        await model.load()
        #expect(model.statusLine?.state == .waitingApproval)
        #expect(model.pendingApprovalItems.count == 1)
        let item = try #require(model.pendingApprovalItems.first)
        let card = try #require(item.content.approval)
        #expect(card.approvalID == DemoData.pendingApprovalID)
        let allow = try #require(card.options.first { $0.kind.isAllow })
        let process = try #require(model.process)
        await process.decide(item, option: allow, reason: "批准")
        #expect(await eventually { model.pendingApprovalItems.isEmpty })
        // 已经完成的运行没有待处理的卡片。
        let done = RunDetailModel(client: mock, runID: DemoData.weeklyRunID)
        await done.load()
        #expect(done.pendingApprovalItems.isEmpty)
    }

    @Test("计划触发的运行：拉到所属计划；计划删掉了不算出错")
    func planLink() async throws {
        let mock = ConversationFixture.mock()
        let model = RunDetailModel(client: mock, runID: DemoData.digestRunID)
        await model.load()
        #expect(model.plan?.id == DemoData.digestPlanID)
        #expect(model.run?.source == .plan)
        mock.update { $0.plans = [] }
        let again = RunDetailModel(client: mock, runID: DemoData.digestRunID)
        await again.load()
        #expect(again.plan == nil)
        #expect(again.detailsError == nil)
    }

    @Test("停止：没结束的可以停；停止整棵树")
    func stop() async throws {
        let mock = ConversationFixture.mock()
        let model = RunDetailModel(client: mock, runID: DemoData.postRunID)
        await model.load()
        #expect(model.canStop)
        #expect(!model.canStopTree)
        await model.stop(wholeTree: false)
        #expect(model.stopError == nil)
        #expect(await eventually { model.state == .cancelled })
        #expect(!model.canStop)
    }

    @Test("委派的子运行：树里有两个，任务带 AI 生成标识，可以停止整棵树")
    func delegatedTree() async throws {
        var state = DemoData.state()
        let child = Run(
            id: "run-child", instanceID: writer, parentRunID: DemoData.publishRunID, rootRunID: DemoData.publishRunID,
            source: .delegate, prompt: "写发布说明", state: .running, createdAt: Date())
        state.runs.append(child)
        let mock = ConversationFixture.mock(state: state)
        let model = RunDetailModel(client: mock, runID: "run-child")
        await model.load()
        #expect(model.hasTree)
        #expect(model.canStopTree)
        #expect(model.promptIsAIGenerated)
        await model.stop(wholeTree: true)
        #expect(mock.state.runs.filter { $0.rootRunID == DemoData.publishRunID }.allSatisfy { $0.state == .cancelled })

        let tree = RunTreeModel(client: mock, runID: "run-child")
        await tree.load()
        #expect(tree.nodes.map(\.id) == [DemoData.publishRunID, "run-child"])
        #expect(tree.nodes.map(\.depth) == [0, 1])
        #expect(tree.nodes.map(\.isFocus) == [false, true])
        #expect(tree.nodes[0].childCount == 1)
        #expect(tree.nodes[1].titleIsAIGenerated)
        #expect(!tree.nodes[0].titleIsAIGenerated)
        #expect(tree.root?.id == DemoData.publishRunID)
    }

    @Test("运行树：深度优先、同一层按创建时间；父运行不在结果里的当成根；步骤名做标题")
    func treeBuild() {
        let t0 = Fixture.now
        let root = Run(id: "r", kind: .pipeline, instanceID: writer, prompt: "发版", createdAt: t0)
        let b = Run(
            id: "b", instanceID: writer, parentRunID: "r", rootRunID: "r", stepKey: "review", source: .pipeline,
            prompt: "审查", createdAt: t0.addingTimeInterval(20))
        let a = Run(
            id: "a", instanceID: writer, parentRunID: "r", rootRunID: "r", stepKey: "collect", source: .pipeline,
            prompt: "收集", createdAt: t0.addingTimeInterval(10))
        let a1 = Run(
            id: "a1", instanceID: reviewer, parentRunID: "a", rootRunID: "r", source: .delegate, prompt: "细节\n第二行",
            createdAt: t0.addingTimeInterval(15))
        let orphan = Run(
            id: "o", instanceID: writer, parentRunID: "missing", rootRunID: "r", prompt: "孤儿",
            createdAt: t0.addingTimeInterval(30))
        let nodes = RunTreeModel.build([b, a1, orphan, root, a], focus: "a1")
        #expect(nodes.map(\.id) == ["r", "a", "a1", "b", "o"])
        #expect(nodes.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(nodes.map(\.title) == ["发版", "collect", "细节", "review", "孤儿"])
        #expect(nodes.first { $0.isFocus }?.id == "a1")
    }

    @Test("运行详情：找不到的运行；离线时先显示缓存里的")
    func missingAndOffline() async {
        let mock = ConversationFixture.mock()
        let missing = RunDetailModel(client: mock, runID: "nope")
        await missing.load()
        #expect(missing.isMissing)
        #expect(missing.process == nil)

        // 离线：先显示带进来的记录，记下网络错误。
        let known = mock.state.runs.first { $0.id == DemoData.postRunID }
        let offline = RunDetailModel(client: mock, runID: DemoData.postRunID, run: known)
        mock.failNext(with: .network(message: "offline"))
        await offline.load()
        #expect(offline.run?.id == DemoData.postRunID)
        #expect(offline.error?.isOffline == true)
        // 缓存里找（只知道运行 id）。
        let cached = RunDetailModel(client: mock, runID: DemoData.reviewRunID, instanceHints: [writer])
        await cached.load()
        #expect(cached.run?.state == .failed)
    }

    @Test("进行中：跨实例、没结束的，等你处理的排在前面")
    func activeRuns() async {
        let mock = ConversationFixture.mock()
        let model = ActiveRunsModel(client: mock)
        await model.load()
        #expect(model.runs.map(\.id) == [DemoData.postRunID, DemoData.publishRunID])
        #expect(model.waiting.map(\.id) == [DemoData.postRunID])
        #expect(model.others.map(\.id) == [DemoData.publishRunID])
        #expect(!model.hasMore)
    }

    @Test("进行中：往下翻（一页 50 个）")
    func activeRunsPaging() async {
        var state = DemoData.state()
        let now = Date()
        for i in 0..<60 {
            state.runs.append(
                Run(
                    id: RunID("q-\(String(format: "%02d", i))"), instanceID: reviewer, prompt: "排队 \(i)",
                    state: .queued, createdAt: now.addingTimeInterval(Double(-i))))
        }
        let model = ActiveRunsModel(client: ConversationFixture.mock(state: state))
        await model.load()
        #expect(model.runs.count == 50)
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.runs.count == 62)
        #expect(!model.hasMore)
        #expect(Set(model.runs.map(\.id)).count == 62)
    }
}
