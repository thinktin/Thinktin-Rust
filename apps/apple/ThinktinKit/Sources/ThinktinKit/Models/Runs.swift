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
    /// 等的是什么（11.8）：只在 `waitingQuota`、`waitingDevice` 时有（见 `RunWaitCode.applies(to:)`），老的服务端没有。
    /// 界面按它决定“去换 key”还是“稍后自动继续”；为 nil 或不认识时按 `state` 显示。
    public var waitCode: RunWaitCode?

    public init(
        id: RunID, kind: RunKind = .agent, instanceID: InstanceID, planID: PlanID? = nil,
        parentRunID: RunID? = nil, rootRunID: RunID? = nil, stepKey: String? = nil, source: RunSource = .user,
        prompt: String, state: RunState = .queued, stateReason: String? = nil, attempt: Int = 1,
        tokensUsed: Int = 0, summary: String? = nil, error: String? = nil, createdAt: Date,
        startedAt: Date? = nil, finishedAt: Date? = nil, waitCode: RunWaitCode? = nil
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
        self.waitCode = waitCode
    }

    /// 运行树的根（没有父运行）。
    public var isRoot: Bool { parentRunID == nil }

    /// 开始到结束（还没结束就到 `now`）的时长；还没开始返回 nil。
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let start = startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(start)
    }
}

extension RunWaitCode {
    /// 这个状态下等待原因码才有意义（等 key、等电脑）；别的状态下服务端不给，给了也不显示。
    public static func applies(to state: RunState) -> Bool {
        state == .waitingQuota || state == .waitingDevice
    }
}

/// 跨实例列运行的条件（11.8，`listRuns(filter:before:limit:)`）。都不给（`RunFilter.all`）是全部运行。
public struct RunFilter: Hashable, Sendable {
    /// 只要这个计划的（包括流水线的步骤，它们在别的实例上跑；配合 `rootsOnly` 一次触发一行）。
    /// 别人的、不存在的、删掉了的计划：删掉的照样列得出来，别人的和不存在的是空列表。
    public var planID: PlanID?
    /// 只要没结束的（排队、启动、运行、等待、退避，以及认不出的状态）：抽屉里的“进行中”、实时活动用。
    public var activeOnly: Bool
    /// 只要根运行（不要流水线的步骤、委派的子任务）。
    public var rootsOnly: Bool

    public init(planID: PlanID? = nil, activeOnly: Bool = false, rootsOnly: Bool = false) {
        self.planID = planID
        self.activeOnly = activeOnly
        self.rootsOnly = rootsOnly
    }

    /// 全部运行。
    public static let all = RunFilter()

    /// 所有没结束的运行（抽屉里的“进行中”、实时活动）。
    public static let active = RunFilter(activeOnly: true)

    /// 计划的运行历史：默认只要根运行，一次触发一行（流水线的步骤在运行树里看）。
    public static func plan(_ planID: PlanID, rootsOnly: Bool = true) -> RunFilter {
        RunFilter(planID: planID, rootsOnly: rootsOnly)
    }

    /// 这个运行符合条件（和服务端的查询一致；事件流更新了运行的状态时，视图模型可以用它决定还留不留在列表里）。
    public func matches(_ run: Run) -> Bool {
        if let planID, run.planID != planID { return false }
        if activeOnly && !run.state.isActive { return false }
        if rootsOnly && !run.isRoot { return false }
        return true
    }

    /// 一页默认几个（服务端不给 `limit` 时用的）。
    public static let defaultLimit = 50

    /// 一页最多几个：`limit` 服务端夹到 1…200。
    public static let maxLimit = 200

    /// 服务端实际用的页大小。
    public static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), maxLimit)
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

    /// `instanceArtifacts` 一次最多返回几个。
    public static let maxListLimit = 500
}
