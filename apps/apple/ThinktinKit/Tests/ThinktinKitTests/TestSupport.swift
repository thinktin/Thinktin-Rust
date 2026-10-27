import Foundation
import Testing

@testable import ThinktinKit

// 测试共用的小工具：固定的时间、日历，拼事件。

enum Fixture {
    /// 北京时间，测试里所有和日历有关的计算都用它（不受运行机器的时区影响）。
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = shanghai
        return c
    }

    /// 北京时间的某个时刻。
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// 2026-10-22 10:00（北京时间）：相对时间测试的“现在”。
    static let now = date(2026, 10, 22, 10, 0)

    static let instanceID: InstanceID = "inst-1"
    static let runA: RunID = "run-a"
    static let runB: RunID = "run-b"

    static func run(
        _ id: RunID, prompt: String = "任务", state: RunState = .running, createdAt: Date = Fixture.now,
        source: RunSource = .user, planID: PlanID? = nil, stepKey: String? = nil
    ) -> Run {
        Run(
            id: id, instanceID: instanceID, planID: planID, stepKey: stepKey, source: source, prompt: prompt,
            state: state, createdAt: createdAt)
    }
}

/// 拼一串事件：seq 从 1 开始递增，时间每条加 1 秒。
struct Events {
    var instanceID: InstanceID = Fixture.instanceID
    var start: Date = Fixture.now
    private(set) var list: [InstanceEvent] = []
    private var nextSeq: UInt64 = 1

    init(instanceID: InstanceID = Fixture.instanceID, start: Date = Fixture.now, firstSeq: UInt64 = 1) {
        self.instanceID = instanceID
        self.start = start
        self.nextSeq = firstSeq
    }

    /// 加一条事件，返回它（测试里可以单独喂）。
    @discardableResult
    mutating func add(
        _ kind: InstanceEventKind, _ runID: RunID?, _ payload: JSONValue = [:], aiGenerated: Bool? = nil
    ) -> InstanceEvent {
        let e = InstanceEvent(
            instanceID: instanceID, seq: nextSeq, runID: runID, kind: kind, payloadJSON: payload.compactString(),
            isAIGenerated: aiGenerated, createdAt: start.addingTimeInterval(TimeInterval(nextSeq)))
        nextSeq += 1
        list.append(e)
        return e
    }

    /// 种类是原始字符串的事件（不认识的 kind）。
    @discardableResult
    mutating func add(raw kind: String, _ runID: RunID?, _ payload: JSONValue = [:]) -> InstanceEvent {
        add(InstanceEventKind(rawValue: kind), runID, payload)
    }
}

/// 解出内容的小工具，失败时返回 nil（`#require` 用）。
extension ConversationItem.Content {
    var assistantText: AssistantText? {
        if case .assistantText(let v) = self { return v }
        return nil
    }
    var thought: Thought? {
        if case .thought(let v) = self { return v }
        return nil
    }
    var toolCall: ToolCallCard? {
        if case .toolCall(let v) = self { return v }
        return nil
    }
    var agentPlan: AgentPlanCard? {
        if case .agentPlan(let v) = self { return v }
        return nil
    }
    var approval: ApprovalCard? {
        if case .approval(let v) = self { return v }
        return nil
    }
    var vaultRequest: VaultRequestCard? {
        if case .vaultRequest(let v) = self { return v }
        return nil
    }
    var runStatus: RunStatusLine? {
        if case .runStatus(let v) = self { return v }
        return nil
    }
    var artifact: ArtifactCard? {
        if case .artifact(let v) = self { return v }
        return nil
    }
    var childRun: ChildRunCard? {
        if case .childRun(let v) = self { return v }
        return nil
    }
    var planActivity: PlanActivityCard? {
        if case .planActivity(let v) = self { return v }
        return nil
    }
    var systemNotice: SystemNotice? {
        if case .systemNotice(let v) = self { return v }
        return nil
    }
    var userMessage: UserMessage? {
        if case .userMessage(let v) = self { return v }
        return nil
    }

    /// 种类名，断言列表结构时用。
    var tag: String {
        switch self {
        case .userMessage: "user"
        case .assistantText: "text"
        case .thought: "thought"
        case .toolCall: "tool"
        case .agentPlan: "plan"
        case .approval: "approval"
        case .vaultRequest: "vault"
        case .runStatus: "status"
        case .artifact: "artifact"
        case .childRun: "child"
        case .planActivity: "planActivity"
        case .systemNotice: "notice"
        }
    }
}

extension Array where Element == ConversationItem {
    /// 每项的种类名，按顺序。
    var tags: [String] { map(\.content.tag) }
}

/// 把 `Encodable` 编成 JSON 文本（键排序）。
func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// 从 JSON 文本解码。
func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
