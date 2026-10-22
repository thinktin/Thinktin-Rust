import Foundation
import Observation

/// 一个实例的对话页（WBS 12.5）= 运行时间线：用户消息取自 `Run.prompt`，agent 的输出取自事件流，按运行分组
/// （`ConversationReducer`，docs/ios.md 第 5 节）。
///
/// - 打开页面先显示缓存：`cachedRuns` 和缓存里最后一屏事件（`latestCachedEvents`），再拉 `runs()`；之后 `subscribe`
///   （`afterSeq` 是已经显示的最后一条）。事件流回调在后台线程，先进 `ConversationStreamRelay`，主线程上按批归并、刷新一次。
/// - 往前翻（`loadOlder()`）：先翻缓存里更早的事件（`cachedEventsBefore`），缓存翻到头了再翻更早的运行（`olderRuns`，
///   这些运行只有任务和结果，`historyNote(for:)` 标“过程记录已超过保留期”）。还没翻到的、比最早一条事件还早的运行先不显示。
/// - `onReset`：本地事件作废，归并状态清空（运行记录保留），从缓存重新读，再重新拉运行（服务端会把保留期内的事件补发过来）。
/// - 进后台 `pause()` 停订阅，回前台 `resume()` 先补上缓存里新到的事件再续订；账号解冻后 `resubscribe()`。
/// - 事件里出现没见过的运行（计划触发、别的设备发的）、运行结束时，拉一次运行记录（摘要、token、结束时间）。
/// - 审批卡片的状态以审批记录为准：打开页面时对卡片上的审批 id 查一次 `getApproval`（每个只查一次），还有没关联上的待处理
///   卡片时拉 `approvals()`；保险箱请求、计划标题也各拉一次（`vaultRequests(all:)`、`plans(instanceID:)`）。
///
/// `focusRunID` 不为 nil 时是运行详情里的“只看本次过程”：只归并这一个运行的事件，没有输入框。
///
/// 发消息、停止、密码拦截、审批、保险箱请求在 `ConversationModel+Actions.swift`。
@Observable @MainActor
public final class ConversationModel {
    /// 打开页面时、往前翻时一次读缓存里的几条事件。
    public nonisolated static let eventPageSize = 200
    /// 一次拉几个运行。
    public nonisolated static let runsPageSize = 30
    /// “只看本次过程”最多从缓存里找多少条事件（缓存每个实例最多留 2000 条）。
    public nonisolated static let focusEventLimit = 2000
    /// 一条消息最多几个字符（服务端去掉首尾空白后按 Unicode 标量数，crates/gateway/src/routes/runs.rs）。
    public nonisolated static let maxPromptLength = 32_000
    /// 离上限还剩这么多时显示字数。
    public nonisolated static let lengthCounterThreshold = 2_000
    /// 事件默认保留 30 天（docs/architecture-v3.md 4.8）。
    public nonisolated static let eventRetention: TimeInterval = 30 * 86400

    public let instanceID: InstanceID
    /// 只看这一个运行（运行详情的“只看本次过程”）；nil 是整个实例的对话。
    public let focusRunID: RunID?

    // MARK: 时间线

    /// 按运行分组的对话。
    public private(set) var turns: [ConversationTurn] = []
    /// 拉到过的运行（这个实例的）。
    public private(set) var runs: [RunID: Run] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 运行列表拉不到（网络不通时照样显示缓存）。
    public private(set) var loadError: ClientError?
    /// 实例（或“只看本次过程”的运行）不存在了。
    public private(set) var isMissing = false
    /// 事件流最近的状态；没订阅时为 nil。连接横幅由应用框架统一显示（`ObservedClient` 自动上报）。
    public private(set) var streamStatus: StreamStatus?
    /// 缓存里可能还有更早的事件。
    public private(set) var hasOlderEvents = false
    /// 服务端可能还有更早的运行。
    public private(set) var hasOlderRuns = false
    public private(set) var isLoadingOlder = false
    public private(set) var olderError: ClientError?
    /// 事件流重置过几次（界面滚到底用）。
    public private(set) var resetCount = 0
    /// `instance.state` 事件说的实例状态（对话页的页头：“正在唤醒”）；没收到过为 nil。
    public private(set) var instanceState: InstanceState?
    /// 计划（来源分隔头上的计划标题、agent 建的计划带 AI 标识）。
    public private(set) var plans: [PlanID: Plan] = [:]
    /// 查过的审批记录（倒计时、处理结果）。
    public private(set) var approvalRecords: [ApprovalID: Approval] = [:]
    /// 这个实例的保险箱填写请求（过期时间、处理结果）。
    public internal(set) var vaultRecords: [VaultRequestID: VaultRequest] = [:]

