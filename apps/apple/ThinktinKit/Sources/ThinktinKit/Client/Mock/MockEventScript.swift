import Foundation

/// `MockClient` 回放的一组事件（预览、测试用）：订阅时或发消息后按顺序播出。
public struct MockEventScript: Sendable {
    public enum Step: Sendable {
        /// 发一条事件（`seq`、时间由 Mock 分配）。`runID` 为 nil 时用脚本的默认运行。
        case event(InstanceEventKind, payload: JSONValue, runID: RunID? = nil)
        /// 连接状态变化。
        case status(StreamStatus)
        /// 续传位置过期（`onReset`）。
        case reset(oldestSeq: UInt64, latestSeq: UInt64?)
        /// 停一会儿（秒）。
        case wait(TimeInterval)
    }

    public var steps: [Step]
    /// `event` 没给运行 id 时用它。
    public var runID: RunID?

    public init(runID: RunID? = nil, steps: [Step]) {
        self.runID = runID
        self.steps = steps
    }

    public static func + (lhs: MockEventScript, rhs: MockEventScript) -> MockEventScript {
        MockEventScript(runID: lhs.runID ?? rhs.runID, steps: lhs.steps + rhs.steps)
    }
}
