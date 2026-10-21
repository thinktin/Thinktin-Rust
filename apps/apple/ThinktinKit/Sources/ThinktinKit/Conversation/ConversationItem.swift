import Foundation

/// 对话页面上的一项（docs/ios.md 第 5 节）。按运行分组：每个运行先是用户消息（`Run.prompt`），
/// 再是 agent 的输出，最后是运行状态行。`id` 在增量更新时保持不变（SwiftUI 列表靠它做差异）。
public struct ConversationItem: Identifiable, Hashable, Sendable {
    public var id: String
    /// 属于哪个运行；agent 在两轮之间发来的系统提示为 nil。
    public var runID: RunID?
    public var createdAt: Date
    public var content: Content

    public init(id: String, runID: RunID?, createdAt: Date, content: Content) {
        self.id = id
        self.runID = runID
        self.createdAt = createdAt
        self.content = content
    }

    public enum Content: Hashable, Sendable {
        /// 用户消息卡片（运行的任务）。
        case userMessage(UserMessage)
        /// assistant 文本（Markdown），连续的 `agent.message` 拼成一段。
        case assistantText(AssistantText)
        /// 可折叠的“思考”块，默认折叠。
        case thought(Thought)
        /// 工具调用卡片（agent 自己的工具或平台工具）。
        case toolCall(ToolCallCard)
        /// agent 的待办清单。
        case agentPlan(AgentPlanCard)
        /// 审批卡片。
        case approval(ApprovalCard)
        /// 保险箱表单卡片。
        case vaultRequest(VaultRequestCard)
        /// 运行状态行。
        case runStatus(RunStatusLine)
        /// 产出物卡片。
        case artifact(ArtifactCard)
        /// 子运行链接卡片（流水线步骤、委派）。
        case childRun(ChildRunCard)
        /// “agent 新建 / 修改了计划，待确认”卡片。
        case planActivity(PlanActivityCard)
        /// 系统提示行。
        case systemNotice(SystemNotice)
    }
}

/// 用户消息（运行的任务）。计划、流水线、委派发起的运行也显示成“用户消息”，用 `source` 区分。
public struct UserMessage: Hashable, Sendable {
    public var text: String
    public var source: RunSource
    public var planID: PlanID?
    /// 流水线步骤名。
    public var stepKey: String?

    public init(text: String, source: RunSource = .user, planID: PlanID? = nil, stepKey: String? = nil) {
        self.text = text
        self.source = source
        self.planID = planID
        self.stepKey = stepKey
    }
}

/// assistant 的回复文本。
public struct AssistantText: Hashable, Sendable {
    public var text: String
    /// 还在输出（这一轮没结束，而且是最后一项）。
    public var isStreaming: Bool
    /// 显示“AI 生成”标识（16.3）。
    public var isAIGenerated: Bool

    public init(text: String, isStreaming: Bool = false, isAIGenerated: Bool = true) {
        self.text = text
        self.isStreaming = isStreaming
        self.isAIGenerated = isAIGenerated
    }
}

/// agent 的思考过程。
public struct Thought: Hashable, Sendable {
    public var text: String
    public var isStreaming: Bool
    public var isAIGenerated: Bool

    public init(text: String, isStreaming: Bool = false, isAIGenerated: Bool = true) {
        self.text = text
        self.isStreaming = isStreaming
        self.isAIGenerated = isAIGenerated
    }
}

/// 工具调用卡片：标题、状态，展开看 `raw`。
public struct ToolCallCard: Hashable, Sendable {
    /// agent 工具是 `tool_call_id`，平台工具是 `call_id`。
    public var toolCallID: String
    public var title: String
    /// ACP 的 tool kind（read、edit、execute……）；平台工具为 nil。
    public var kind: String?
    /// 平台工具没有状态（为 nil）。
    public var status: ToolCallStatus?
    /// 原始内容（agent 工具是合并过更新的 ACP tool_call，平台工具是参数）。
    public var raw: JSONValue?
    /// 平台工具的类别；agent 自己的工具为 nil。
    public var platformCategory: PlatformToolCategory?

    public init(
        toolCallID: String, title: String, kind: String? = nil, status: ToolCallStatus? = nil, raw: JSONValue? = nil,
        platformCategory: PlatformToolCategory? = nil
    ) {
        self.toolCallID = toolCallID
        self.title = title
        self.kind = kind
        self.status = status
        self.raw = raw
        self.platformCategory = platformCategory
    }

    public var isPlatformTool: Bool { platformCategory != nil }
}

/// agent 的待办清单（每次更新都是完整清单，原地替换）。
public struct AgentPlanCard: Hashable, Sendable {
    public var entries: [AgentPlanEntry]
    public var isAIGenerated: Bool

    public init(entries: [AgentPlanEntry], isAIGenerated: Bool = true) {
        self.entries = entries
        self.isAIGenerated = isAIGenerated
    }

    public var completedCount: Int { entries.filter { $0.status == .completed }.count }
}

/// 审批卡片：未决时显示选项按钮（调 `decideApproval`，要先拿到 `approvalID`），已决显示结果和由谁决定。
public struct ApprovalCard: Hashable, Sendable {
    /// agent 那边的请求 id（事件里的 `request_id`）。
    public var requestID: String
    /// 审批记录的 id（`ConversationReducer.link(approvals:)` 关联上之后才有）：决定时用它。
    public var approvalID: ApprovalID?
    public var title: String?
    public var options: [ApprovalOption]
    public var toolCall: JSONValue?
    /// 已决时有。
    public var resolution: Resolution?

