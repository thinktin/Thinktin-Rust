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
/// - 审批卡片 `agent.permission_requested` 未决 → `agent.permission_resolved` 已决，一个运行里按
///   `(attempt, request_id)` 认（shim 每次尝试都从 `perm-1` 重新编号，docs/agent-integration.md 第 6 节）；
///   事件带 `approval_id` 时直接关联审批记录；`approval_state` 是 expired 的显示“已过期”；尝试比运行当前的小的、
///   运行已经结束的待处理卡片作废（平台把它们取消了）；
/// - `run.state` 更新这一组末尾的状态行；
/// - `seq` 不大于已处理的最大 `seq` 的事件当作重复丢掉；`reset()` 之后重新开始。
public struct ConversationReducer: Sendable {
    private var turns: [TurnState] = []
    private var turnIndex: [String: Int] = [:]
    /// 已处理的最大 `seq`。
    public private(set) var lastSeq: UInt64?
    /// 关联过的审批：审批 id → 哪一组的哪张卡片。
    private var approvalLinks: [ApprovalID: CardRef] = [:]

    /// 一张审批卡片在哪：组（运行）的键 + 组里的卡片键。
    private struct CardRef: Hashable, Sendable {
        var turnKey: String
        var card: ApprovalKey
    }

    public init(runs: [Run] = []) {
        upsert(runs: runs)
    }

    // MARK: 输入

