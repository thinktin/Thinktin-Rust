import Foundation

// 事件载荷（`InstanceEvent.payloadJSON`）解析好的形式。字段名和服务端写进运行日志的一致（snake_case），
// 见 docs/ios.md 第 5 节和 crates/proto/src/shim.rs 的 `ShimEvent`。缺字段、多字段都不报错。

/// 按事件种类解析好的载荷。
public enum EventPayload: Hashable, Sendable {
    /// `agent.message`
    case message(TextPayload)
    /// `agent.thought`
    case thought(TextPayload)
    /// `agent.tool_call`
    case toolCall(ToolCallPayload)
    /// `agent.tool_call_update`
    case toolCallUpdate(ToolCallPayload)
    /// `agent.platform_tool_call`
    case platformToolCall(PlatformToolCallPayload)
    /// `agent.plan`
    case agentPlan(AgentPlanPayload)
    /// `agent.permission_requested`
    case permissionRequested(PermissionRequestedPayload)
    /// `agent.permission_resolved`
    case permissionResolved(PermissionResolvedPayload)
    /// `approval.decided`
    case approvalDecided(ApprovalDecidedPayload)
    /// `vault.requested`
    case vaultRequested(VaultRequestedPayload)
    /// `vault.fulfilled`
    case vaultFulfilled(VaultResolvedPayload)
    /// `vault.declined`
    case vaultDeclined(VaultResolvedPayload)
    /// `vault.used`
    case vaultUsed(VaultUsedPayload)
    /// `run.state`
    case runState(RunStatePayload)
    /// `artifact.published`
    case artifactPublished(ArtifactPublishedPayload)
    /// `pipeline.step_started`
    case pipelineStepStarted(PipelineStepStartedPayload)
    /// `delegate.started`
    case delegateStarted(DelegateStartedPayload)
    /// `plan.needs_confirmation`
    case planNeedsConfirmation(PlanNeedsConfirmationPayload)
    /// `plan.cancelled`
    case planCancelled(PlanCancelledPayload)
    /// `agent.turn_ended`
    case turnEnded(TurnEndedPayload)
    /// `agent.error`
    case agentError(ErrorPayload)
    /// `agent.session_lost`
    case sessionLost(SessionLostPayload)
    /// `agent.exited`
    case agentExited(AgentExitedPayload)
    /// `run.log_truncated`
    case logTruncated(LogTruncatedPayload)
    /// 不单独建模的事件（`agent.usage`、`agent.ready`、`agent.update`、`agent.turn_started`、不认识的种类），
    /// 或者载荷解析失败：保留原始 JSON。
    case other(JSONValue?)

    public init(kind: InstanceEventKind, json: String) {
        func parse<T: Decodable>(_ type: T.Type, _ wrap: (T) -> EventPayload) -> EventPayload {
            guard let value = Self.decode(type, from: json) else { return .other(JSONValue.parse(json)) }
            return wrap(value)
        }
        switch kind {
        case .agentMessage: self = parse(TextPayload.self, EventPayload.message)
        case .agentThought: self = parse(TextPayload.self, EventPayload.thought)
        case .toolCall:
            self = ToolCallPayload(json: json).map(EventPayload.toolCall) ?? .other(JSONValue.parse(json))
        case .toolCallUpdate:
            self = ToolCallPayload(json: json).map(EventPayload.toolCallUpdate) ?? .other(JSONValue.parse(json))
        case .platformToolCall: self = parse(PlatformToolCallPayload.self, EventPayload.platformToolCall)
        case .agentPlan: self = parse(AgentPlanPayload.self, EventPayload.agentPlan)
        case .permissionRequested: self = parse(PermissionRequestedPayload.self, EventPayload.permissionRequested)
        case .permissionResolved: self = parse(PermissionResolvedPayload.self, EventPayload.permissionResolved)
        case .approvalDecided: self = parse(ApprovalDecidedPayload.self, EventPayload.approvalDecided)
        case .vaultRequested: self = parse(VaultRequestedPayload.self, EventPayload.vaultRequested)
        case .vaultFulfilled: self = parse(VaultResolvedPayload.self, EventPayload.vaultFulfilled)
        case .vaultDeclined: self = parse(VaultResolvedPayload.self, EventPayload.vaultDeclined)
        case .vaultUsed: self = parse(VaultUsedPayload.self, EventPayload.vaultUsed)
        case .runState: self = parse(RunStatePayload.self, EventPayload.runState)
        case .artifactPublished: self = parse(ArtifactPublishedPayload.self, EventPayload.artifactPublished)
        case .pipelineStepStarted: self = parse(PipelineStepStartedPayload.self, EventPayload.pipelineStepStarted)
        case .delegateStarted: self = parse(DelegateStartedPayload.self, EventPayload.delegateStarted)
        case .planNeedsConfirmation:
            self = parse(PlanNeedsConfirmationPayload.self, EventPayload.planNeedsConfirmation)
        case .planCancelled: self = parse(PlanCancelledPayload.self, EventPayload.planCancelled)
        case .turnEnded: self = parse(TurnEndedPayload.self, EventPayload.turnEnded)
        case .agentError: self = parse(ErrorPayload.self, EventPayload.agentError)
        case .agentSessionLost: self = parse(SessionLostPayload.self, EventPayload.sessionLost)
        case .agentExited: self = parse(AgentExitedPayload.self, EventPayload.agentExited)
        case .runLogTruncated: self = parse(LogTruncatedPayload.self, EventPayload.logTruncated)
        default: self = .other(JSONValue.parse(json))
        }
    }

