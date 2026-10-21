import Foundation

/// 一次运行：agent 在实例上执行一轮任务，或流水线的根。
public struct Run: Identifiable, Hashable, Codable, Sendable {
    public var id: RunID
    public var kind: RunKind
    public var instanceID: InstanceID
    public var planID: PlanID?
    public var parentRunID: RunID?
    public var rootRunID: RunID
    /// 流水线里的步骤名。
    public var stepKey: String?
    public var source: RunSource
    /// 这次运行的任务（对话页面上显示成用户消息）。
    public var prompt: String
    public var state: RunState
    public var stateReason: String?
    /// 第几次尝试（从 1 开始；崩溃重试后加一）。
    public var attempt: Int
    public var tokensUsed: Int
    /// agent 最后的回答摘要。
    public var summary: String?
    public var error: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: RunID, kind: RunKind = .agent, instanceID: InstanceID, planID: PlanID? = nil,
        parentRunID: RunID? = nil, rootRunID: RunID? = nil, stepKey: String? = nil, source: RunSource = .user,
        prompt: String, state: RunState = .queued, stateReason: String? = nil, attempt: Int = 1,
        tokensUsed: Int = 0, summary: String? = nil, error: String? = nil, createdAt: Date,
        startedAt: Date? = nil, finishedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.instanceID = instanceID
        self.planID = planID
        self.parentRunID = parentRunID
        self.rootRunID = rootRunID ?? id
        self.stepKey = stepKey
        self.source = source
        self.prompt = prompt
        self.state = state
        self.stateReason = stateReason
        self.attempt = attempt
        self.tokensUsed = tokensUsed
        self.summary = summary
        self.error = error
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// 运行树的根（没有父运行）。
    public var isRoot: Bool { parentRunID == nil }

    /// 开始到结束（还没结束就到 `now`）的时长；还没开始返回 nil。
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let start = startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(start)
    }
}

/// agent 发布的产出物。
public struct Artifact: Identifiable, Hashable, Codable, Sendable {
    public var id: ArtifactID
    public var instanceID: InstanceID
    public var runID: RunID
    public var name: String
    public var version: Int
    public var contentType: String
    /// 字节数。
    public var size: Int
    public var sha256: String
    public var createdAt: Date

    public init(
        id: ArtifactID, instanceID: InstanceID, runID: RunID, name: String, version: Int = 1,
        contentType: String, size: Int, sha256: String = "", createdAt: Date
    ) {
        self.id = id
        self.instanceID = instanceID
        self.runID = runID
        self.name = name
        self.version = version
        self.contentType = contentType
        self.size = size
        self.sha256 = sha256
        self.createdAt = createdAt
    }

    /// 文本类内容（可以直接预览）。
    public var isText: Bool {
        contentType.hasPrefix("text/") || contentType.contains("json") || contentType.contains("xml")
            || contentType.contains("markdown")
    }

    public var isImage: Bool { contentType.hasPrefix("image/") }
}