    /// 加入或更新运行记录（用户消息、状态行用它）。运行记录的尝试次数、结束状态也会让旧的待处理审批卡片作废。
    public mutating func upsert(run: Run) {
        let key = run.id.rawValue
        if let i = turnIndex[key] {
            turns[i].run = run
            turns[i].supersedeStaleApprovals()
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
        switch event.payload {
        case .permissionRequested(let p):
            if let id = p.approvalID, let card = turns[t].cardKey(requestID: p.requestID, attempt: p.attempt) {
                linkCard(id, turn: t, card: card)
            }
        case .permissionResolved(let p):
            if let id = p.approvalID, let card = turns[t].cardKey(requestID: p.requestID, attempt: p.attempt) {
                linkCard(id, turn: t, card: card)
            }
        case .approvalDecided(let p):
            applyDecision(p, turn: t)
        default:
            break
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

    /// 关联审批记录（`approvals()`、`getApproval` 的结果）。卡片已经按事件里的 `approval_id` 关联上的不再动。
    ///
    /// - 审批有请求 id（11.8）：按 `(attempt, request_id)` 对上同一运行里的卡片（`attempt` 为 0 的老记录取这个请求 id 的
    ///   最后一张卡片）；
    /// - 老的审批（没有请求 id）：同一运行里按创建顺序对上未关联的卡片，标题相同的优先；未决的审批只配未决的卡片；
    ///   按预授权策略决定的卡片没有审批记录，不参与。
    ///
    /// 关联上之后卡片有 `approvalID`，可以调 `decideApproval`；审批已经有结果、卡片还没有（或只是推断作废的）时补上结果。
    public mutating func link(approvals: [Approval]) {
        for approval in approvals.sorted(by: { $0.createdAt < $1.createdAt }) where approvalLinks[approval.id] == nil {
            guard let t = turnIndex[approval.runID.rawValue], let card = candidateCard(for: approval, in: t) else {
                continue
            }
            linkCard(approval.id, turn: t, card: card)
            turns[t].apply(record: approval, to: card)
        }
    }

    /// 审批记录对应这一组里的哪张卡片（还没关联别的审批的）。
    private func candidateCard(for approval: Approval, in t: Int) -> ApprovalKey? {
        let turn = turns[t]
        func unlinked(_ key: ApprovalKey) -> Bool { turn.approvalCard(key)?.approvalID == nil }
        if !approval.requestID.isEmpty {
            let key: ApprovalKey?
            if approval.attempt > 0 {
                key = turn.cardKey(requestID: approval.requestID, attempt: approval.attempt)
            } else {
                key = turn.approvalOrder.last { $0.requestID == approval.requestID }
            }
            return key.flatMap { unlinked($0) ? $0 : nil }
        }
        let candidates = turn.approvalOrder.filter { key in
            guard let card = turn.approvalCard(key), card.approvalID == nil else { return false }
            if card.resolution?.by == .policy { return false }
            return !approval.isPending || card.isPending
        }
        return candidates.first { turn.approvalCard($0)?.title == approval.title } ?? candidates.first
    }

    // MARK: 输出

    /// 按运行分组的结果。只有不显示的事件的组（`agent.ready`、不认识的 kind）不出现。
    public var conversationTurns: [ConversationTurn] {
        orderedTurns().filter(\.hasContent).map { $0.render() }
    }

    /// 平铺的对话列表（按组的顺序）。
    public var items: [ConversationItem] {
        orderedTurns().flatMap { $0.render().items }
    }

    /// 有运行还在输出（最后一个有内容的组）。
    public var isStreaming: Bool {
        orderedTurns().last(where: \.hasContent)?.isStreaming ?? false
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
        // 只有不显示的事件的运行组不算“隔开”。
        if let last = orderedTurns().last(where: { $0.runID == nil || $0.hasContent }), last.runID == nil,
            let i = turnIndex[last.key]
        {
            return i
        }
        appendTurn(TurnState(key: "none-\(event.seq)", runID: nil, run: nil, firstAt: event.createdAt))
        return turns.count - 1
    }

    /// 卡片关联上审批记录。事件说的为准：这个审批之前按猜测关联到了别的卡片上时，那张卡片解除关联。
    private mutating func linkCard(_ approvalID: ApprovalID, turn t: Int, card: ApprovalKey) {
        let ref = CardRef(turnKey: turns[t].key, card: card)
        if let old = approvalLinks[approvalID], old != ref, let ot = turnIndex[old.turnKey] {
            turns[ot].setApprovalID(nil, for: old.card)
        }
        approvalLinks[approvalID] = ref
        turns[t].setApprovalID(approvalID, for: card)
    }

    /// `approval.decided`：按关联的审批 id 找卡片；还没关联过时按事件里的 `(attempt, request_id)`（11.8）；老的服务端没有
    /// 请求 id 时，这个运行里只有一张未决、未关联的卡片就是它（agent 一次只等一个审批）。对不上就不改，等
    /// `permission_resolved`。
    private mutating func applyDecision(_ p: ApprovalDecidedPayload, turn t: Int) {
        if let ref = approvalLinks[p.approvalID], let lt = turnIndex[ref.turnKey] {
            turns[lt].resolveApproval(ref.card, optionID: p.optionID, by: .user, state: p.state)
            return
        }
        let card: ApprovalKey?
        if let requestID = p.requestID {
            card = turns[t].cardKey(requestID: requestID, attempt: p.attempt)
        } else {
            let pending = turns[t].approvalOrder.filter { key in
                guard let card = turns[t].approvalCard(key) else { return false }
                return card.isPending && card.approvalID == nil
            }
            card = pending.count == 1 ? pending.first : nil
        }
        guard let card, turns[t].approvalCard(card)?.approvalID == nil else { return }
        linkCard(p.approvalID, turn: t, card: card)
        turns[t].resolveApproval(card, optionID: p.optionID, by: .user, state: p.state)
    }
}

/// 一个运行里一张审批卡片的键：第几次尝试（0 是不知道）+ shim 的请求 id。
private struct ApprovalKey: Hashable, Sendable {
    var attempt: Int
    var requestID: String
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
    var approvalIndex: [ApprovalKey: Int] = [:]
    /// 审批卡片的出现顺序。
    var approvalOrder: [ApprovalKey] = []
    /// 结果是推断出来的卡片（旧的尝试、运行结束时没处理的，当作被取消）：之后事件或审批记录给了真正的结果就换掉。
    var inferredResolutions: Set<ApprovalKey> = []
    /// 最近一条 `run.state` 说的第几次尝试（事件里的审批没带 `attempt` 时用它）。
    var eventAttempt: Int?
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

    /// 有要显示的东西：运行记录（用户消息）、输出、状态，或者正在输出（界面显示“输入中”）。
    var hasContent: Bool {
        run != nil || !entries.isEmpty || status != nil || isStreaming
    }

    /// 某张审批卡片。
    func approvalCard(_ key: ApprovalKey) -> ApprovalCard? {
        guard let i = approvalIndex[key], case .approval(let card) = entries[i].content else { return nil }
        return card
    }

    /// 事件里的审批属于第几次尝试：带了 `attempt` 就用它，否则是这之前最近一条 `run.state` 的，都没有是 0（不知道）。
    func attempt(of eventAttempt: Int?) -> Int {
        eventAttempt ?? self.eventAttempt ?? 0
    }

    /// 已有的卡片：先按 `(attempt, request_id)` 找；找不到时，同一个请求 id、尝试不知道（0）的卡片也算（老数据和新数据混着时）。
    func cardKey(requestID: String, attempt: Int?) -> ApprovalKey? {
        let key = ApprovalKey(attempt: self.attempt(of: attempt), requestID: requestID)
        if approvalIndex[key] != nil { return key }
        let unknown = ApprovalKey(attempt: 0, requestID: requestID)
        if approvalIndex[unknown] != nil { return unknown }
        return nil
    }

    /// 运行当前是第几次尝试（`run.state` 事件和运行记录里大的那个）；0 是不知道。
    var currentAttempt: Int {
        max(eventAttempt ?? 0, run?.attempt ?? 0)
    }

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
            let card = ApprovalKey(attempt: attempt(of: p.attempt), requestID: p.requestID)
            if let i = approvalIndex[card], case .approval(var existing) = entries[i].content {
                existing.title = p.title ?? existing.title
                if !p.options.isEmpty { existing.options = p.options }
                existing.toolCall = p.toolCall ?? existing.toolCall
                entries[i].content = .approval(existing)
            } else {
                addApprovalCard(
                    card, event: event,
                    ApprovalCard(
                        requestID: p.requestID, attempt: card.attempt, title: p.title, options: p.options,
                        toolCall: p.toolCall))
            }
            // 缓存里的旧尝试（运行记录已经是下一次了）、已经结束的运行：这张卡片一出现就作废。
            supersedeStaleApprovals()
        case .permissionResolved(let p):
            let card: ApprovalKey
            if let existing = cardKey(requestID: p.requestID, attempt: p.attempt) {
                card = existing
            } else {
                // 按预授权策略直接决定的请求没有 requested 事件，只有 resolved：补一张已决的卡片。
                card = ApprovalKey(attempt: attempt(of: p.attempt), requestID: p.requestID)
                addApprovalCard(
                    card, event: event, ApprovalCard(requestID: p.requestID, attempt: card.attempt, title: nil, options: []))
            }
            resolveApproval(card, optionID: p.optionID, by: p.by, state: p.approvalState)
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
            if let attempt = p.attempt { eventAttempt = max(eventAttempt ?? 0, attempt) }
            // 新的尝试开始了（旧尝试没处理的审批被平台取消了）、运行结束了：待处理的旧卡片作废。
            supersedeStaleApprovals()
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
            let card = ChildRunCard(
                runID: p.runID, instanceID: p.instanceID, title: p.step, origin: .pipelineStep(p.step))
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
            append(
                id: "seq-\(event.seq)", event: event, .systemNotice(SystemNotice(kind: .agentError, message: p.message))
            )
        case .sessionLost(let p):
            append(
                id: "seq-\(event.seq)", event: event, .systemNotice(SystemNotice(kind: .sessionLost, message: p.reason))
            )
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

    /// 加一张审批卡片（id 带上尝试：同一个运行里不同尝试的 `perm-1` 是不同的卡片）。
    private mutating func addApprovalCard(_ card: ApprovalKey, event: InstanceEvent, _ content: ApprovalCard) {
        approvalIndex[card] = entries.count
        approvalOrder.append(card)
        append(id: "approval-\(key)-\(card.attempt)-\(card.requestID)", event: event, .approval(content))
    }

    mutating func setApprovalID(_ approvalID: ApprovalID?, for card: ApprovalKey) {
        guard let i = approvalIndex[card], case .approval(var content) = entries[i].content else { return }
        content.approvalID = approvalID
        entries[i].content = .approval(content)
    }

    /// 写上审批的结果。`state` 是审批记录的结果（`approval_state`、`approval.decided` 的 `state`）：expired 的一律算超时
    /// （平台判的超时 shim 回的是 `by: user`），cancelled 的算取消。
    ///
    /// 已经有结果的不再改（`permission_resolved` 和 `approval.decided` 都会来，以先到的为准），只补上选项、记录的结果；
    /// 之前的结果是推断的（`inferred`，旧尝试、运行结束时作废的）就整个换掉。推断的结果不覆盖任何已有的结果。
    mutating func resolveApproval(
        _ card: ApprovalKey, optionID: String?, by: DecisionSource, state: ApprovalState?, inferred: Bool = false
    ) {
        guard let i = approvalIndex[card], case .approval(var content) = entries[i].content else { return }
        let option = optionID.flatMap { id in content.options.first { $0.id == id } }
        if var existing = content.resolution, !(inferredResolutions.contains(card) && !inferred) {
            guard !inferred else { return }
            var changed = false
            if existing.optionID == nil, let optionID {
                existing.optionID = optionID
                existing.optionName = option?.name
                existing.isApproved = option?.kind.isAllow ?? existing.isApproved
                changed = true
            }
            if existing.state == nil, let state {
                existing.state = state
                if state == .expired { existing.by = .timeout }
                changed = true
            }
            if changed {
                content.resolution = existing
                entries[i].content = .approval(content)
            }
            return
        }
        let source: DecisionSource
        switch state {
        case .expired?: source = .timeout
        case .cancelled?: source = .cancelled
        default: source = by
        }
        let approved = option?.kind.isAllow ?? (state == .approved)
        content.resolution = ApprovalCard.Resolution(
            optionID: optionID, optionName: option?.name, by: source, isApproved: approved, state: state)
        entries[i].content = .approval(content)
        if inferred {
            inferredResolutions.insert(card)
        } else {
            inferredResolutions.remove(card)
        }
    }

    /// 一次尝试结束时它没处理的审批会被取消（docs/agent-integration.md 第 6 节）：尝试比运行当前的小的待处理卡片作废；
    /// 运行已经结束的，待处理的卡片也都作废（平台把它们取消了）。尝试不知道（0）的只在运行结束时作废。
    mutating func supersedeStaleApprovals() {
        let current = currentAttempt
        let ended = effectiveState?.state.isTerminal ?? false
        for card in approvalOrder {
            guard approvalCard(card)?.isPending == true else { continue }
            guard ended || (card.attempt > 0 && card.attempt < current) else { continue }
            resolveApproval(card, optionID: nil, by: .cancelled, state: .cancelled, inferred: true)
        }
    }

    /// 审批记录（`approvals()`、`getApproval`）补到卡片上：选项、结果（卡片还没结果、或者只是推断作废的时候）。
    mutating func apply(record approval: Approval, to card: ApprovalKey) {
        guard let i = approvalIndex[card], case .approval(var content) = entries[i].content else { return }
        if content.options.isEmpty {
            content.options = approval.options
            entries[i].content = .approval(content)
        }
        let by: DecisionSource
        switch approval.state {
        case .pending, .unknown: return
        case .approved, .rejected: by = .user
        case .expired: by = .timeout
        case .cancelled: by = .cancelled
        }
        resolveApproval(card, optionID: approval.decidedOption, by: by, state: approval.state)
    }

    private mutating func setVaultStatus(_ p: VaultResolvedPayload, _ status: VaultRequestStatus, event: InstanceEvent)
    {
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
            items.append(
                ConversationItem(
                    id: "run-\(key)-prompt", runID: runID, createdAt: run.createdAt, content: .userMessage(message)))
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
            items.append(
                ConversationItem(id: "run-\(key)-status", runID: runID, createdAt: at, content: .runStatus(line)))
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
