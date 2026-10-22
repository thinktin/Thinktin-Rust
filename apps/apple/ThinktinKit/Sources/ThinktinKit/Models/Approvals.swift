import Foundation

/// 审批的一个选项。
public struct ApprovalOption: Identifiable, Hashable, Codable, Sendable {
    /// `option_id`：决定时原样传回。
    public var id: String
    public var name: String
    public var kind: ApprovalOptionKind

    public init(id: String, name: String, kind: ApprovalOptionKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// agent 请求执行的、要用户批准的操作。
///
/// 和运行日志里的审批事件对应（docs/agent-integration.md 第 6 节）：shim 每次尝试都从 `perm-1` 重新编号，
/// 所以要 `runID`、`attempt`、`requestID` 三个一起认（`agent.permission_requested` 带 `approval_id` 时直接用它）。
public struct Approval: Identifiable, Hashable, Codable, Sendable {
    public var id: ApprovalID
    public var runID: RunID
    public var instanceID: InstanceID
    /// agent 写的标题：显示时带“AI 生成”标识。
    public var title: String?
    public var options: [ApprovalOption]
    /// agent 要执行的工具调用（ACP 的 tool_call，JSON 文本），给用户看细节。
    public var toolCallJSON: String
    public var state: ApprovalState
    public var expiresAt: Date
    public var createdAt: Date
    /// shim 给的请求 id（11.8，和 `agent.permission_requested` 事件里的 `request_id` 一样）；老数据为空。
    public var requestID: String
    /// 第几次尝试（11.8，和 `run.state` 事件的 `attempt` 一样）；0 是不知道（老数据）。
    public var attempt: Int
    /// 选了哪个选项（`option_id`，11.8）；还没处理、过期了的为 nil。
    public var decidedOption: String?
    /// 什么时候处理的（11.8）；还没处理的为 nil。
    public var decidedAt: Date?

    public init(
        id: ApprovalID, runID: RunID, instanceID: InstanceID, title: String?, options: [ApprovalOption],
        toolCallJSON: String = "{}", state: ApprovalState = .pending, expiresAt: Date, createdAt: Date,
        requestID: String = "", attempt: Int = 0, decidedOption: String? = nil, decidedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.instanceID = instanceID
        self.title = title
        self.options = options
        self.toolCallJSON = toolCallJSON
        self.state = state
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.requestID = requestID
        self.attempt = attempt
        self.decidedOption = decidedOption
        self.decidedAt = decidedAt
    }

    /// 选中的选项（`decidedOption` 对得上 `options` 里的一个时）。
    public var decidedOptionInfo: ApprovalOption? {
        decidedOption.flatMap { id in options.first { $0.id == id } }
    }

    /// 解析好的工具调用（不是合法 JSON 时为 nil）。
    public var toolCall: ToolCallPayload? {
        ToolCallPayload(json: toolCallJSON)
    }

    public var isPending: Bool { state == .pending }

    /// 过期了（还没决定、已经过了期限）。
    public func isExpired(now: Date = Date()) -> Bool {
        state == .expired || (state == .pending && expiresAt <= now)
    }
}