    public init(
        requestID: String, approvalID: ApprovalID? = nil, title: String?, options: [ApprovalOption],
        toolCall: JSONValue? = nil, resolution: Resolution? = nil
    ) {
        self.requestID = requestID
        self.approvalID = approvalID
        self.title = title
        self.options = options
        self.toolCall = toolCall
        self.resolution = resolution
    }

    public var isPending: Bool { resolution == nil }

    /// 审批的结果。
    public struct Resolution: Hashable, Sendable {
        /// 选中的选项；为 nil 表示放弃作答（超时、取消）。
        public var optionID: String?
        /// 选项的名字（找得到的话）。
        public var optionName: String?
        public var by: DecisionSource
        /// 批准了（选的是 allow 类选项）；没有选项时为 false。
        public var isApproved: Bool

        public init(optionID: String?, optionName: String?, by: DecisionSource, isApproved: Bool) {
            self.optionID = optionID
            self.optionName = optionName
            self.by = by
            self.isApproved = isApproved
        }
    }
}

/// 保险箱表单卡片：agent 请用户填账号密码（只进保险箱，agent 只拿到名字）。
public struct VaultRequestCard: Hashable, Sendable {
    public var requestID: VaultRequestID
    public var name: String
    /// agent 写的用途：显示时带“AI 生成”标识。
    public var purpose: String
    public var fields: [VaultField]
    public var status: VaultRequestStatus

    public init(
        requestID: VaultRequestID, name: String, purpose: String, fields: [VaultField],
        status: VaultRequestStatus = .pending
    ) {
        self.requestID = requestID
        self.name = name
        self.purpose = purpose
        self.fields = fields
        self.status = status
    }

    /// 用途是 agent 写的。
    public var purposeIsAIGenerated: Bool { true }
}

/// 运行状态行：等待类状态显示原因和下一步。
public struct RunStatusLine: Hashable, Sendable {
    public var state: RunState
    public var reason: String?
    public var attempt: Int?
    public var tokensUsed: Int?
    public var error: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        state: RunState, reason: String? = nil, attempt: Int? = nil, tokensUsed: Int? = nil, error: String? = nil,
        startedAt: Date? = nil, finishedAt: Date? = nil
    ) {
        self.state = state
        self.reason = reason
        self.attempt = attempt
        self.tokensUsed = tokensUsed
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// 等待类状态的下一步。
    public var nextStep: RunNextStep? {
        switch state {
        case .waitingApproval: .approve
        case .waitingQuota: .configureKey
        case .waitingDevice: .waitForComputer
        case .waitingChildren: .waitForSubtasks
        default: nil
        }
    }
}

/// 运行在等什么、用户该做什么。
public enum RunNextStep: String, Hashable, Sendable {
    /// 去审批。
    case approve
    /// 去配 key（额度用完或 key 失效）。
    case configureKey
    /// 等电脑上线。
    case waitForComputer
    /// 等子任务完成。
    case waitForSubtasks
}

/// 产出物卡片，点开预览 / 分享。
public struct ArtifactCard: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var name: String
    public var version: Int
    public var size: Int

    public init(artifactID: ArtifactID, name: String, version: Int, size: Int) {
        self.artifactID = artifactID
        self.name = name
        self.version = version
        self.size = size
    }
}

/// 子运行链接卡片，进运行树。
public struct ChildRunCard: Hashable, Sendable {
    public var runID: RunID
    public var instanceID: InstanceID
    public var title: String
    public var origin: Origin

    public init(runID: RunID, instanceID: InstanceID, title: String, origin: Origin) {
        self.runID = runID
        self.instanceID = instanceID
        self.title = title
        self.origin = origin
    }

    public enum Origin: Hashable, Sendable {
        /// 流水线的一步。
        case pipelineStep(String)
        /// 委派给另一个实例（实例名）。
        case delegate(to: String)
    }
}

/// agent 对计划的改动：待确认（跳到计划页）或已取消。
public struct PlanActivityCard: Hashable, Sendable {
    public var planID: PlanID
    public var title: String
    public var activity: Activity

    public init(planID: PlanID, title: String, activity: Activity) {
        self.planID = planID
        self.title = title
        self.activity = activity
    }

    public enum Activity: Hashable, Sendable {
        case needsConfirmation(PlanChange)
        case cancelled
    }
}

/// 系统提示行。
public struct SystemNotice: Hashable, Sendable {
    public var kind: Kind
    /// 原始说明（英文，给开发者看的；界面按 `kind` 显示本地化文案）。
    public var message: String?

    public init(kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    public enum Kind: Hashable, Sendable {
        /// agent 报错。
        case agentError
        /// 会话接不回来，开了新会话。
        case sessionLost
        /// agent 进程退出（`willRestart` 时会自动重启）。
        case agentExited(willRestart: Bool)
        /// 运行日志到上限，之后的输出不再记录。
        case logTruncated
        /// 用了保险箱里的条目。
        case vaultUsed([String])
    }
}

/// 一个运行在对话里的那一组。
public struct ConversationTurn: Identifiable, Hashable, Sendable {
    /// 运行 id；没有运行的系统提示组是 `none-<seq>`。
    public var id: String
    public var runID: RunID?
    /// 运行记录（还没加载时为 nil，这时不显示用户消息）。
    public var run: Run?
    /// 这一组的全部项（用户消息、输出、状态行）。
    public var items: [ConversationItem]
    /// 最新的运行状态。
    public var state: RunState?
    /// agent 还在输出。
    public var isStreaming: Bool
    /// 最近一次 `agent.usage` 的内容（运行详情里显示）。
    public var lastUsage: JSONValue?
}
