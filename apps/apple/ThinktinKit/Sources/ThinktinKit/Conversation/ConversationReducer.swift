import Foundation

/// 把一个实例的事件流归并成对话（docs/ios.md 第 5 节）。可以增量喂事件：
///
/// ```swift
/// var reducer = ConversationReducer(runs: cachedRuns)
/// reducer.apply(cachedEvents)        // 先显示缓存
/// reducer.apply(event)               // 事件流来一条喂一条
/// reducer.link(approvals: pending)   // 关联审批记录，卡片上才能决定
/// list = reducer.items
/// ```
///
/// 规则：
/// - 按运行分组，组按运行的创建时间（运行还没加载时按第一条事件的时间）排序；
/// - 连续的 `agent.message`（中间没有别的显示项）拼成一段，`agent.thought` 同理；
/// - 工具调用按 `tool_call_id` 合并后续的 `agent.tool_call_update`；
/// - 审批卡片 `agent.permission_requested` 未决 → `agent.permission_resolved` 已决；
/// - `run.state` 更新这一组末尾的状态行；
/// - `seq` 不大于已处理的最大 `seq` 的事件当作重复丢掉；`reset()` 之后重新开始。
public struct ConversationReducer: Sendable {
    private var turns: [TurnState] = []
    private var turnIndex: [String: Int] = [:]
    /// 已处理的最大 `seq`。
    public private(set) var lastSeq: UInt64?
    /// 关联过的审批：`运行 id|request_id` → 审批 id。
    private var approvalLinks: [String: ApprovalID] = [:]

    public init(runs: [Run] = []) {
        upsert(runs: runs)
    }

    // MARK: 输入

    /// 加入或更新运行记录（用户消息、状态行用它）。
    public mutating func upsert(run: Run) {
        let key = run.id.rawValue
        if let i = turnIndex[key] {
            turns[i].run = run
        } else {
            appendTurn(TurnState(key: key, runID: run.id, run: run, firstAt: run.createdAt))
        }
    }

    public mutating func upsert(runs: [Run]) {
        for run in runs.sorted(by: { $0.createdAt < $1.createdAt }) {
            upsert(run: run)
        }
    }

    /// 喂一条事件。返回是否用上了（重复的、比已处理的旧的返回 false）。
    @discardableResult
    public mutating func apply(_ event: InstanceEvent) -> Bool {
        if let last = lastSeq, event.seq <= last { return false }
        lastSeq = event.seq
        let t = turnFor(event)
        turns[t].apply(event)
        if event.kind == .approvalDecided, case .approvalDecided(let p) = event.payload {
            applyDecision(p)
        }
        return true
    }

    public mutating func apply(_ events: [InstanceEvent]) {
        for e in events.sorted(by: { $0.seq < $1.seq }) {
            apply(e)
        }
    }

    /// 事件流 `on_reset`：本地的事件作废（运行记录保留），之后重新喂。
    public mutating func reset() {
        let runs = turns.compactMap(\.run)
        turns = []
        turnIndex = [:]
        lastSeq = nil
        approvalLinks = [:]
        upsert(runs: runs)
    }

    /// 关联审批记录（`approvals()` 的结果）：同一运行里按创建顺序对上未关联的审批卡片，标题相同的优先。
    /// 关联上之后卡片有 `approvalID`，可以调 `decideApproval`；审批已经有结果、卡片还没有时补上结果。
    public mutating func link(approvals: [Approval]) {
        let linked = Set(approvalLinks.values)
        let byRun = Dictionary(grouping: approvals.filter { !linked.contains($0.id) }, by: \.runID)
        for (runID, list) in byRun {
            guard let t = turnIndex[runID.rawValue] else { continue }
            var remaining = list.sorted { $0.createdAt < $1.createdAt }
            for requestID in turns[t].approvalOrder {
                guard let entry = turns[t].approvalIndex[requestID],
                    case .approval(var card) = turns[t].entries[entry].content, card.approvalID == nil,
                    !remaining.isEmpty
                else { continue }
                let pick = remaining.firstIndex { $0.title == card.title } ?? 0
                let approval = remaining.remove(at: pick)
                card.approvalID = approval.id
                if card.resolution == nil, let resolution = Self.resolution(from: approval, card: card) {
                    card.resolution = resolution
                }
                if card.options.isEmpty { card.options = approval.options }
                turns[t].entries[entry].content = .approval(card)
                approvalLinks["\(runID.rawValue)|\(requestID)"] = approval.id
            }
        }
    }