    // MARK: 输入框（ConversationModel+Actions.swift）

    /// 输入框里的文字。
    public var draft = ""
    public internal(set) var isSending = false
    public internal(set) var sendError: ClientError?
    /// 发送前拦下了像密码的内容：弹保险箱表单。
    public internal(set) var interception: SecretInterception?
    /// 最近发出去的运行（界面滚到底）。
    public internal(set) var lastSentRunID: RunID?
    public internal(set) var isStopping = false
    public internal(set) var stopError: ClientError?

    // MARK: 卡片上的操作（ConversationModel+Actions.swift）

    /// 正在决定的审批卡片（`ConversationItem.id`）。
    public internal(set) var decidingApprovals: Set<String> = []
    public internal(set) var approvalErrors: [String: ConversationActionError] = [:]
    public internal(set) var busyVaultRequests: Set<VaultRequestID> = []
    public internal(set) var vaultErrors: [VaultRequestID: ClientError] = [:]

    // MARK: 内部

    @ObservationIgnored let client: any ClientProtocol
    @ObservationIgnored let biometricGate: any BiometricGate
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored var reducer = ConversationReducer()
    /// 已经读进来的事件（按 seq 升序、不重复；“只看本次过程”时只有那个运行的）。
    @ObservationIgnored var events: [InstanceEvent] = []
    /// 有事件的运行。
    @ObservationIgnored var eventRunIDs: Set<RunID> = []
    /// 处理到的最大 seq（不管属于哪个运行）：续订、补缓存从这里往后。
    @ObservationIgnored var cursorSeq: UInt64?
    @ObservationIgnored private var subscription: EventSubscriptionHandle?
    @ObservationIgnored private var relay: ConversationStreamRelay?
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var fetchingRuns: Set<RunID> = []
    @ObservationIgnored private var checkedApprovals: Set<ApprovalID> = []
    @ObservationIgnored private var hasLoadedVaultRecords = false
    @ObservationIgnored private var hasLoadedPlans = false
    @ObservationIgnored private var markdown: [String: MarkdownStream] = [:]

    /// - Parameters:
    ///   - biometricGate: 批准前的本机验证（App 里是 LocalAuthentication，预览、测试直接通过）。
    ///   - focusRunID: 只看这一个运行的过程。
    ///   - now: 现在的时间（测试传固定值）。
    public init(
        client: any ClientProtocol, instanceID: InstanceID, focusRunID: RunID? = nil,
        biometricGate: any BiometricGate = PassthroughBiometricGate(), now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.instanceID = instanceID
        self.focusRunID = focusRunID
        self.biometricGate = biometricGate
        self.now = now
    }

    // MARK: 生命周期

    /// 打开页面：先显示缓存、拉运行，再订阅事件流。可以重复调（已经加载过、订阅着的不重来）。
    public func start() async {
        if !hasLoaded { await load() }
        subscribeIfNeeded()
        await loadRecords()
    }

