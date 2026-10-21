import Foundation

/// 触发规则。
public enum Schedule: Hashable, Codable, Sendable {
    /// 五段 cron，按 `timeZone`（IANA 名称，比如 Asia/Shanghai）的本地时间。
    case cron(expression: String, timeZone: String)
    /// iCalendar 的 DTSTART;TZID=...+RRULE。
    case rrule(String)
    /// 一次性定时。
    case once(Date)
}

/// 计划的一个触发器。
public struct Trigger: Identifiable, Hashable, Codable, Sendable {
    public var id: TriggerID
    public var schedule: Schedule
    public var isEnabled: Bool
    public var nextFireAt: Date?
    public var lastFireAt: Date?

    public init(id: TriggerID, schedule: Schedule, isEnabled: Bool = true, nextFireAt: Date? = nil, lastFireAt: Date? = nil) {
        self.id = id
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.nextFireAt = nextFireAt
        self.lastFireAt = lastFireAt
    }
}

/// 流水线的一步。
public struct PlanStep: Identifiable, Hashable, Codable, Sendable {
    /// 步骤名，在计划里唯一；`dependsOn` 引用它。
    public var key: String
    public var instanceID: InstanceID
    public var prompt: String
    public var dependsOn: [String]

    public var id: String { key }

    public init(key: String, instanceID: InstanceID, prompt: String, dependsOn: [String] = []) {
        self.key = key
        self.instanceID = instanceID
        self.prompt = prompt
        self.dependsOn = dependsOn
    }
}

/// 计划：定时（或一次性）在实例上执行的任务；有 `steps` 时是流水线。
public struct Plan: Identifiable, Hashable, Codable, Sendable {
    public var id: PlanID
    public var instanceID: InstanceID
    public var title: String
    public var goal: String
    public var isPaused: Bool
    public var createdBy: PlanAuthor
    /// agent 新建或修改过、等用户确认（`confirmPlan` 带上 `revision`）。
    public var awaitingConfirmation: Bool
    /// 计划的版本，确认时原样带回。
    public var revision: Int
    /// 策略（预授权工具、审批超时、预算），JSON 文本；解析好的见 `policy`。
    public var policyJSON: String
    public var createdAt: Date
    /// 列表接口里为空，详情里有。
    public var triggers: [Trigger]
    public var steps: [PlanStep]

    public init(
        id: PlanID, instanceID: InstanceID, title: String, goal: String, isPaused: Bool = false,
        createdBy: PlanAuthor = .user, awaitingConfirmation: Bool = false, revision: Int = 1,
        policyJSON: String = "{}", createdAt: Date, triggers: [Trigger] = [], steps: [PlanStep] = []
    ) {
        self.id = id
        self.instanceID = instanceID
        self.title = title
        self.goal = goal
        self.isPaused = isPaused
        self.createdBy = createdBy
        self.awaitingConfirmation = awaitingConfirmation
        self.revision = revision
        self.policyJSON = policyJSON
        self.createdAt = createdAt
        self.triggers = triggers
        self.steps = steps
    }

    /// 解析好的策略；JSON 不合法时为 nil，缺的字段用服务端的默认值。
    public var policy: PlanPolicy? {
        guard let data = policyJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlanPolicy.self, from: data)
    }

    /// 是流水线（多个步骤）。
    public var isPipeline: Bool { !steps.isEmpty }

    /// 最近一次要触发的时间（所有启用的触发器里最早的）。
    public var nextFireAt: Date? {
        triggers.filter(\.isEnabled).compactMap(\.nextFireAt).min()
    }
}

/// 新建计划。
public struct NewPlan: Hashable, Codable, Sendable {
    public var instanceID: InstanceID
    public var title: String
    public var goal: String
    public var triggers: [Schedule]
    /// 给了就是流水线：按依赖顺序在各个实例上执行。
    public var steps: [PlanStep]

    public init(instanceID: InstanceID, title: String, goal: String, triggers: [Schedule], steps: [PlanStep] = []) {
        self.instanceID = instanceID
        self.title = title
        self.goal = goal
        self.triggers = triggers
        self.steps = steps
    }
}

/// 计划的执行策略（`Plan.policyJSON` 解析出来的；字段同 crates/proto 的 `PlanPolicy`）。
public struct PlanPolicy: Hashable, Codable, Sendable {
    /// 预授权的工具种类（ACP 的 tool kind，比如 read、edit、search）。
    public var preauthorizedTools: [String]
    public var approvalTimeoutSecs: Int
    /// 审批超时，以及等电脑、等 key 超时之后怎么办。
    public var onApprovalTimeout: ApprovalTimeoutAction
    public var budget: RunBudget
    /// 每天最多消耗的 token 数（整个计划）。
    public var dailyTokenLimit: Int?
    /// 等电脑上线、等补上 key 最多等多久。
    public var waitTimeoutSecs: Int

    public init(
        preauthorizedTools: [String] = [], approvalTimeoutSecs: Int = 24 * 3600,
        onApprovalTimeout: ApprovalTimeoutAction = .pausePlan, budget: RunBudget = RunBudget(),
        dailyTokenLimit: Int? = nil, waitTimeoutSecs: Int = 24 * 3600
    ) {
        self.preauthorizedTools = preauthorizedTools
        self.approvalTimeoutSecs = approvalTimeoutSecs
        self.onApprovalTimeout = onApprovalTimeout
        self.budget = budget
        self.dailyTokenLimit = dailyTokenLimit
        self.waitTimeoutSecs = waitTimeoutSecs
    }

    enum CodingKeys: String, CodingKey {
        case preauthorizedTools = "preauthorized_tools"
        case approvalTimeoutSecs = "approval_timeout_secs"
        case onApprovalTimeout = "on_approval_timeout"
        case budget
        case dailyTokenLimit = "daily_token_limit"
        case waitTimeoutSecs = "wait_timeout_secs"
    }

    public init(from decoder: any Decoder) throws {
        let d = PlanPolicy()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preauthorizedTools = try c.decodeIfPresent([String].self, forKey: .preauthorizedTools) ?? d.preauthorizedTools
        approvalTimeoutSecs = try c.decodeIfPresent(Int.self, forKey: .approvalTimeoutSecs) ?? d.approvalTimeoutSecs
        onApprovalTimeout =
            try c.decodeIfPresent(ApprovalTimeoutAction.self, forKey: .onApprovalTimeout) ?? d.onApprovalTimeout
        budget = try c.decodeIfPresent(RunBudget.self, forKey: .budget) ?? d.budget
        dailyTokenLimit = try c.decodeIfPresent(Int.self, forKey: .dailyTokenLimit)
        waitTimeoutSecs = try c.decodeIfPresent(Int.self, forKey: .waitTimeoutSecs) ?? d.waitTimeoutSecs
    }
}

/// 一次运行的预算。
public struct RunBudget: Hashable, Codable, Sendable {
    public var maxTokens: Int?
    public var maxDurationSecs: Int
    public var maxSteps: Int?

    public init(maxTokens: Int? = nil, maxDurationSecs: Int = 6 * 3600, maxSteps: Int? = nil) {
        self.maxTokens = maxTokens
        self.maxDurationSecs = maxDurationSecs
        self.maxSteps = maxSteps
    }

    enum CodingKeys: String, CodingKey {
        case maxTokens = "max_tokens"
        case maxDurationSecs = "max_duration_secs"
        case maxSteps = "max_steps"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        maxDurationSecs = try c.decodeIfPresent(Int.self, forKey: .maxDurationSecs) ?? 6 * 3600
        maxSteps = try c.decodeIfPresent(Int.self, forKey: .maxSteps)
    }
}