    // MARK: 输出

    /// 按运行分组的结果。
    public var conversationTurns: [ConversationTurn] {
        orderedTurns().map { $0.render() }
    }

    /// 平铺的对话列表（按组的顺序）。
    public var items: [ConversationItem] {
        orderedTurns().flatMap { $0.render().items }
    }

    /// 有运行还在输出（最后一组）。
    public var isStreaming: Bool {
        orderedTurns().last?.isStreaming ?? false
    }

    /// 还没决定的审批卡片（已关联的才能直接决定）。
    public var pendingApprovals: [ApprovalCard] {
        items.compactMap {
            if case .approval(let card) = $0.content, card.isPending { return card }
            return nil
        }
    }

    // MARK: 内部

    private func orderedTurns() -> [TurnState] {
        turns.enumerated()
            .sorted { a, b in
                let (da, db) = (a.element.sortDate, b.element.sortDate)
                return da != db ? da < db : a.offset < b.offset
            }
            .map(\.element)
    }

    private mutating func appendTurn(_ turn: TurnState) {
        turnIndex[turn.key] = turns.count
        turns.append(turn)
    }

    /// 事件属于哪一组：有运行 id 就是那个运行；没有的话接在最后一个“无运行”组后面（紧挨着时），否则新开一组。
    private mutating func turnFor(_ event: InstanceEvent) -> Int {
        if let runID = event.runID {
            if let i = turnIndex[runID.rawValue] { return i }
            appendTurn(TurnState(key: runID.rawValue, runID: runID, run: nil, firstAt: event.createdAt))
            return turns.count - 1
        }
        if let last = orderedTurns().last, last.runID == nil, let i = turnIndex[last.key] {
            return i
        }
        appendTurn(TurnState(key: "none-\(event.seq)", runID: nil, run: nil, firstAt: event.createdAt))
        return turns.count - 1
    }

    private mutating func applyDecision(_ p: ApprovalDecidedPayload) {
        guard let link = approvalLinks.first(where: { $0.value == p.approvalID }) else { return }
        let parts = link.key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let t = turnIndex[parts[0]] else { return }
        turns[t].resolveApproval(requestID: parts[1], optionID: p.optionID, by: .user, state: p.state)
    }

    private static func resolution(from approval: Approval, card: ApprovalCard) -> ApprovalCard.Resolution? {
        let by: DecisionSource
        switch approval.state {
        case .pending: return nil
        case .approved, .rejected: by = .user
        case .expired: by = .timeout
        case .cancelled: by = .cancelled
        case .unknown: return nil
        }
        return ApprovalCard.Resolution(
            optionID: nil, optionName: nil, by: by, isApproved: approval.state == .approved)
    }
}

/// 一组（一个运行）的归并状态。
private struct TurnState: Sendable {
    let key: String
    let runID: RunID?
    var run: Run?
    let firstAt: Date
    /// agent 的输出（不含用户消息和状态行）。
    var entries: [ConversationItem] = []
    var toolIndex: [String: Int] = [:]
    var approvalIndex: [String: Int] = [:]
    /// 审批卡片的出现顺序（request_id）。
    var approvalOrder: [String] = []
    var vaultIndex: [VaultRequestID: Int] = [:]
    var agentPlanIndex: Int?
    var status: RunStatePayload?
    var statusAt: Date?
    var streaming = false
    var turnEnded = false
    var lastUsage: JSONValue?

    init(key: String, runID: RunID?, run: Run?, firstAt: Date) {
        self.key = key
        self.runID = runID
        self.run = run
        self.firstAt = firstAt
    }

    var sortDate: Date { run?.createdAt ?? firstAt }