    /// 读缓存、拉运行（下拉刷新也调它）。正在拉时再调直接返回。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if !hasLoaded { loadCache() }
        await refreshRuns()
        hasLoaded = true
    }

    /// 下拉：往上还能翻就往前翻，否则重新拉运行。
    public func refresh() async {
        if canLoadOlder {
            await loadOlder()
        } else {
            await load()
        }
    }

    /// 进后台：停掉事件流（scenePhase）。
    public func pause() {
        isPaused = true
        stopSubscription()
    }

    /// 回前台：补上缓存里新到的事件，续订，再刷新运行。
    public func resume() async {
        isPaused = false
        subscribeIfNeeded()
        await refreshRuns()
        await loadRecords()
    }

    /// 重新订阅（账号解冻后 `AppModel.resubscribeRequest` 变了）。
    public func resubscribe() {
        stopSubscription()
        isPaused = false
        subscribeIfNeeded()
    }

    /// 正订阅着事件流。
    public var isSubscribed: Bool { subscription != nil }

    // MARK: 显示

    /// 平铺的对话列表。
    public var items: [ConversationItem] { turns.flatMap(\.items) }

    /// 一段回复解析好的块（流式追加时前面的块不变，只重新解析最后一块）。
    public func markdownBlocks(for item: ConversationItem) -> [MarkdownBlockItem] {
        if let cached = markdown[item.id] { return cached.blocks }
        guard case .assistantText(let text) = item.content else { return [] }
        return MarkdownParser.parse(text.text)
    }

    /// 页面上什么都没有（还没有运行）。
    public var isEmpty: Bool { turns.isEmpty }

    /// 往上还能翻（缓存里更早的事件，或者更早的运行）。
    public var canLoadOlder: Bool {
        focusRunID == nil && hasLoaded && (hasOlderEvents || hasOlderRuns)
    }

    /// 某个运行的那一组。
    public func turn(for runID: RunID) -> ConversationTurn? {
        turns.first { $0.runID == runID }
    }

    /// 这一组在等审批时，要滚到的那张待处理审批卡片（`ConversationItem.id`）。
    public func pendingApprovalItemID(in runID: RunID) -> String? {
        turn(for: runID)?.items.first {
            if case .approval(let card) = $0.content { return card.isPending }
            return false
        }?.id
    }

    /// 运行只有任务和结果、没有过程记录时的说明（比最早一条事件还早、或者事件已经被清掉了）。
    public func historyNote(for turn: ConversationTurn) -> TurnHistoryNote? {
        guard let run = turn.run, !eventRunIDs.contains(run.id), run.state.isTerminal else { return nil }
        // 还没翻到它的事件（缓存里可能还有）不算。
        if hasOlderEvents { return nil }
        return now().timeIntervalSince(run.createdAt) > Self.eventRetention ? .expired : .notCached
    }

    /// 计划触发的运行的计划（拉到了的话）。
    public func plan(for turn: ConversationTurn) -> Plan? {
        turn.run?.planID.flatMap { plans[$0] }
    }

    /// 审批卡片对应的审批记录（查到了的话）。
    public func approvalRecord(for card: ApprovalCard) -> Approval? {
        card.approvalID.flatMap { approvalRecords[$0] }
    }

    /// 保险箱卡片对应的请求记录。
    public func vaultRecord(for card: VaultRequestCard) -> VaultRequest? {
        vaultRecords[card.requestID]
    }

    /// 保险箱卡片现在的状态：事件说的为准；事件还是待填、记录已经过期或处理了的按记录。
    public func vaultStatus(for card: VaultRequestCard) -> VaultRequestStatus {
        guard card.status == .pending, let record = vaultRecords[card.requestID] else { return card.status }
        if record.status == .pending && record.expiresAt <= now() { return .expired }
        return record.status
    }

    // MARK: 缓存与运行

    /// 读缓存：运行和最后一屏事件（“只看本次过程”时找这个运行的全部事件）。
    private func loadCache() {
        if let focus = focusRunID {
            let cached = (try? client.latestCachedEvents(instanceID: instanceID, limit: Self.focusEventLimit)) ?? []
            cursorSeq = cached.last?.seq
            events = cached.filter { $0.runID == focus }
            hasOlderEvents = false
            if let run = findCachedRun(focus) { merge(runs: [run]) }
        } else {
            merge(runs: (try? client.cachedRuns(instanceID: instanceID, limit: Self.runsPageSize)) ?? [])
            let cached = (try? client.latestCachedEvents(instanceID: instanceID, limit: Self.eventPageSize)) ?? []
            events = cached
            cursorSeq = cached.last?.seq
            hasOlderEvents = cached.count >= Self.eventPageSize
        }
        noteInstanceStates(events)
        rebuild()
    }

    /// 缓存里找一个运行（只知道运行 id 时）。
    private func findCachedRun(_ runID: RunID) -> Run? {
        (try? client.cachedRuns(instanceID: instanceID, limit: 200))?.first { $0.id == runID }
    }

    /// 拉最新的一页运行（“只看本次过程”时拉那一个）。
    func refreshRuns() async {
        if let focus = focusRunID {
            do {
                merge(runs: [try await client.getRun(focus)])
                loadError = nil
            } catch {
                guard let failure = ConversationErrors.from(error) else { return }
                if failure.isNotFound { isMissing = true } else { loadError = failure }
            }
            rebuild()
            return
        }
        do {
            let fresh = try await client.runs(instanceID: instanceID, limit: Self.runsPageSize)
            merge(runs: fresh)
            if !hasLoaded { hasOlderRuns = fresh.count >= Self.runsPageSize }
            loadError = nil
            isMissing = false
            await fetchRunsForEvents()
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isMissing = true } else { loadError = failure }
        }
        rebuild()
    }

    /// 事件里有、还没拉到的运行：先往前翻几页运行，剩下的逐个拉。
    private func fetchRunsForEvents() async {
        var missing = eventRunIDs.subtracting(runs.keys)
        var pages = 0
        while !missing.isEmpty, hasOlderRuns, pages < 5, let oldest = oldestRun {
            guard
                let page = try? await client.olderRuns(
                    instanceID: instanceID, before: oldest.id, limit: Self.runsPageSize)
            else { break }
            merge(runs: page)
            hasOlderRuns = page.count >= Self.runsPageSize
            missing.subtract(page.map(\.id))
            pages += 1
        }
        for id in missing.prefix(10) {
            if let run = try? await client.getRun(id) { merge(runs: [run]) }
        }
    }

    /// 拉几个运行的最新记录（事件里新出现的、刚结束的），拉到了就更新时间线。
    func fetchRuns(_ ids: Set<RunID>) async {
        let pending = ids.subtracting(fetchingRuns)
        guard !pending.isEmpty else { return }
        fetchingRuns.formUnion(pending)
        defer { fetchingRuns.subtract(pending) }
        var changed = false
        for id in pending.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let run = try? await client.getRun(id) else { continue }
            if merge(runs: [run]) { changed = true }
        }
        if changed {
            for id in pending { if let run = runs[id] { reducer.upsert(run: run) } }
            render()
        }
    }

    /// 最早的运行（往前翻运行的游标）。
    var oldestRun: Run? {
        runs.values.filter { $0.instanceID == instanceID }.min {
            ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue)
        }
    }

    /// 记下运行；返回有没有变。只收这个实例的（“只看本次过程”时只收那一个）。
    @discardableResult
    func merge(runs list: [Run]) -> Bool {
        var changed = false
        for run in list {
            if let focus = focusRunID {
                guard run.id == focus else { continue }
            } else {
                guard run.instanceID == instanceID else { continue }
            }
            if runs[run.id] != run {
                runs[run.id] = run
                changed = true
            }
        }
        return changed
    }

    // MARK: 往前翻

    /// 往上翻：先翻缓存里更早的事件，翻到头了再翻更早的运行。
    public func loadOlder() async {
        guard canLoadOlder, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        if hasOlderEvents {
            let older: [InstanceEvent]
            if let first = events.first {
                older =
                    (try? client.cachedEventsBefore(
                        instanceID: instanceID, beforeSeq: first.seq, limit: Self.eventPageSize)) ?? []
            } else {
                older = []
            }
            let fresh = older.filter { e in !events.contains { $0.seq == e.seq } }
            events = (fresh + events).sorted { $0.seq < $1.seq }
            hasOlderEvents = older.count >= Self.eventPageSize
            noteInstanceStates(fresh)
            rebuild()
            await fetchRunsForEvents()
            rebuild()
            return
        }
        guard let oldest = oldestRun else {
            hasOlderRuns = false
            return
        }
        do {
            let page = try await client.olderRuns(instanceID: instanceID, before: oldest.id, limit: Self.runsPageSize)
            merge(runs: page)
            hasOlderRuns = page.count >= Self.runsPageSize
            olderError = nil
        } catch {
            olderError = ConversationErrors.from(error)
        }
        rebuild()
    }

    // MARK: 事件流

    private func subscribeIfNeeded() {
        guard subscription == nil, !isPaused, !isMissing else { return }
        // 停订阅期间 client-core 收到、写进缓存的事件不会再回调：先从缓存补上。
        catchUpFromCache()
        let relay = ConversationStreamRelay { [weak self] relay in
            Task { @MainActor [weak self] in self?.drain(relay) }
        }
        self.relay = relay
        do {
            subscription = try client.subscribe(instanceID: instanceID, afterSeq: cursorSeq, listener: relay)
        } catch {
            self.relay = nil
            streamStatus = nil
        }
    }

    private func stopSubscription() {
        relay = nil
        subscription?.stop()
        subscription = nil
        streamStatus = nil
    }

    /// 缓存里 `cursorSeq` 之后的事件（停订阅期间到的）。
    private func catchUpFromCache() {
        guard hasLoaded, let after = cursorSeq else { return }
        let fresh =
            (try? client.cachedEvents(instanceID: instanceID, afterSeq: after, limit: Self.focusEventLimit)) ?? []
        guard !fresh.isEmpty else { return }
        receive(fresh.map(EventStreamElement.event))
    }

    private func drain(_ relay: ConversationStreamRelay) {
        // 停订阅、重新订阅之后，旧的那条事件流里还没处理的不要了（续订时从缓存补）。
        guard relay === self.relay else { return }
        receive(relay.drain())
    }

    /// 处理一批事件流的内容（按顺序），最后刷新一次界面。
    func receive(_ elements: [EventStreamElement]) {
        var changed = false
        var runsToFetch: Set<RunID> = []
        for element in elements {
            switch element {
            case .event(let event):
                if let cursor = cursorSeq, event.seq <= cursor { continue }
                cursorSeq = event.seq
                if noteInstanceState(event) { continue }
                if let focus = focusRunID, event.runID != focus { continue }
                events.append(event)
                guard reducer.apply(event) else { continue }
                changed = true
                if let id = event.runID {
                    eventRunIDs.insert(id)
                    if runs[id] == nil { runsToFetch.insert(id) }
                    if case .runState(let state) = event.payload {
                        apply(state, to: id, at: event.createdAt)
                        if state.state.isTerminal { runsToFetch.insert(id) }
                    }
                }
            case .reset(let oldestSeq, _):
                reset(oldestSeq: oldestSeq)
                changed = true
            case .status(let status):
                streamStatus = status
                if status.isFinal {
                    subscription = nil
                    relay = nil
                    if status == .notFound { isMissing = true }
                }
            }
        }
        if changed { render() }
        if !runsToFetch.isEmpty {
            Task { await fetchRuns(runsToFetch) }
        }
    }

    /// `run.state` 事件同步到运行记录（状态、尝试次数、等待原因码），“进行中”、停止按钮跟着变。
    private func apply(_ state: RunStatePayload, to runID: RunID, at date: Date) {
        guard var run = runs[runID] else { return }
        run.state = state.state
        run.stateReason = state.reason
        run.waitCode = RunWaitCode.applies(to: state.state) ? state.waitCode : nil
        if let attempt = state.attempt { run.attempt = max(run.attempt, attempt) }
        if state.state == .running && run.startedAt == nil { run.startedAt = date }
        if state.state.isTerminal && run.finishedAt == nil { run.finishedAt = date }
        runs[runID] = run
        reducer.upsert(run: run)
    }

    /// 事件流重置：本地事件作废，从缓存重新读（client-core 已经清掉了，服务端接着补发），运行记录保留并重新拉。
    private func reset(oldestSeq: UInt64) {
        resetCount += 1
        let cached: [InstanceEvent]
        if let focus = focusRunID {
            cached = ((try? client.latestCachedEvents(instanceID: instanceID, limit: Self.focusEventLimit)) ?? [])
                .filter { $0.runID == focus }
        } else {
            cached = (try? client.latestCachedEvents(instanceID: instanceID, limit: Self.eventPageSize)) ?? []
            hasOlderEvents = cached.count >= Self.eventPageSize
        }
        events = cached
        // 补发的事件从 `oldestSeq` 开始，缓存里已经有的不重复。
        let cachedLast = cached.last?.seq ?? 0
        cursorSeq = max(cachedLast, oldestSeq > 0 ? oldestSeq - 1 : 0)
        if cachedLast == 0 && oldestSeq <= 1 { cursorSeq = nil }
        checkedApprovals = []
        rebuild()
        Task {
            await refreshRuns()
            await loadRecords()
        }
    }

    /// `instance.state` 事件（没有运行 id，不进时间线）：记下实例状态。是这种事件返回 true。
    private func noteInstanceState(_ event: InstanceEvent) -> Bool {
        guard event.kind.rawValue == Self.instanceStateKind else { return false }
        if let raw = event.payloadValue?["state"]?.stringValue { instanceState = InstanceState(rawValue: raw) }
        return true
    }

    private func noteInstanceStates(_ list: [InstanceEvent]) {
        for event in list { _ = noteInstanceState(event) }
    }

    /// 实例状态变化的事件（control 写的，crates/control/src/lib.rs）。
    nonisolated static let instanceStateKind = "instance.state"

    // MARK: 审批记录、保险箱请求、计划

    /// 打开页面（和重置之后）各查一次：卡片上的审批、没关联上的待处理审批、保险箱请求、计划标题。
    func loadRecords() async {
        await checkApprovals()
        await loadVaultRecords()
        await loadPlans()
    }

    /// 查审批记录：卡片上有审批 id 的（待处理的、结论还不确定的）各查一次 `getApproval`；有没关联上的待处理卡片时拉
    /// `approvals()`。查到的交给归并（卡片的状态以记录为准）。
    private func checkApprovals() async {
        let cards = approvalCards
        let unsure = cards.filter { card in
            guard card.approvalID != nil else { return false }
            guard let resolution = card.resolution else { return true }
            return resolution.by != .policy && resolution.state == nil
        }
        var fetched: [Approval] = []
        for id in unsure.compactMap(\.approvalID).suffix(20) where !checkedApprovals.contains(id) {
            checkedApprovals.insert(id)
            if let approval = try? await client.getApproval(id) { fetched.append(approval) }
        }
        if cards.contains(where: { $0.isPending && $0.approvalID == nil }),
            let pending = try? await client.approvals()
        {
            fetched += pending.filter { $0.instanceID == instanceID }
        }
        apply(approvals: fetched)
    }

    /// 卡片出现在屏幕上时查一次它的审批记录（打开页面时没查到的）。
    public func checkApproval(_ card: ApprovalCard) async {
        guard let id = card.approvalID, !checkedApprovals.contains(id) else { return }
        checkedApprovals.insert(id)
        guard let approval = try? await client.getApproval(id) else { return }
        apply(approvals: [approval])
    }

    func apply(approvals list: [Approval]) {
        guard !list.isEmpty else { return }
        for approval in list { approvalRecords[approval.id] = approval }
        reducer.link(approvals: list)
        render()
    }

    private var approvalCards: [ApprovalCard] {
        items.compactMap {
            if case .approval(let card) = $0.content { return card }
            return nil
        }
    }

    private func loadVaultRecords() async {
        let hasCards = items.contains {
            if case .vaultRequest = $0.content { return true }
            return false
        }
        guard hasCards, !hasLoadedVaultRecords else { return }
        guard let list = try? await client.vaultRequests(all: true) else { return }
        hasLoadedVaultRecords = true
        for request in list where request.instanceID == instanceID { vaultRecords[request.id] = request }
    }

    private func loadPlans() async {
        let hasPlanRuns = runs.values.contains { $0.planID != nil }
        guard hasPlanRuns, !hasLoadedPlans else { return }
        guard let list = try? await client.plans(instanceID: nil) else { return }
        hasLoadedPlans = true
        plans = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: 归并

    /// 显示哪些运行：缓存里还有更早的事件时，只显示有事件的、或者比最早一条事件晚建的（再早的等翻到再显示）。
    private var visibleRuns: [Run] {
        let all = Array(runs.values)
        guard focusRunID == nil, hasOlderEvents, let first = events.first else { return all }
        return all.filter { eventRunIDs.contains($0.id) || $0.createdAt >= first.createdAt }
    }

    /// 从头归并（读了缓存、往前翻、重置之后）。
    func rebuild() {
        eventRunIDs = Set(events.compactMap(\.runID))
        var next = ConversationReducer(runs: visibleRuns)
        next.apply(events)
        next.link(approvals: Array(approvalRecords.values))
        reducer = next
        render()
    }

    /// 刷新界面（一批事件只刷新一次）。
    func render() {
        turns = reducer.conversationTurns
        var seen: Set<String> = []
        for turn in turns {
            for item in turn.items {
                guard case .assistantText(let text) = item.content else { continue }
                seen.insert(item.id)
                markdown[item.id, default: MarkdownStream()].update(text.text)
            }
        }
        for key in markdown.keys where !seen.contains(key) { markdown[key] = nil }
    }
}

/// 只有任务和结果、没有过程记录的运行旁边的说明。
public enum TurnHistoryNote: Hashable, Sendable {
    /// 事件已经超过保留期（默认 30 天）被清掉了。
    case expired
    /// 本机缓存里没有（缓存每个实例只留最近的 2000 条，事件流重置时也会清掉）。
    case notCached
}

/// 卡片上的操作出的错。
public enum ConversationActionError: Hashable, Sendable {
    /// 接口的错误（按 `ClientError` 的分类显示）。
    case client(ClientError)
    /// 批准前的本机验证没通过。
    case verificationFailed
    /// 审批卡片还没关联上审批记录（老的服务端、建审批失败）：去审批中心处理。
    case notLinked
}

/// 视图模型里统一的错误转换。
enum ConversationErrors {
    /// 任务被取消（页面关了）返回 nil，不算出错；不是 `ClientError` 的按内部错误。
    static func from(_ error: any Error) -> ClientError? {
        if error is CancellationError { return nil }
        return (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}