    /// 解码 JSON 文本，失败返回 nil。
    static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// `agent.message`、`agent.thought`：`{text}`。多条连续的拼成一段。
public struct TextPayload: Hashable, Codable, Sendable {
    public var text: String

    public init(text: String) { self.text = text }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// 工具调用：`agent.tool_call` / `agent.tool_call_update` 的载荷（`{tool_call_id, title, kind, status, raw}`），
/// 也用来解析审批里的 `tool_call_json`（ACP 的 tool_call，字段是 camelCase）。
public struct ToolCallPayload: Hashable, Codable, Sendable {
    public var toolCallID: String
    public var title: String?
    /// ACP 的 tool kind（read、edit、execute、search……）。
    public var kind: String?
    public var status: ToolCallStatus?
    /// agent 发来的原始内容，展开详情时显示。
    public var raw: JSONValue?

    public init(
        toolCallID: String, title: String? = nil, kind: String? = nil, status: ToolCallStatus? = nil,
        raw: JSONValue? = nil
    ) {
        self.toolCallID = toolCallID
        self.title = title
        self.kind = kind
        self.status = status
        self.raw = raw
    }

    /// 从 JSON 文本解析：两种字段命名都认（`tool_call_id` / `toolCallId`）；不是 JSON 对象时为 nil。
    public init?(json: String) {
        guard let value = JSONValue.parse(json), let object = value.objectValue else { return nil }
        self.init(object: object)
    }

    init(object o: [String: JSONValue]) {
        toolCallID = o["tool_call_id"]?.stringValue ?? o["toolCallId"]?.stringValue ?? ""
        title = o["title"]?.stringValue
        kind = o["kind"]?.stringValue
        status = o["status"]?.stringValue.map(ToolCallStatus.init(rawValue:))
        // 事件里原始内容在 `raw`（为 null 时当作没有，免得合并更新时把原来的内容冲掉）；
        // 审批的 tool_call 没有 `raw` 字段，本身就是原始内容。
        // 注意 JSONValue 也认 nil 字面量：`r.isNull ? nil : r` 里的 nil 会变成 `.null`，所以分开写。
        if let r = o["raw"] {
            if r.isNull { raw = Optional.none } else { raw = r }
        } else {
            raw = .object(o)
        }
        if title == nil { title = raw?["title"]?.stringValue }
        if kind == nil { kind = raw?["kind"]?.stringValue }
        if status == nil { status = raw?["status"]?.stringValue.map(ToolCallStatus.init(rawValue:)) }
    }

    enum CodingKeys: String, CodingKey {
        case toolCallID = "tool_call_id"
        case title, kind, status, raw
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.objectValue else {
            throw DecodingError.typeMismatch(
                ToolCallPayload.self, .init(codingPath: decoder.codingPath, debugDescription: "not an object"))
        }
        self.init(object: object)
    }

    /// 编码成事件里的形式。`raw` 为 nil 时写成 null：省略的话解码时会把整个载荷当成原始内容，往返就不一致了。
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallID, forKey: .toolCallID)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encode(raw ?? .null, forKey: .raw)
    }
}

/// `agent.platform_tool_call`：`{call_id, name, arguments}`。
public struct PlatformToolCallPayload: Hashable, Codable, Sendable {
    public var callID: String
    public var name: String
    public var arguments: JSONValue?

    public init(callID: String, name: String, arguments: JSONValue? = nil) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case name, arguments
    }

    /// 平台工具的类别（按名字前缀）。
    public var category: PlatformToolCategory {
        PlatformToolCategory(toolName: name)
    }
}

/// 平台工具的类别：界面上显示成“平台工具：计划 / 产出物 / 委派 / 保险箱”。
public enum PlatformToolCategory: String, Hashable, Codable, Sendable {
    case plan, artifact, delegate, vault, computer, other

