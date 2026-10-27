import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("运行树：停止、等你处理的子步骤、定时刷新")
struct RunTreeStopTests {
    private let writer = DemoData.writerID
    private let reviewer = DemoData.reviewerID

    /// 一条流水线：根运行在跑，collect 做完了，review 在等审批，notes 在跑。
    private func pipelineMock() -> MockClient {
        let t0 = Date().addingTimeInterval(-600)
        var state = DemoData.state()
        state.runs += [
            Run(
                id: "root", kind: .pipeline, instanceID: writer, source: .plan, prompt: "发版流水线", state: .running,
                createdAt: t0),
            Run(
                id: "collect", instanceID: writer, parentRunID: "root", rootRunID: "root", stepKey: "collect",
                source: .pipeline, prompt: "收集", state: .succeeded, createdAt: t0.addingTimeInterval(1)),
            Run(
                id: "review", instanceID: reviewer, parentRunID: "root", rootRunID: "root", stepKey: "review",
                source: .pipeline, prompt: "审查", state: .waitingApproval, createdAt: t0.addingTimeInterval(2)),
            Run(
                id: "notes", instanceID: writer, parentRunID: "root", rootRunID: "root", stepKey: "notes",
                source: .pipeline, prompt: "写说明", state: .running, createdAt: t0.addingTimeInterval(3)),
        ]
        return MockClient(state: state, stepDelay: 0, autoReply: false)
    }

    @Test("等你处理的子步骤冒到顶上；根运行自己不算")
    func attention() async throws {
        let model = RunTreeModel(client: pipelineMock(), runID: "notes")
        await model.load()
        #expect(model.nodes.map(\.id) == ["root", "collect", "review", "notes"])
        #expect(model.hasActiveRuns)
        let run = try #require(model.attention)
        #expect(run.id == "review")
        #expect(TeamsText.attention(run, language: .chinese) == "review 在等你审批")
        #expect(TeamsText.attention(run, language: .english) == "review is waiting for your approval")
    }

    @Test("停一个节点：只停它，刷新后看到新状态")
    func stopOne() async throws {
        let mock = pipelineMock()
        let model = RunTreeModel(client: mock, runID: "root")
        await model.load()
        await model.stop("notes")
        #expect(model.stopError == nil)
        #expect(model.stopping.isEmpty)
        #expect(model.nodes.first { $0.id == "notes" }?.run.state == .cancelled)
        #expect(model.nodes.first { $0.id == "review" }?.run.state == .waitingApproval)
        #expect(model.hasActiveRuns)
    }

    @Test("停止整棵树：没结束的都停下，定时刷新跟着结束")
    func stopTree() async throws {
        let mock = pipelineMock()
        let model = RunTreeModel(client: mock, runID: "review")
        await model.load()
        await model.stopTree()
        #expect(model.stopError == nil)
        #expect(!model.hasActiveRuns)
        #expect(model.attention == nil)
        #expect(model.nodes.first { $0.id == "collect" }?.run.state == .succeeded)
        // 都结束了：定时刷新马上返回。
        await model.refreshWhileActive(every: .milliseconds(1))
    }

    @Test("停已经结束的（冲突）不提示错误；别的错误留着，可以清掉")
    func stopErrors() async throws {
        let mock = pipelineMock()
        let model = RunTreeModel(client: mock, runID: "root")
        await model.load()
        await model.stop("collect")
        #expect(model.stopError == nil)

        mock.failNext(
            "cancelRun(_:wholeTree:)", with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        await model.stop("notes")
        #expect(model.stopError != nil)
        model.clearStopError()
        #expect(model.stopError == nil)
    }

    @Test("定时刷新：有没结束的就一直刷新，都结束了就停")
    func refresh() async throws {
        let mock = pipelineMock()
        let model = RunTreeModel(client: mock, runID: "root")
        await model.load()
        let task = Task { await model.refreshWhileActive(every: .milliseconds(5)) }
        mock.update { state in
            for i in state.runs.indices where state.runs[i].rootRunID == "root" && state.runs[i].state.isActive {
                state.runs[i].state = .succeeded
            }
        }
        await task.value
        #expect(!model.hasActiveRuns)
        #expect(mock.callCount("runTree(_:)") >= 2)
    }
}
