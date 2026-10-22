import Foundation
import Testing

@testable import ThinktinKit

// 对话页（12.5）测试用的演示客户端。

enum ConversationFixture {
    static let writer = DemoData.writerID
    static let reviewer = DemoData.reviewerID

    /// 演示数据：不等待；`autoReply` 时发消息后马上播完 agent 的回答。
    static func mock(autoReply: Bool = false, state: MockState = DemoData.state()) -> MockClient {
        MockClient(state: state, stepDelay: 0, autoReply: autoReply)
    }

    /// 写作助手换成 `count` 个已完成的运行，每个 `eventsPerRun` 条事件（最后一条是 `run.state` 成功），每 10 分钟一个，
    /// 最后一个是 `now` 前 10 分钟。
    static func manyRuns(count: Int, eventsPerRun: Int, now: Date = Date()) -> MockClient {
        var state = DemoData.state(now: now)
        let base = now.addingTimeInterval(-Double(count) * 600)
        var runs: [Run] = []
        var events: [InstanceEvent] = []
        var seq: UInt64 = 0
        for i in 0..<count {
            let id = RunID("run-\(String(format: "%03d", i))")
            let created = base.addingTimeInterval(Double(i) * 600)
            runs.append(
                Run(
                    id: id, instanceID: writer, prompt: "任务 \(i)", state: .succeeded, createdAt: created,
                    startedAt: created, finishedAt: created.addingTimeInterval(60)))
            for j in 0..<eventsPerRun {
                seq += 1
                let last = j == eventsPerRun - 1
                let payload: JSONValue = last ? ["state": "succeeded"] : ["text": .string("第 \(i)-\(j) 段")]
                events.append(
                    InstanceEvent(
                        instanceID: writer, seq: seq, runID: id, kind: last ? .runState : .agentMessage,
                        payloadJSON: payload.compactString(), createdAt: created.addingTimeInterval(Double(j))))
            }
        }
        state.runs = state.runs.filter { $0.instanceID != writer } + runs
        state.events[writer] = events
        state.approvals = []
        state.inbox = []
        return MockClient(state: state, stepDelay: 0, autoReply: false)
    }

    /// 某个运行那一组里 agent 的回复文字（拼起来）。
    @MainActor
    static func replyText(_ model: ConversationModel, _ runID: RunID) -> String {
        (model.turn(for: runID)?.items ?? []).compactMap(\.content.assistantText?.text).joined(separator: "\n")
    }
}