    /// 当前的运行状态：运行记录已经结束时以它为准，否则以最新的 `run.state` 事件为准。
    var effectiveState: (state: RunState, reason: String?, attempt: Int?)? {
        if let run, run.state.isTerminal || status == nil {
            return (run.state, run.stateReason ?? status?.reason, run.attempt)
        }
        if let s = status { return (s.state, s.reason, s.attempt ?? run?.attempt) }
        return nil
    }

    var isStreaming: Bool {
        guard streaming, !turnEnded else { return false }
        if let s = effectiveState?.state, s.isTerminal { return false }
        return true
    }

    mutating func apply(_ event: InstanceEvent) {
        switch event.payload {
        case .message(let p):
            markActive()
            appendText(p.text, event: event, thought: false)
        case .thought(let p):
            markActive()
            appendText(p.text, event: event, thought: true)
        case .toolCall(let p), .toolCallUpdate(let p):
            markActive()
            upsertToolCall(p, isUpdate: event.kind == .toolCallUpdate, event: event)
        case .platformToolCall(let p):
            markActive()
            let id = "ptool-\(key)-\(p.callID)"
            let card = ToolCallCard(
                toolCallID: p.callID, title: p.name, raw: p.arguments, platformCategory: p.category)
            if let i = toolIndex["platform:\(p.callID)"] {
                entries[i].content = .toolCall(card)
            } else {
                toolIndex["platform:\(p.callID)"] = entries.count
                append(id: id, event: event, .toolCall(card))
            }
        case .agentPlan(let p):
            let card = AgentPlanCard(entries: p.entries, isAIGenerated: event.isAIGenerated)
            if let i = agentPlanIndex {
                entries[i].content = .agentPlan(card)
            } else {
                agentPlanIndex = entries.count
                append(id: "plan-\(key)", event: event, .agentPlan(card))
            }
        case .permissionRequested(let p):
            if let i = approvalIndex[p.requestID], case .approval(var card) = entries[i].content {
                card.title = p.title ?? card.title
                if !p.options.isEmpty { card.options = p.options }
                card.toolCall = p.toolCall ?? card.toolCall
                entries[i].content = .approval(card)
            } else {
                approvalIndex[p.requestID] = entries.count
                approvalOrder.append(p.requestID)
                let card = ApprovalCard(requestID: p.requestID, title: p.title, options: p.options, toolCall: p.toolCall)
                append(id: "approval-\(key)-\(p.requestID)", event: event, .approval(card))
            }
        case .permissionResolved(let p):
            if approvalIndex[p.requestID] == nil {
                // 按预授权策略直接决定的请求没有 requested 事件，只有 resolved：补一张已决的卡片。
                approvalIndex[p.requestID] = entries.count
                approvalOrder.append(p.requestID)
                let card = ApprovalCard(requestID: p.requestID, title: nil, options: [])
                append(id: "approval-\(key)-\(p.requestID)", event: event, .approval(card))
            }
            resolveApproval(requestID: p.requestID, optionID: p.optionID, by: p.by, state: nil)
        case .approvalDecided:
            break  // 由 ConversationReducer 按关联的审批 id 处理
        case .vaultRequested(let p):
            let card = VaultRequestCard(requestID: p.requestID, name: p.name, purpose: p.purpose, fields: p.fields)
            if let i = vaultIndex[p.requestID] {
                entries[i].content = .vaultRequest(card)
            } else {
                vaultIndex[p.requestID] = entries.count
                append(id: "vault-\(p.requestID.rawValue)", event: event, .vaultRequest(card))
            }
        case .vaultFulfilled(let p):
            setVaultStatus(p, .fulfilled, event: event)
        case .vaultDeclined(let p):
            setVaultStatus(p, .declined, event: event)
        case .vaultUsed(let p):
            append(id: "seq-\(event.seq)", event: event, .systemNotice(SystemNotice(kind: .vaultUsed(p.names))))
        case .runState(let p):
            status = p
            statusAt = event.createdAt
            switch p.state {
            case .running:
                // 回到运行中（开始、审批通过、重试）：这一轮接着输出。
                streaming = true
                turnEnded = false
            case .starting:
                turnEnded = false
            default:
                // 排队、等待、退避、结束：没在输出。
                streaming = false
            }
        case .artifactPublished(let p):
            let card = ArtifactCard(artifactID: p.artifactID, name: p.name, version: p.version, size: p.size)
            append(id: "seq-\(event.seq)", event: event, .artifact(card))
        case .pipelineStepStarted(let p):
            let card = ChildRunCard(runID: p.runID, instanceID: p.instanceID, title: p.step, origin: .pipelineStep(p.step))
            append(id: "seq-\(event.seq)", event: event, .childRun(card))
        case .delegateStarted(let p):
            let card = ChildRunCard(
                runID: p.childRunID, instanceID: p.instanceID, title: p.title ?? p.to, origin: .delegate(to: p.to))
            append(id: "seq-\(event.seq)", event: event, .childRun(card))
        case .planNeedsConfirmation(let p):
            let card = PlanActivityCard(planID: p.planID, title: p.title, activity: .needsConfirmation(p.change))
            append(id: "seq-\(event.seq)", event: event, .planActivity(card))
        case .planCancelled(let p):
            let card = PlanActivityCard(planID: p.planID, title: p.title, activity: .cancelled)
            append(id: "seq-\(event.seq)", event: event, .planActivity(card))
        case .turnEnded:
            turnEnded = true
            streaming = false
        case .agentError(let p):
            append(id: "seq-\(event.seq)", event: event, .systemNotice(SystemNotice(kind: .agentError, message: p.message)))
        case .sessionLost(let p):
            append(id: "seq-\(event.seq)", event: event, .systemNotice(SystemNotice(kind: .sessionLost, message: p.reason)))
        case .agentExited(let p):
            let notice = SystemNotice(
                kind: .agentExited(willRestart: p.willRestart), message: p.code.map { "exit code \($0)" })
            append(id: "seq-\(event.seq)", event: event, .systemNotice(notice))
        case .logTruncated(let p):
            let notice = SystemNotice(kind: .logTruncated, message: p.limitBytes.map { "limit \($0) bytes" })
            append(id: "seq-\(event.seq)", event: event, .systemNotice(notice))
        case .other(let raw):
            switch event.kind {
            case .turnStarted:
                streaming = true
                turnEnded = false
            case .agentUsage:
                lastUsage = raw?["raw"] ?? raw
            default:
                break  // agent.ready、agent.update、不认识的种类：不显示
            }
        }
    }