    public init(toolName name: String) {
        if name.hasPrefix("schedule_") || name.hasPrefix("plan_") {
            self = .plan
        } else if name.hasPrefix("artifact_") {
            self = .artifact
        } else if name == "delegate" || name.hasPrefix("delegate_") {
            self = .delegate
        } else if name.hasPrefix("vault_") {
            self = .vault
        } else if name.hasPrefix("computer_") || name.hasPrefix("desktop_") {
            self = .computer
        } else {
            self = .other
        }
    }
}

/// `agent.plan`：agent 的待办清单（ACP 的 plan，每次都是完整清单）。
public struct AgentPlanPayload: Hashable, Codable, Sendable {
    public var entries: [AgentPlanEntry]

    public init(entries: [AgentPlanEntry]) { self.entries = entries }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decodeIfPresent([AgentPlanEntry].self, forKey: .entries)) ?? []
    }
}

/// 待办清单的一项。
public struct AgentPlanEntry: Hashable, Codable, Sendable {
    public var content: String
    /// high / medium / low
    public var priority: String?
    /// pending / in_progress / completed
    public var status: ToolCallStatus?

    public init(content: String, priority: String? = nil, status: ToolCallStatus? = nil) {
        self.content = content
        self.priority = priority
        self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        status = try c.decodeIfPresent(ToolCallStatus.self, forKey: .status)
    }
}

/// `agent.permission_requested`：`{request_id, title, options, tool_call}`。
public struct PermissionRequestedPayload: Hashable, Codable, Sendable {
    public var requestID: String
    public var title: String?
    public var options: [ApprovalOption]
    public var toolCall: JSONValue?

    public init(requestID: String, title: String?, options: [ApprovalOption], toolCall: JSONValue? = nil) {
        self.requestID = requestID
        self.title = title
        self.options = options
        self.toolCall = toolCall
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case title, options
        case toolCall = "tool_call"
    }

    private struct Option: Decodable {
        var optionID: String
        var name: String?
        var kind: String?
        enum CodingKeys: String, CodingKey {
            case optionID = "option_id"
            case name, kind
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(String.self, forKey: .requestID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        let raw = (try? c.decodeIfPresent([Option].self, forKey: .options)) ?? []
        options = raw.map {
            ApprovalOption(
                id: $0.optionID, name: $0.name ?? $0.optionID, kind: ApprovalOptionKind(rawValue: $0.kind ?? ""))
        }
        toolCall = try c.decodeIfPresent(JSONValue.self, forKey: .toolCall)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encodeIfPresent(title, forKey: .title)
        let opts: [JSONValue] = options.map {
            ["option_id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind.rawValue)]
        }
        try c.encode(opts, forKey: .options)
        try c.encodeIfPresent(toolCall, forKey: .toolCall)
    }
}

/// `agent.permission_resolved`：`{request_id, option_id, by}`。`option_id` 为空表示放弃作答。
public struct PermissionResolvedPayload: Hashable, Codable, Sendable {
    public var requestID: String
    public var optionID: String?
    public var by: DecisionSource

    public init(requestID: String, optionID: String?, by: DecisionSource) {
        self.requestID = requestID
        self.optionID = optionID
        self.by = by
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case optionID = "option_id"
        case by
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(String.self, forKey: .requestID)
        optionID = try c.decodeIfPresent(String.self, forKey: .optionID)
        by = try c.decodeIfPresent(DecisionSource.self, forKey: .by) ?? .unknown("")
    }
}

/// `approval.decided`：用户在 App 里决定后服务端记的（`{approval_id, state, option_id}`）。
public struct ApprovalDecidedPayload: Hashable, Codable, Sendable {
    public var approvalID: ApprovalID
    public var state: ApprovalState
    public var optionID: String?

    public init(approvalID: ApprovalID, state: ApprovalState, optionID: String?) {
        self.approvalID = approvalID
        self.state = state
        self.optionID = optionID
    }

    enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id"
        case state
        case optionID = "option_id"
    }
}

/// `vault.requested`：`{request_id, name, purpose, fields}`。
public struct VaultRequestedPayload: Hashable, Codable, Sendable {
    public var requestID: VaultRequestID
    public var name: String
    /// agent 写的用途：显示时带“AI 生成”标识。
    public var purpose: String
    public var fields: [VaultField]

    public init(requestID: VaultRequestID, name: String, purpose: String, fields: [VaultField]) {
        self.requestID = requestID
        self.name = name
        self.purpose = purpose
        self.fields = fields
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case name, purpose, fields
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(VaultRequestID.self, forKey: .requestID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        fields = try c.decodeIfPresent([VaultField].self, forKey: .fields) ?? [.password]
    }
}

/// `vault.fulfilled` / `vault.declined`：`{request_id, name}`。
public struct VaultResolvedPayload: Hashable, Codable, Sendable {
    public var requestID: VaultRequestID
    public var name: String?

