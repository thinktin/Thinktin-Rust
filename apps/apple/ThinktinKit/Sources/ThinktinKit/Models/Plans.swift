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

    public init(
        id: TriggerID, schedule: Schedule, isEnabled: Bool = true, nextFireAt: Date? = nil, lastFireAt: Date? = nil
    ) {
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

    /// 步骤名的格式（和服务端一致）：1 到 32 个 a-z、0-9、`_`、`-`，字母或数字开头。
    public static func isValidKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard (1...32).contains(bytes.count) else { return false }
        return bytes.enumerated().allSatisfy { i, b in
            let alnum =
                (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            return alnum || (i > 0 && (b == UInt8(ascii: "_") || b == UInt8(ascii: "-")))
        }
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
    /// 计划的版本，确认时原样带回：确认之前又被改过，确认会失败（要重新给用户看一遍）。
    public var revision: Int
    /// 策略：预授权工具、审批超时、预算、每日上限、等待超时。
    public var policy: PlanPolicy
    /// 错过的触发怎么补。
    public var catchUp: CatchUp
    public var createdAt: Date
    /// 列表接口里为空，详情里有。
    public var triggers: [Trigger]
    public var steps: [PlanStep]

    public init(
        id: PlanID, instanceID: InstanceID, title: String, goal: String, isPaused: Bool = false,
        createdBy: PlanAuthor = .user, awaitingConfirmation: Bool = false, revision: Int = 1,
        policy: PlanPolicy = PlanPolicy(), catchUp: CatchUp = .default, createdAt: Date, triggers: [Trigger] = [],
        steps: [PlanStep] = []
    ) {
        self.id = id
        self.instanceID = instanceID
        self.title = title
        self.goal = goal
        self.isPaused = isPaused
        self.createdBy = createdBy
        self.awaitingConfirmation = awaitingConfirmation
        self.revision = revision
        self.policy = policy
        self.catchUp = catchUp
        self.createdAt = createdAt
        self.triggers = triggers
        self.steps = steps
    }

    /// 一个计划最多几个触发器。
    public static let maxTriggers = 10
    /// 流水线最多几步。
    public static let maxSteps = 20
    /// 标题最长几个字符。
    public static let maxTitleLength = 100
    /// 目标最长几个字符。
    public static let maxGoalLength = 8000

    /// 策略的 JSON 文本（服务端的字段名，和 ThinktinCore 的 `policy_json` 同格式）。只为兼容保留，以 `policy` 为准。
    public var policyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(policy)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
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
    /// nil 用服务端默认的策略（`PlanPolicy()`）。
    public var policy: PlanPolicy?
    /// nil 用默认的 `once`。
    public var catchUp: CatchUp?

    public init(
        instanceID: InstanceID, title: String, goal: String, triggers: [Schedule], steps: [PlanStep] = [],
        policy: PlanPolicy? = nil, catchUp: CatchUp? = nil
    ) {
        self.instanceID = instanceID
        self.title = title
        self.goal = goal
        self.triggers = triggers
        self.steps = steps
        self.policy = policy
        self.catchUp = catchUp
    }
}

/// 改计划（`updatePlan`）：只改给了的字段，nil 的不动。`steps` 整体替换，给空数组就变回单个 agent 的计划。
/// 触发器另用 `addTrigger`、`deleteTrigger` 改。
public struct PlanChange: Hashable, Codable, Sendable {
    public var title: String?
    public var goal: String?
    public var policy: PlanPolicy?
    public var catchUp: CatchUp?
    public var steps: [PlanStep]?

    public init(
        title: String? = nil, goal: String? = nil, policy: PlanPolicy? = nil, catchUp: CatchUp? = nil,
        steps: [PlanStep]? = nil
    ) {
        self.title = title
        self.goal = goal
        self.policy = policy
        self.catchUp = catchUp
        self.steps = steps
    }

    /// 什么都没改。
    public var isEmpty: Bool {
        title == nil && goal == nil && policy == nil && catchUp == nil && steps == nil
    }

    /// 把改动套到计划上（只动给了的字段，不校验、不改版本号）。界面上预览改完的样子用。
    public func applied(to plan: Plan) -> Plan {
        var p = plan
        if let title { p.title = title }
        if let goal { p.goal = goal }
        if let policy { p.policy = policy }
        if let catchUp { p.catchUp = catchUp }
        if let steps { p.steps = steps }
        return p
    }
}

/// 计划的执行策略（4.4、4.7、7.11；字段同 ThinktinCore 的 `PlanPolicy` 记录，每次运行的上限收在 `budget` 里）。
///
/// 编解码用服务端的字段名（`preauthorized_tools`、`budget.max_tokens`……），缺的字段取服务端的默认值。
public struct PlanPolicy: Hashable, Codable, Sendable {
    /// 预授权的工具种类（ACP 的 tool kind：read、edit、search、execute……），用到时不用审批。
    public var preauthorizedTools: [String]
    /// 审批等多久（秒，60 秒到 7 天）。
    public var approvalTimeoutSecs: Int
    /// 审批超时，以及等电脑、等 key 超时之后怎么办。
    public var onApprovalTimeout: ApprovalTimeoutAction
    /// 每次运行的上限：token 数、时长、步数。
    public var budget: RunBudget
    /// 整个计划每天最多用多少 token；nil 不限。
    public var dailyTokenLimit: Int?
    /// 等电脑上线、等补上 key 最多等多久（秒，60 秒到 7 天）。
    public var waitTimeoutSecs: Int

    /// 审批超时、等待超时允许的范围（秒）。
    public static let timeoutRange = 60...(7 * 24 * 3600)
    /// 每次运行的时长上限允许的范围（秒）。
    public static let maxDurationRange = 1...(24 * 3600)
    /// 预授权的工具种类最多几个。
    public static let maxPreauthorizedTools = 32

    /// 解析服务端 `policy` 字段的 JSON 文本（老接口的 `policy_json`、旧的缓存）。不是合法 JSON 时为 nil，缺的字段用默认值。
    public init?(json: String) {
        guard let data = json.data(using: .utf8), let policy = try? JSONDecoder().decode(PlanPolicy.self, from: data)
        else { return nil }
        self = policy
    }

    /// 取值都在服务端允许的范围里（不在的保存时返回 invalid）。
    public var isValid: Bool {
        Self.timeoutRange.contains(approvalTimeoutSecs) && Self.timeoutRange.contains(waitTimeoutSecs)
            && Self.maxDurationRange.contains(budget.maxDurationSecs)
            && preauthorizedTools.count <= Self.maxPreauthorizedTools
    }

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
    /// 最多用多少 token；nil 不限。
    public var maxTokens: Int?
    /// 最长跑多久（秒，1 秒到 24 小时）。
    public var maxDurationSecs: Int
    /// 最多几步（工具调用）；nil 不限。
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