    /// 有输出说明这一轮在进行（除非运行已经结束）。
    private mutating func markActive() {
        if let s = effectiveState?.state, s.isTerminal { return }
        if !turnEnded { streaming = true }
    }

    private mutating func append(id: String, event: InstanceEvent, _ content: ConversationItem.Content) {
        entries.append(ConversationItem(id: id, runID: runID, createdAt: event.createdAt, content: content))
    }

    private mutating func appendText(_ text: String, event: InstanceEvent, thought: Bool) {
        if let last = entries.indices.last {
            switch entries[last].content {
            case .assistantText(var t) where !thought:
                t.text += text
                entries[last].content = .assistantText(t)
                return
            case .thought(var t) where thought:
                t.text += text
                entries[last].content = .thought(t)
                return
            default:
                break
            }
        }
        let content: ConversationItem.Content =
            thought
            ? .thought(Thought(text: text, isAIGenerated: event.isAIGenerated))
            : .assistantText(AssistantText(text: text, isAIGenerated: event.isAIGenerated))
        append(id: "seq-\(event.seq)", event: event, content)
    }

    private mutating func upsertToolCall(_ p: ToolCallPayload, isUpdate: Bool, event: InstanceEvent) {
        if let i = toolIndex[p.toolCallID], case .toolCall(var card) = entries[i].content {
            if let title = p.title, !title.isEmpty { card.title = title }
            if let kind = p.kind { card.kind = kind }
            if let status = p.status { card.status = status }
            if let raw = p.raw {
                card.raw = card.raw.map { $0.merging(raw) } ?? raw
            }
            entries[i].content = .toolCall(card)
            return
        }
        // 没见过的工具调用（更新先到、或者 reset 之后）：直接建卡片。
        let card = ToolCallCard(
            toolCallID: p.toolCallID, title: p.title ?? "", kind: p.kind,
            status: p.status ?? (isUpdate ? nil : .pending), raw: p.raw)
        toolIndex[p.toolCallID] = entries.count
        append(id: "tool-\(key)-\(p.toolCallID)", event: event, .toolCall(card))
    }