    public init(requestID: VaultRequestID, name: String? = nil) {
        self.requestID = requestID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case name
    }
}

/// `vault.used`：agent 这一轮用了哪些保险箱条目（`{names}`）。
public struct VaultUsedPayload: Hashable, Codable, Sendable {
    public var names: [String]

    public init(names: [String]) { self.names = names }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
    }
}

/// `run.state`：`{state, reason, attempt}`（流水线的根还有 `steps`，整棵停止时有 `tree`）。
public struct RunStatePayload: Hashable, Codable, Sendable {
    public var state: RunState
    public var reason: String?
    public var attempt: Int?
    /// 流水线开始等子运行时的步骤数。
    public var steps: Int?
    /// 整棵运行树一起停止。
    public var tree: Bool?

    public init(state: RunState, reason: String? = nil, attempt: Int? = nil, steps: Int? = nil, tree: Bool? = nil) {
        self.state = state
        self.reason = reason
        self.attempt = attempt
        self.steps = steps
        self.tree = tree
    }
}

/// `artifact.published`：`{artifact_id, name, version, size}`。
public struct ArtifactPublishedPayload: Hashable, Codable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case name, version, size
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artifactID = try c.decode(ArtifactID.self, forKey: .artifactID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }
}

/// `pipeline.step_started`：`{step, run_id, instance_id}`。
public struct PipelineStepStartedPayload: Hashable, Codable, Sendable {
    public var step: String
    public var runID: RunID
    public var instanceID: InstanceID

    public init(step: String, runID: RunID, instanceID: InstanceID) {
        self.step = step
        self.runID = runID
        self.instanceID = instanceID
    }

    enum CodingKeys: String, CodingKey {
        case step
        case runID = "run_id"
        case instanceID = "instance_id"
    }
}

/// `delegate.started`：`{child_run_id, instance_id, to, title}`。
public struct DelegateStartedPayload: Hashable, Codable, Sendable {
    public var childRunID: RunID
    public var instanceID: InstanceID
    /// 委派给谁（实例名）。
    public var to: String
    public var title: String?

    public init(childRunID: RunID, instanceID: InstanceID, to: String, title: String? = nil) {
        self.childRunID = childRunID
        self.instanceID = instanceID
        self.to = to
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case childRunID = "child_run_id"
        case instanceID = "instance_id"
        case to, title
    }
}

/// `plan.needs_confirmation`：`{plan_id, title, change}`。
public struct PlanNeedsConfirmationPayload: Hashable, Codable, Sendable {
    public var planID: PlanID
    public var title: String
    public var change: PlanChange

    public init(planID: PlanID, title: String, change: PlanChange) {
        self.planID = planID
        self.title = title
        self.change = change
    }

    enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case title, change
    }
}

/// `plan.cancelled`：agent 删掉了计划（`{plan_id, title}`）。
public struct PlanCancelledPayload: Hashable, Codable, Sendable {
    public var planID: PlanID
    public var title: String

    public init(planID: PlanID, title: String) {
        self.planID = planID
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case title
    }
}

/// `agent.turn_ended`：`{stop_reason}`。
public struct TurnEndedPayload: Hashable, Codable, Sendable {
    public var stopReason: StopReason?

    public init(stopReason: StopReason?) { self.stopReason = stopReason }

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
    }
}

/// `agent.error`：`{message}`。
public struct ErrorPayload: Hashable, Codable, Sendable {
    public var message: String

    public init(message: String) { self.message = message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// `agent.session_lost`：之前的会话接不回来，开了新会话（`{previous_session_id, reason}`）。
public struct SessionLostPayload: Hashable, Codable, Sendable {
    public var reason: String?

    public init(reason: String?) { self.reason = reason }
}

/// `agent.exited`：agent 进程退出（`{code, will_restart, restarts}`）。
public struct AgentExitedPayload: Hashable, Codable, Sendable {
    public var code: Int?
    public var willRestart: Bool
    public var restarts: Int

    public init(code: Int?, willRestart: Bool, restarts: Int) {
        self.code = code
        self.willRestart = willRestart
        self.restarts = restarts
    }

    enum CodingKeys: String, CodingKey {
        case code
        case willRestart = "will_restart"
        case restarts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(Int.self, forKey: .code)
        willRestart = try c.decodeIfPresent(Bool.self, forKey: .willRestart) ?? false
        restarts = try c.decodeIfPresent(Int.self, forKey: .restarts) ?? 0
    }
}

/// `run.log_truncated`：运行日志到上限，之后的输出不再记录（`{limit_bytes}`）。
public struct LogTruncatedPayload: Hashable, Codable, Sendable {
    public var limitBytes: Int?

    public init(limitBytes: Int?) { self.limitBytes = limitBytes }

    enum CodingKeys: String, CodingKey {
        case limitBytes = "limit_bytes"
    }
}
