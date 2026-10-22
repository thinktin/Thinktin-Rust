import Foundation

/// 实例事件流里的一条（运行日志）。同一实例里按 `seq` 递增。
public struct InstanceEvent: Identifiable, Hashable, Codable, Sendable {
    public var instanceID: InstanceID
    public var seq: UInt64
    public var runID: RunID?
    public var kind: InstanceEventKind
    /// 载荷（JSON 文本）；解析好的见 `payload`。
    public var payloadJSON: String
    /// 内容是 agent 生成的（消息、思考、计划）：显示时要带“AI 生成”标识（16.3）。
    public var isAIGenerated: Bool
    public var createdAt: Date

    public init(
        instanceID: InstanceID, seq: UInt64, runID: RunID?, kind: InstanceEventKind, payloadJSON: String,
        isAIGenerated: Bool? = nil, createdAt: Date
    ) {
        self.instanceID = instanceID
        self.seq = seq
        self.runID = runID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.isAIGenerated = isAIGenerated ?? kind.isAIGenerated
        self.createdAt = createdAt
    }

    /// 同一实例里唯一：`<实例 id>#<seq>`。
    public var id: String { "\(instanceID.rawValue)#\(seq)" }

    /// 按 `kind` 解析好的载荷。
    public var payload: EventPayload {
        EventPayload(kind: kind, json: payloadJSON)
    }

    /// 载荷的原始 JSON（解析失败时为 nil）。
    public var payloadValue: JSONValue? {
        JSONValue.parse(payloadJSON)
    }

    /// `run.state` 事件的载荷；别的事件为 nil。
    public var runStatePayload: RunStatePayload? {
        guard kind == .runState else { return nil }
        return EventPayload.decode(RunStatePayload.self, from: payloadJSON)
    }

    /// 工具调用（`agent.tool_call`、`agent.tool_call_update`）的载荷；别的事件为 nil。
    public var toolCallPayload: ToolCallPayload? {
        guard kind == .toolCall || kind == .toolCallUpdate else { return nil }
        return ToolCallPayload(json: payloadJSON)
    }
}

/// 事件的种类（`kind`）。取值见 crates/orchestrator（`agent.*` 是 agent-shim 的事件）。
public enum InstanceEventKind: OpenStringEnum {
    case agentReady
    case agentSessionLost
    case agentExited
    case agentMessage
    case agentThought
    case toolCall
    case toolCallUpdate
    case agentPlan
    case agentUsage
    case permissionRequested
    case permissionResolved
    case agentUpdate
    case turnStarted
    case platformToolCall
    case vaultReveal
    case turnEnded
    case agentError
    case runState
    case runLogTruncated
    case approvalDecided
    case artifactPublished
    case delegateStarted
    case pipelineStepStarted
    case planNeedsConfirmation
    case planCancelled
    case vaultRequested
    case vaultFulfilled
    case vaultDeclined
    case vaultUsed
    case unknown(String)

    public static let knownCases: [InstanceEventKind] = [
        .agentReady, .agentSessionLost, .agentExited, .agentMessage, .agentThought, .toolCall, .toolCallUpdate,
        .agentPlan, .agentUsage, .permissionRequested, .permissionResolved, .agentUpdate, .turnStarted,
        .platformToolCall, .vaultReveal, .turnEnded, .agentError, .runState, .runLogTruncated, .approvalDecided,
        .artifactPublished, .delegateStarted, .pipelineStepStarted, .planNeedsConfirmation, .planCancelled,
        .vaultRequested, .vaultFulfilled, .vaultDeclined, .vaultUsed,
    ]

    public var rawValue: String {
        switch self {
        case .agentReady: "agent.ready"
        case .agentSessionLost: "agent.session_lost"
        case .agentExited: "agent.exited"
        case .agentMessage: "agent.message"
        case .agentThought: "agent.thought"
        case .toolCall: "agent.tool_call"
        case .toolCallUpdate: "agent.tool_call_update"
        case .agentPlan: "agent.plan"
        case .agentUsage: "agent.usage"
        case .permissionRequested: "agent.permission_requested"
        case .permissionResolved: "agent.permission_resolved"
        case .agentUpdate: "agent.update"
        case .turnStarted: "agent.turn_started"
        case .platformToolCall: "agent.platform_tool_call"
        case .vaultReveal: "agent.vault_reveal"
        case .turnEnded: "agent.turn_ended"
        case .agentError: "agent.error"
        case .runState: "run.state"
        case .runLogTruncated: "run.log_truncated"
        case .approvalDecided: "approval.decided"
        case .artifactPublished: "artifact.published"
        case .delegateStarted: "delegate.started"
        case .pipelineStepStarted: "pipeline.step_started"
        case .planNeedsConfirmation: "plan.needs_confirmation"
        case .planCancelled: "plan.cancelled"
        case .vaultRequested: "vault.requested"
        case .vaultFulfilled: "vault.fulfilled"
        case .vaultDeclined: "vault.declined"
        case .vaultUsed: "vault.used"
        case .unknown(let raw): raw
        }
    }

    /// 和服务端 `proto::labels::is_ai_generated_event` 一致。
    public var isAIGenerated: Bool {
        switch self {
        case .agentMessage, .agentThought, .agentPlan: true
        default: false
        }
    }
}

/// 事件流的连接状态。
public enum StreamStatus: Hashable, Sendable {
    case connecting
    case live
    /// 断开了，过 `retryIn` 秒重连。
    case reconnecting(retryIn: TimeInterval)
    /// 登录失效，事件流停止：回登录页。
    case signedOut
    /// 实例不存在或不属于当前用户，事件流停止：回实例列表。
    case notFound
    /// 账号被冻结（4.6），事件流停止：显示冻结页。
    case accountFrozen
    /// 调用方停的；或者这个版本太老了，服务端不再接受（11.8：这时 `ClientProtocol.upgradeRequired()` 是 true，
    /// 界面进升级页，之后的订阅也直接以它结束、不再连）。
    case stopped

    /// 连接中或重连中：顶部显示细条。
    public var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    /// 事件流已经停止，不会再收到事件。
    public var isFinal: Bool {
        switch self {
        case .signedOut, .notFound, .accountFrozen, .stopped: true
        default: false
        }
    }
}
