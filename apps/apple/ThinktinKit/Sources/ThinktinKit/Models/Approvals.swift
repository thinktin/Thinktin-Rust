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
public struct Approval: Identifiable, Hashable, Codable, Sendable {
    public var id: ApprovalID
    public var runID: RunID
    public var instanceID: InstanceID
    public var title: String?
    public var options: [ApprovalOption]
    /// agent 要执行的工具调用（ACP 的 tool_call，JSON 文本），给用户看细节。
    public var toolCallJSON: String
    public var state: ApprovalState
    public var expiresAt: Date
    public var createdAt: Date

    public init(
        id: ApprovalID, runID: RunID, instanceID: InstanceID, title: String?, options: [ApprovalOption],
        toolCallJSON: String = "{}", state: ApprovalState = .pending, expiresAt: Date, createdAt: Date
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