    mutating func resolveApproval(requestID: String, optionID: String?, by: DecisionSource, state: ApprovalState?) {
        guard let i = approvalIndex[requestID], case .approval(var card) = entries[i].content else { return }
        // 已经有结果的不再改（permission_resolved 和 approval.decided 都会来，以先到的为准，但补上选项名）。
        let option = optionID.flatMap { id in card.options.first { $0.id == id } }
        if var existing = card.resolution {
            if existing.optionID == nil, let optionID {
                existing.optionID = optionID
                existing.optionName = option?.name
                existing.isApproved = option?.kind.isAllow ?? existing.isApproved
                card.resolution = existing
                entries[i].content = .approval(card)
            }
            return
        }
        let approved = option?.kind.isAllow ?? (state == .approved)
        card.resolution = ApprovalCard.Resolution(
            optionID: optionID, optionName: option?.name, by: by, isApproved: approved)
        entries[i].content = .approval(card)
    }

    private mutating func setVaultStatus(_ p: VaultResolvedPayload, _ status: VaultRequestStatus, event: InstanceEvent) {
        if let i = vaultIndex[p.requestID], case .vaultRequest(var card) = entries[i].content {
            card.status = status
            entries[i].content = .vaultRequest(card)
        } else {
            // 请求事件已经过了保留期：只显示结果。
            let card = VaultRequestCard(
                requestID: p.requestID, name: p.name ?? "", purpose: "", fields: [], status: status)
            vaultIndex[p.requestID] = entries.count
            append(id: "vault-\(p.requestID.rawValue)", event: event, .vaultRequest(card))
        }
    }

    func render() -> ConversationTurn {
        var items: [ConversationItem] = []
        if let run {
            let message = UserMessage(text: run.prompt, source: run.source, planID: run.planID, stepKey: run.stepKey)
            items.append(ConversationItem(id: "run-\(key)-prompt", runID: runID, createdAt: run.createdAt, content: .userMessage(message)))
        }
        let streaming = isStreaming
        for (i, item) in entries.enumerated() {
            var item = item
            let isLast = i == entries.count - 1
            switch item.content {
            case .assistantText(var t):
                t.isStreaming = streaming && isLast
                item.content = .assistantText(t)
            case .thought(var t):
                t.isStreaming = streaming && isLast
                item.content = .thought(t)
            default:
                break
            }
            items.append(item)
        }
        let state = effectiveState
        if let state {
            let line = RunStatusLine(
                state: state.state, reason: state.reason, attempt: state.attempt, tokensUsed: run?.tokensUsed,
                error: run?.error, startedAt: run?.startedAt, finishedAt: run?.finishedAt)
            let at = statusAt ?? run?.finishedAt ?? run?.startedAt ?? run?.createdAt ?? firstAt
            items.append(ConversationItem(id: "run-\(key)-status", runID: runID, createdAt: at, content: .runStatus(line)))
        }
        return ConversationTurn(
            id: key, runID: runID, run: run, items: items, state: state?.state, isStreaming: streaming,
            lastUsage: lastUsage)
    }
}

/// 一次性归并（纯函数）：给定运行和事件，得到对话列表。
public enum Conversation {
    public static func build(runs: [Run], events: [InstanceEvent], approvals: [Approval] = []) -> [ConversationItem] {
        var reducer = ConversationReducer(runs: runs)
        reducer.apply(events)
        reducer.link(approvals: approvals)
        return reducer.items
    }

    public static func turns(runs: [Run], events: [InstanceEvent], approvals: [Approval] = []) -> [ConversationTurn] {
        var reducer = ConversationReducer(runs: runs)
        reducer.apply(events)
        reducer.link(approvals: approvals)
        return reducer.conversationTurns
    }
}
