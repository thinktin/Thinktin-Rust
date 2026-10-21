import Foundation

/// 内存里的 `ClientProtocol` 实现，带演示数据（`DemoData`）。预览、快照测试、Linux 上的单元测试、
/// Debug 版 App（`THINKTIN_MOCK=1`）都用它。
///
/// - 状态可以直接读写（`state`、`update(_:)`），也可以整体换掉（`MockClient(state:)`）；
/// - 发消息（`sendMessage` / `createRun`）后自动播放一段 agent 回答（`DemoData.replyScript`），
///   审批、保险箱请求处理后接着播；`setScript(_:for:)` 设定下一次订阅时回放的事件；
/// - `failNext(with:)` 让下一次调用抛错；`latency` 模拟网络延迟；
/// - 规则尽量和服务端一致：没登录抛 `signedOut`，找不到抛 `not_found`，状态不对抛 `conflict`，参数不对抛 `invalid`。
public final class MockClient: ClientProtocol, @unchecked Sendable {
    public let secretDetector: any SecretDetector
    private let inner: Locked<Inner>

    /// - Parameters:
    ///   - latency: 每次异步调用前等多久（秒），模拟网络。
    ///   - stepDelay: 回放脚本时每条事件之间等多久（秒）；为 0 时脚本里的 `wait` 也跳过（测试用）。
    ///   - autoReply: 发消息后自动播放 agent 的回答。
    public init(
        state: MockState = DemoData.state(), latency: TimeInterval = 0, stepDelay: TimeInterval = 0.35,
        autoReply: Bool = true, secretDetector: any SecretDetector = MockSecretDetector()
    ) {
        self.secretDetector = secretDetector
        var inner = Inner(state: state)
        inner.latency = latency
        inner.stepDelay = stepDelay
        inner.autoReply = autoReply
        inner.indexPendingPermissions()
        self.inner = Locked(inner)
    }

    // MARK: 测试和预览用的控制

    /// 当前状态的拷贝。
    public var state: MockState { inner.withLock { $0.state } }

    /// 直接改状态（不发事件）。
    public func update(_ body: (inout MockState) -> Void) {
        inner.withLock { body(&$0.state) }
    }

    /// 下一次调用（任何方法）抛这个错误。可以连续排几个。
    public func failNext(with error: ClientError) {
        inner.withLock { $0.failures.append(error) }
    }

    /// 下一次订阅这个实例时，补发完历史事件后回放这段脚本（只用一次）。
    public func setScript(_ script: MockEventScript, for instanceID: InstanceID) {
        inner.withLock { $0.scripts[instanceID] = script }
    }

    /// 发一条事件：记进实例的事件，推给订阅者，并按事件更新状态（运行状态、审批、保险箱请求、产出物）。
    @discardableResult
    public func emit(
        _ kind: InstanceEventKind, payload: JSONValue, runID: RunID?, instanceID: InstanceID, at date: Date = Date()
    ) -> InstanceEvent {
        inner.withLock { $0.emit(kind, payload: payload, runID: runID, instanceID: instanceID, at: date) }
    }

    /// 按顺序播放脚本（后台任务）。
    @discardableResult
    public func play(_ script: MockEventScript, instanceID: InstanceID) -> Task<Void, Never> {
        let key = UUID()
        let delay = inner.withLock { $0.stepDelay }
        let task = Task { [weak self] in
            for step in script.steps {
                if Task.isCancelled { return }
                switch step {
                case .wait(let seconds):
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                case .event(let kind, let payload, let runID):
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    if Task.isCancelled { return }
                    guard let self else { return }
                    // 取消和播放可能同时发生：在锁里检查，被取消的运行不再出新事件（否则会被播放中的脚本“复活”）。
                    let target = runID ?? script.runID
                    let emitted = self.inner.withLock { s -> Bool in
                        if let target, s.cancelledRuns.contains(target) { return false }
                        s.emit(kind, payload: payload, runID: target, instanceID: instanceID, at: Date())
                        return true
                    }
                    if !emitted { return }
                case .status(let status):
                    self?.inner.withLock { $0.broadcast(.status(status), to: instanceID) }
                case .reset(let oldest, let latest):
                    self?.inner.withLock { $0.broadcast(.reset(oldestSeq: oldest, latestSeq: latest), to: instanceID) }
                }
            }
        }
        inner.withLock { $0.playbacks[key] = Playback(runID: script.runID, task: task) }
        return task
    }

    /// 等所有正在播放的脚本播完（包括播放中又触发的）。
    public func waitForPlayback() async {
        while true {
            let tasks = inner.withLock { s -> [Task<Void, Never>] in
                defer { s.playbacks.removeAll() }
                return s.playbacks.values.map(\.task)
            }
            if tasks.isEmpty { return }
            for t in tasks { await t.value }
        }
    }

    // MARK: 内部

    private func call<R>(signedIn required: Bool = true, _ body: (inout Inner) throws -> R) async throws -> R {
        let latency = inner.withLock { $0.latency }
        if latency > 0 { try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        return try syncCall(signedIn: required, body)
    }

    private func syncCall<R>(signedIn required: Bool = true, _ body: (inout Inner) throws -> R) throws -> R {
        try inner.withLock { s in
            if !s.failures.isEmpty { throw s.failures.removeFirst() }
            if required && s.state.session == nil { throw ClientError.signedOut }
            return try body(&s)
        }
    }

    private func cancelPlayback(runIDs: Set<RunID>) {
        let tasks = inner.withLock { s -> [Task<Void, Never>] in
            let keys = s.playbacks.filter { $0.value.runID.map(runIDs.contains) ?? false }.map(\.key)
            return keys.compactMap { s.playbacks.removeValue(forKey: $0)?.task }
        }
        for task in tasks { task.cancel() }
    }

    private func autoReply(to run: Run) {
        guard inner.withLock({ $0.autoReply }) else { return }
        play(DemoData.replyScript(for: run), instanceID: run.instanceID)
    }

    // MARK: 账号

    public func signedIn() -> Bool {
        inner.withLock { $0.state.session != nil }
    }

    public func sendCode(phone: String) async throws {
        try await call(signedIn: false) { _ in
            guard phone.filter(\.isNumber).count >= 11 else { throw MockErrors.invalid("bad phone number") }
        }
    }

    public func login(phone: String, code: String, push: PushRegistration?) async throws -> LoginResult {
        try await call(signedIn: false) { s in
            guard phone.filter(\.isNumber).count >= 11 else { throw MockErrors.invalid("bad phone number") }
            guard code == s.state.verificationCode else { throw MockErrors.invalid("wrong verification code") }
            let isNew = phone != s.state.user.phone
            if isNew { s.state.user.phone = phone }
            s.state.session = Session(
                userID: s.state.user.id, deviceID: DemoData.deviceID, accessToken: "mock-access-\(UUID().uuidString)",
                refreshToken: "mock-refresh-\(UUID().uuidString)")
            return LoginResult(user: s.state.user, isNewUser: isNew)
        }
    }

    public func logout() async throws {
        try await call(signedIn: false) { s in s.state.session = nil }
    }

    public func me() async throws -> User {
        try await call { s in s.state.user }
    }

    public func setLocale(_ locale: UserLocale) async throws -> User {
        try await call { s in
            s.state.user.locale = locale
            return s.state.user
        }
    }

    public func setPushToken(_ push: PushRegistration) async throws {
        try await call { _ in
            guard !push.token.isEmpty else { throw MockErrors.invalid("empty push token") }
        }
    }

    public func stopAll() async throws -> StopAllResult {
        let (result, cancelled) = try await call { s in s.stopAll() }
        cancelPlayback(runIDs: cancelled)
        return result
    }

    public func signOutOtherDevices(stopAgents: Bool) async throws -> SignOutOthersResult {
        let (result, cancelled) = try await call { s -> (SignOutOthersResult, Set<RunID>) in
            guard stopAgents else { return (SignOutOthersResult(devicesSignedOut: 1), []) }
            let (stopped, cancelled) = s.stopAll()
            return (SignOutOthersResult(devicesSignedOut: 1, stopped: stopped), cancelled)
        }
        cancelPlayback(runIDs: cancelled)
        return result
    }

    // MARK: agent 与实例

    public func agents() async throws -> [AgentInfo] {
        try await call { s in s.state.agents }
    }

    public func instances() async throws -> [Instance] {
        try await call { s in s.state.instances }
    }

    public func cachedInstances() throws -> [Instance] {
        try syncCall(signedIn: false) { s in s.state.instances }
    }

    public func adopt(agentID: AgentID, name: String, harness: String?) async throws -> Instance {
        try await call { s in
            guard let agent = s.state.agents.first(where: { $0.id == agentID }) else {
                throw MockErrors.notFound("agent")
            }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MockErrors.invalid("name is empty") }
            let harness = harness ?? agent.defaultHarness
            guard agent.harnesses.isEmpty || agent.harnesses.contains(harness) else {
                throw MockErrors.invalid("unknown harness \(harness)")
            }
            let now = Date()
            let instance = Instance(
                id: .random(), agentID: agent.id, agentVersion: agent.version, harness: harness, name: name,
                state: .running, createdAt: now, lastActiveAt: now)
            s.state.instances.append(instance)
            return instance
        }
    }

    public func renameInstance(_ instanceID: InstanceID, name: String) async throws -> Instance {
        try await call { s in
            let i = try s.instanceIndex(instanceID)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MockErrors.invalid("name is empty") }
            s.state.instances[i].name = name
            return s.state.instances[i]
        }
    }

    public func setInstanceVersion(_ instanceID: InstanceID, version: String?) async throws -> Instance {
        try await call { s in
            let i = try s.instanceIndex(instanceID)
            let agent = s.state.agents.first { $0.id == s.state.instances[i].agentID }
            let target = version ?? agent?.versions.first ?? agent?.version ?? s.state.instances[i].agentVersion
            if let agent, !agent.versions.isEmpty, !agent.versions.contains(target) {
                throw MockErrors.invalid("unknown version \(target)")
            }
            s.state.instances[i].agentVersion = target
            return s.state.instances[i]
        }
    }

    public func modelRoutes(instanceID: InstanceID) async throws -> [ModelRoute] {
        try await call { s in
            _ = try s.instanceIndex(instanceID)
            return s.state.routes[instanceID] ?? []
        }
    }

    public func setModelRoutes(instanceID: InstanceID, routes: [ModelRoute]) async throws {
        try await call { s in
            _ = try s.instanceIndex(instanceID)
            let known = Set(s.state.credentials.map(\.id))
            guard Set(routes.map(\.alias)).count == routes.count else { throw MockErrors.invalid("duplicate alias") }
            for r in routes {
                guard !r.alias.isEmpty else { throw MockErrors.invalid("empty alias") }
                guard r.fallbacks.count <= ModelRoute.maxFallbacks else {
                    throw MockErrors.invalid("too many fallbacks")
                }
                guard known.contains(r.credentialID), r.fallbacks.allSatisfy({ known.contains($0.credentialID) }) else {
                    throw MockErrors.invalid("unknown credential")
                }
            }
            s.state.routes[instanceID] = routes
        }
    }

    public func deleteInstance(_ instanceID: InstanceID) async throws {
        try await call { s in
            let i = try s.instanceIndex(instanceID)
            s.state.instances.remove(at: i)
            s.state.routes[instanceID] = nil
            s.state.plans.removeAll { $0.instanceID == instanceID }
        }
    }

    // MARK: 运行

    public func createRun(instanceID: InstanceID, prompt: String) async throws -> Run {
        let run = try await call { s in try s.createRun(instanceID: instanceID, prompt: prompt) }
        autoReply(to: run)
        return run
    }

    public func runs(instanceID: InstanceID, limit: Int) async throws -> [Run] {
        try await call { s in
            _ = try s.instanceIndex(instanceID)
            return s.runs(of: instanceID, limit: limit)
        }
    }

    public func cachedRuns(instanceID: InstanceID, limit: Int) throws -> [Run] {
        try syncCall(signedIn: false) { s in s.runs(of: instanceID, limit: limit) }
    }

    public func getRun(_ runID: RunID) async throws -> Run {
        try await call { s in s.state.runs[try s.runIndex(runID)] }
    }

    public func cancelRun(_ runID: RunID, wholeTree: Bool) async throws -> Run {
        let (run, cancelled) = try await call { s -> (Run, Set<RunID>) in
            let i = try s.runIndex(runID)
            guard s.state.runs[i].state.isActive else { throw MockErrors.conflict("run already finished") }
            let root = s.state.runs[i].rootRunID
            let targets =
                wholeTree
                ? s.state.runs.filter { $0.rootRunID == root && $0.state.isActive }.map(\.id) : [runID]
            for id in targets {
                guard let r = s.state.runs.first(where: { $0.id == id }) else { continue }
                var payload: JSONValue = ["state": "cancelled", "reason": "cancelled by user"]
                if wholeTree { payload = payload.merging(["tree": true]) }
                s.cancelledRuns.insert(id)
                s.emit(.runState, payload: payload, runID: id, instanceID: r.instanceID, at: Date())
            }
            return (s.state.runs[try s.runIndex(runID)], Set(targets))
        }
        cancelPlayback(runIDs: cancelled)
        return run
    }

    public func runTree(_ runID: RunID) async throws -> [Run] {
        try await call { s in
            let root = s.state.runs[try s.runIndex(runID)].rootRunID
            return s.state.runs.filter { $0.rootRunID == root }.sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func runArtifacts(_ runID: RunID) async throws -> [Artifact] {
        try await call { s in
            _ = try s.runIndex(runID)
            return s.state.artifacts.filter { $0.runID == runID }
        }
    }

    public func artifactContent(_ artifactID: ArtifactID) async throws -> Data {
        try await call { s in
            guard let data = s.state.artifactContents[artifactID] else { throw MockErrors.notFound("artifact") }
            return data
        }
    }

    // MARK: 事件流

    public func subscribe(instanceID: InstanceID, afterSeq: UInt64?, listener: any EventListening) throws
        -> EventSubscriptionHandle
    {
        let (stream, continuation) = AsyncStream.makeStream(of: EventStreamElement.self, bufferingPolicy: .unbounded)
        let id = UUID()
        let script = try syncCall(signedIn: false) { s -> MockEventScript? in
            continuation.yield(.status(.connecting))
            guard s.state.session != nil else {
                continuation.yield(.status(.signedOut))
                continuation.finish()
                return nil
            }
            guard s.state.instances.contains(where: { $0.id == instanceID }) else {
                continuation.yield(.status(.notFound))
                continuation.finish()
                return nil
            }
            for e in s.state.events[instanceID] ?? [] where e.seq > (afterSeq ?? 0) {
                continuation.yield(.event(e))
            }
            continuation.yield(.status(.live))
            s.subscribers[id] = Subscriber(instanceID: instanceID, continuation: continuation)
            return s.scripts.removeValue(forKey: instanceID)
        }
        // 回调按顺序在后台任务上执行（和 client-core 一样不在主线程）。
        let consumer = Task.detached {
            for await element in stream {
                switch element {
                case .event(let e): listener.onEvent(e)
                case .reset(let oldest, let latest): listener.onReset(oldestSeq: oldest, latestSeq: latest)
                case .status(let status): listener.onStatus(status)
                }
            }
        }
        let playback = script.map { play($0, instanceID: instanceID) }
        return EventSubscriptionHandle { [weak self] in
            self?.inner.withLock { _ = $0.subscribers.removeValue(forKey: id) }
            continuation.finish()
            consumer.cancel()
            playback?.cancel()
        }
    }

    public func cachedEvents(instanceID: InstanceID, afterSeq: UInt64, limit: Int) throws -> [InstanceEvent] {
        try syncCall(signedIn: false) { s in
            Array((s.state.events[instanceID] ?? []).filter { $0.seq > afterSeq }.prefix(max(0, limit)))
        }
    }

    // MARK: 审批

    public func approvals() async throws -> [Approval] {
        try await call { s in s.state.approvals.filter(\.isPending) }
    }

    public func decideApproval(_ approvalID: ApprovalID, optionID: String) async throws -> Approval {
        let (approval, script) = try await call { s -> (Approval, MockEventScript?) in
            guard let i = s.state.approvals.firstIndex(where: { $0.id == approvalID }) else {
                throw MockErrors.notFound("approval")
            }
            guard s.state.approvals[i].isPending else { throw MockErrors.conflict("approval already decided") }
            guard let option = s.state.approvals[i].options.first(where: { $0.id == optionID }) else {
                throw MockErrors.invalid("unknown option \(optionID)")
            }
            s.state.approvals[i].state = option.kind.isAllow ? .approved : .rejected
            let approval = s.state.approvals[i]
            s.emit(
                .approvalDecided,
                payload: [
                    "approval_id": .string(approvalID.rawValue), "state": .string(approval.state.rawValue),
                    "option_id": .string(optionID),
                ], runID: approval.runID, instanceID: approval.instanceID, at: Date())
            for j in s.state.inbox.indices where s.state.inbox[j].approvalID == approvalID {
                s.state.inbox[j].isRead = true
            }
            let pending = s.permissions.removeValue(forKey: approvalID)
            let script = pending.map {
                DemoData.approvalResolvedScript(
                    runID: approval.runID, requestID: $0.requestID, toolCallID: $0.toolCallID, optionID: optionID,
                    approved: option.kind.isAllow)
            }
            return (approval, script)
        }
        if let script { play(script, instanceID: approval.instanceID) }
        return approval
    }

    // MARK: 计划

    public func plans(instanceID: InstanceID?) async throws -> [Plan] {
        try await call { s in
            // 和接口一致：列表里没有触发器和步骤，详情里才有。
            s.state.plans.filter { instanceID == nil || $0.instanceID == instanceID }.map { plan in
                var p = plan
                p.triggers = []
                p.steps = []
                return p
            }
        }
    }

    public func getPlan(_ planID: PlanID) async throws -> Plan {
        try await call { s in s.state.plans[try s.planIndex(planID)] }
    }

    public func createPlan(_ plan: NewPlan) async throws -> Plan {
        try await call { s in
            _ = try s.instanceIndex(plan.instanceID)
            guard !plan.title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MockErrors.invalid("empty title")
            }
            guard !plan.triggers.isEmpty else { throw MockErrors.invalid("a plan needs at least one trigger") }
            for step in plan.steps { _ = try s.instanceIndex(step.instanceID) }
            let policy = (try? JSONEncoder().encode(PlanPolicy())).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let created = Plan(
                id: .random(), instanceID: plan.instanceID, title: plan.title, goal: plan.goal, createdBy: .user,
                revision: 1, policyJSON: policy, createdAt: Date(),
                triggers: plan.triggers.map { schedule in
                    var next: Date?
                    if case .once(let at) = schedule { next = at }
                    return Trigger(id: .random(), schedule: schedule, nextFireAt: next)
                }, steps: plan.steps)
            s.state.plans.append(created)
            return created
        }
    }

    public func setPlanPaused(_ planID: PlanID, paused: Bool) async throws -> Plan {
        try await call { s in
            let i = try s.planIndex(planID)
            if s.state.plans[i].awaitingConfirmation && !paused {
                throw MockErrors.conflict("the plan is awaiting confirmation")
            }
            s.state.plans[i].isPaused = paused
            return s.state.plans[i]
        }
    }

    public func confirmPlan(_ planID: PlanID, revision: Int) async throws -> Plan {
        try await call { s in
            let i = try s.planIndex(planID)
            guard s.state.plans[i].awaitingConfirmation else { throw MockErrors.conflict("nothing to confirm") }
            guard s.state.plans[i].revision == revision else { throw MockErrors.conflict("the plan changed") }
            s.state.plans[i].awaitingConfirmation = false
            return s.state.plans[i]
        }
    }

    public func deletePlan(_ planID: PlanID) async throws {
        try await call { s in
            _ = s.state.plans.remove(at: try s.planIndex(planID))
        }
    }

    // MARK: 收件箱

    public func syncInbox(limit: Int) async throws -> InboxPage {
        try await call { s in
            InboxPage(items: Array(s.state.inbox.prefix(max(0, limit))), unread: s.state.unreadCount)
        }
    }

    public func olderInbox(before: InboxItemID, limit: Int) async throws -> [InboxItem] {
        try await call { s in s.inbox(before: before, limit: limit) }
    }

    public func cachedInbox(before: InboxItemID?, limit: Int) throws -> [InboxItem] {
        try syncCall(signedIn: false) { s in s.inbox(before: before, limit: limit) }
    }

    public func cachedUnread() throws -> Int {
        try syncCall(signedIn: false) { s in s.state.unreadCount }
    }

    public func markInboxRead(ids: [InboxItemID], upTo: InboxItemID?) async throws -> Int {
        try await call { s in
            if ids.isEmpty {
                let start = upTo.flatMap { id in s.state.inbox.firstIndex { $0.id == id } } ?? 0
                for i in s.state.inbox.indices where i >= start { s.state.inbox[i].isRead = true }
            } else {
                let set = Set(ids)
                for i in s.state.inbox.indices where set.contains(s.state.inbox[i].id) {
                    s.state.inbox[i].isRead = true
                }
            }
            return s.state.unreadCount
        }
    }

    // MARK: 用量

    public func usage(group: UsageGroup, from: Date?, to: Date?, timeZone: TimeZone?) async throws -> UsageSummary {
        try await call { s in s.usage(group: group) }
    }

    // MARK: 模型 key

    public func vendors() async throws -> [VendorInfo] {
        try await call { s in s.state.vendors }
    }

    public func credentials() async throws -> [Credential] {
        try await call { s in s.state.credentials }
    }

    public func addCredential(_ credential: NewCredential) async throws -> Credential {
        try await call { s in
            let key = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count >= 8 else { throw MockErrors.invalid("api key is too short") }
            let vendor = s.state.vendors.first { $0.id == credential.vendor }
            if vendor == nil {
                guard credential.vendor == NewCredential.customVendor,
                    credential.anthropicBase != nil || credential.openaiBase != nil || credential.responsesBase != nil
                else { throw MockErrors.invalid("unknown vendor \(credential.vendor)") }
            }
            let label = credential.label.isEmpty ? (vendor?.name ?? credential.vendor) : credential.label
            let created = Credential(
                id: .random(), vendor: credential.vendor, label: label, last4: String(key.suffix(4)),
                dailyTokenLimit: credential.dailyTokenLimit, createdAt: Date())
            s.state.credentials.append(created)
            return created
        }
    }

    public func deleteCredential(_ credentialID: CredentialID) async throws {
        try await call { s in
            guard let i = s.state.credentials.firstIndex(where: { $0.id == credentialID }) else {
                throw MockErrors.notFound("credential")
            }
            s.state.credentials.remove(at: i)
        }
    }

    // MARK: IM 渠道

    public func imChannels() async throws -> [ImChannel] {
        try await call { s in s.state.imChannels }
    }

    public func addImChannel(_ channel: NewImChannel) async throws -> ImChannel {
        try await call { s in
            let vendor = try MockErrors.imVendor(webhookURL: channel.webhookURL)
            let created = ImChannel(
                id: .random(), vendor: vendor, label: channel.label, hint: String(channel.webhookURL.suffix(4)),
                hasSecret: !(channel.secret ?? "").isEmpty, events: channel.events ?? ImEvent.knownCases,
                createdAt: Date())
            s.state.imChannels.append(created)
            return created
        }
    }

    public func updateImChannel(_ channelID: ImChannelID, label: String?, events: [ImEvent]?, enabled: Bool?)
        async throws -> ImChannel
    {
        try await call { s in
            let i = try s.channelIndex(channelID)
            if let label { s.state.imChannels[i].label = label }
            if let events {
                guard !events.isEmpty else { throw MockErrors.invalid("pick at least one event") }
                s.state.imChannels[i].events = events
            }
            if let enabled { s.state.imChannels[i].isEnabled = enabled }
            return s.state.imChannels[i]
        }
    }

    public func replaceImWebhook(_ channelID: ImChannelID, webhookURL: String, secret: String?) async throws
        -> ImChannel
    {
        try await call { s in
            let i = try s.channelIndex(channelID)
            s.state.imChannels[i].vendor = try MockErrors.imVendor(webhookURL: webhookURL)
            s.state.imChannels[i].hint = String(webhookURL.suffix(4))
            s.state.imChannels[i].hasSecret = !(secret ?? "").isEmpty
            s.state.imChannels[i].lastError = nil
            return s.state.imChannels[i]
        }
    }

    public func testImChannel(_ channelID: ImChannelID) async throws {
        try await call { s in
            let i = try s.channelIndex(channelID)
            guard s.state.imChannels[i].isEnabled else { throw MockErrors.conflict("channel is disabled") }
            s.state.imChannels[i].lastSentAt = Date()
        }
    }

    public func deleteImChannel(_ channelID: ImChannelID) async throws {
        try await call { s in
            _ = s.state.imChannels.remove(at: try s.channelIndex(channelID))
        }
    }

    // MARK: 消息与保险箱

    public func sendMessage(instanceID: InstanceID, text: String, allowSecrets: Bool) async throws -> Run {
        let found = allowSecrets ? [] : secretDetector.detectSecrets(in: text)
        let run = try await call { s in
            guard found.isEmpty else { throw ClientError.containsSecrets(count: found.count) }
            return try s.createRun(instanceID: instanceID, prompt: text)
        }
        autoReply(to: run)
        return run
    }

    public func saveSecretFromMessage(message: String, value: String, item: NewVaultItem) async throws -> SavedSecret {
        let detector = secretDetector
        return try await call { s in
            let created = try s.createVaultItem(item)
            let redacted = detector.redactMessage(
                message, references: [SecretReference(value: value, name: created.name)])
            return SavedSecret(item: created, message: redacted)
        }
    }

    public func vaultItems() async throws -> [VaultItem] {
        try await call { s in s.state.vaultItems }
    }

    public func vaultItem(_ itemID: VaultItemID) async throws -> VaultItemDetail {
        try await call { s in
            let item = s.state.vaultItems[try s.vaultIndex(itemID)]
            return VaultItemDetail(item: item, username: s.state.vaultUsernames[itemID] ?? "")
        }
    }

    public func createVaultItem(_ item: NewVaultItem) async throws -> VaultItem {
        try await call { s in try s.createVaultItem(item) }
    }

    public func updateVaultItem(_ itemID: VaultItemID, change: VaultItemUpdate) async throws -> VaultItem {
        try await call { s in
            let i = try s.vaultIndex(itemID)
            // 先校验再改：出错时状态不动。
            if let password = change.password, password.isEmpty { throw MockErrors.invalid("empty password") }
            if let purpose = change.purpose { s.state.vaultItems[i].purpose = purpose }
            if let username = change.username {
                s.state.vaultUsernames[itemID] = username
                s.state.vaultItems[i].hasUsername = !username.isEmpty
            }
            if let ids = change.instanceIDs { s.state.vaultItems[i].instanceIDs = ids }
            s.state.vaultItems[i].updatedAt = Date()
            return s.state.vaultItems[i]
        }
    }

    public func deleteVaultItem(_ itemID: VaultItemID) async throws {
        try await call { s in
            let i = try s.vaultIndex(itemID)
            s.state.vaultItems.remove(at: i)
            s.state.vaultUsernames[itemID] = nil
        }
    }

    public func vaultRequests(all: Bool) async throws -> [VaultRequest] {
        try await call { s in all ? s.state.vaultRequests : s.state.vaultRequests.filter { $0.status == .pending } }
    }

    public func fulfillVaultRequest(_ requestID: VaultRequestID, username: String, password: String, purpose: String?)
        async throws -> VaultRequest
    {
        let detector = secretDetector
        let request = try await call { s -> VaultRequest in
            let i = try s.vaultRequestIndex(requestID)
            let request = s.state.vaultRequests[i]
            guard request.status == .pending else { throw MockErrors.conflict("request already handled") }
            guard !password.isEmpty else { throw MockErrors.invalid("empty password") }
            let name = detector.uniqueVaultName(base: request.name, taken: s.state.vaultItems.map(\.name))
            let item = try s.createVaultItem(
                NewVaultItem(
                    name: name, purpose: purpose ?? request.purpose, username: username, password: password,
                    instanceIDs: [request.instanceID]))
            s.state.vaultRequests[i].status = .fulfilled
            s.state.vaultRequests[i].itemID = item.id
            s.state.vaultRequests[i].resolvedAt = Date()
            s.emit(
                .vaultFulfilled, payload: ["request_id": .string(requestID.rawValue), "name": .string(item.name)],
                runID: request.runID, instanceID: request.instanceID, at: Date())
            return s.state.vaultRequests[i]
        }
        if let runID = request.runID {
            play(DemoData.vaultResolvedScript(runID: runID, fulfilled: true), instanceID: request.instanceID)
        }
        return request
    }

    public func declineVaultRequest(_ requestID: VaultRequestID) async throws -> VaultRequest {
        let request = try await call { s -> VaultRequest in
            let i = try s.vaultRequestIndex(requestID)
            guard s.state.vaultRequests[i].status == .pending else {
                throw MockErrors.conflict("request already handled")
            }
            s.state.vaultRequests[i].status = .declined
            s.state.vaultRequests[i].resolvedAt = Date()
            let request = s.state.vaultRequests[i]
            s.emit(
                .vaultDeclined, payload: ["request_id": .string(requestID.rawValue), "name": .string(request.name)],
                runID: request.runID, instanceID: request.instanceID, at: Date())
            return request
        }
        if let runID = request.runID {
            play(DemoData.vaultResolvedScript(runID: runID, fulfilled: false), instanceID: request.instanceID)
        }
        return request
    }
}

// MARK: - 锁里的状态

private struct Subscriber: Sendable {
    let instanceID: InstanceID
    let continuation: AsyncStream<EventStreamElement>.Continuation
}

private struct Playback: Sendable {
    let runID: RunID?
    let task: Task<Void, Never>
}

/// 还没决定的审批对应的 agent 请求（决定后回放 `permission_resolved` 要用）。
private struct PendingPermission: Sendable {
    let requestID: String
    let toolCallID: String?
}

private struct Inner: Sendable {
    var state: MockState
    var latency: TimeInterval = 0
    var stepDelay: TimeInterval = 0.35
    var autoReply = true
    var failures: [ClientError] = []
    var scripts: [InstanceID: MockEventScript] = [:]
    var subscribers: [UUID: Subscriber] = [:]
    var playbacks: [UUID: Playback] = [:]
    var permissions: [ApprovalID: PendingPermission] = [:]
    /// 用户取消了的运行：回放中的脚本不再给它们出事件。
    var cancelledRuns: Set<RunID> = []

    init(state: MockState) {
        self.state = state
    }

    /// 把现有的未决审批和事件里的 `permission_requested` 对上（按运行和标题）。
    mutating func indexPendingPermissions() {
        for approval in state.approvals where approval.isPending {
            let requested = (state.events[approval.instanceID] ?? []).filter {
                $0.runID == approval.runID && $0.kind == .permissionRequested
            }
            for e in requested {
                guard case .permissionRequested(let p) = e.payload, p.title == approval.title else { continue }
                permissions[approval.id] = PendingPermission(
                    requestID: p.requestID, toolCallID: p.toolCall?["toolCallId"]?.stringValue)
            }
        }
    }

    func broadcast(_ element: EventStreamElement, to instanceID: InstanceID) {
        for sub in subscribers.values where sub.instanceID == instanceID {
            sub.continuation.yield(element)
        }
    }

    @discardableResult
    mutating func emit(
        _ kind: InstanceEventKind, payload: JSONValue, runID: RunID?, instanceID: InstanceID, at date: Date
    ) -> InstanceEvent {
        let event = InstanceEvent(
            instanceID: instanceID, seq: state.lastSeq(of: instanceID) + 1, runID: runID, kind: kind,
            payloadJSON: payload.compactString(), createdAt: date)
        state.events[instanceID, default: []].append(event)
        applySideEffects(of: event)
        broadcast(.event(event), to: instanceID)
        return event
    }

    /// 事件对状态的影响（服务端做的那部分）。
    private mutating func applySideEffects(of event: InstanceEvent) {
        if let i = state.instances.firstIndex(where: { $0.id == event.instanceID }) {
            state.instances[i].lastActiveAt = event.createdAt
        }
        let instanceName = state.instances.first { $0.id == event.instanceID }?.name ?? ""
        switch event.payload {
        case .runState(let p):
            guard let runID = event.runID, let i = state.runs.firstIndex(where: { $0.id == runID }) else { return }
            state.runs[i].state = p.state
            state.runs[i].stateReason = p.reason
            if let attempt = p.attempt { state.runs[i].attempt = attempt }
            if p.state == .running && state.runs[i].startedAt == nil { state.runs[i].startedAt = event.createdAt }
            guard p.state.isTerminal else { return }
            state.runs[i].finishedAt = event.createdAt
            // 运行结束时还没决定的审批一并作废，收件箱里的审批提醒标已读（和服务端的 cancel_run_approvals 一致；
            // 之后再决定返回 conflict）。
            for j in state.approvals.indices where state.approvals[j].runID == runID && state.approvals[j].isPending {
                state.approvals[j].state = .cancelled
                permissions[state.approvals[j].id] = nil
            }
            for j in state.inbox.indices where state.inbox[j].runID == runID && state.inbox[j].approvalID != nil {
                state.inbox[j].isRead = true
            }
            let run = state.runs[i]
            let text = (state.events[event.instanceID] ?? []).filter { $0.runID == runID && $0.kind == .agentMessage }
                .compactMap { e -> String? in
                    if case .message(let m) = e.payload { return m.text }
                    return nil
                }.joined()
            if !text.isEmpty { state.runs[i].summary = String(text.prefix(120)) }
            if p.state == .cancelled { return }
            let succeeded = p.state == .succeeded
            state.inbox.insert(
                InboxItem(
                    id: .random(), instanceID: run.instanceID, runID: run.id, planID: run.planID,
                    kind: succeeded ? .runFinished : .runFailed,
                    title: succeeded ? "\(instanceName) 已完成" : "\(instanceName) 运行失败",
                    body: succeeded ? (state.runs[i].summary ?? "") : (p.reason ?? ""), isAIGenerated: succeeded,
                    createdAt: event.createdAt), at: 0)
        case .permissionRequested(let p):
            guard let runID = event.runID else { return }
            let approval = Approval(
                id: .random(), runID: runID, instanceID: event.instanceID, title: p.title, options: p.options,
                toolCallJSON: p.toolCall?.compactString() ?? "{}", state: .pending,
                expiresAt: event.createdAt.addingTimeInterval(24 * 3600), createdAt: event.createdAt)
            state.approvals.append(approval)
            permissions[approval.id] = PendingPermission(
                requestID: p.requestID, toolCallID: p.toolCall?["toolCallId"]?.stringValue)
            state.inbox.insert(
                InboxItem(
                    id: .random(), instanceID: event.instanceID, runID: runID, approvalID: approval.id, kind: .approval,
                    title: "\(instanceName) 等你审批", body: p.title ?? "", isAIGenerated: p.title != nil,
                    createdAt: event.createdAt), at: 0)
        case .vaultRequested(let p):
            guard !state.vaultRequests.contains(where: { $0.id == p.requestID }) else { return }
            state.vaultRequests.append(
                VaultRequest(
                    id: p.requestID, instanceID: event.instanceID, runID: event.runID, name: p.name, purpose: p.purpose,
                    fields: p.fields, createdAt: event.createdAt,
                    expiresAt: event.createdAt.addingTimeInterval(24 * 3600)))
        case .artifactPublished(let p):
            guard let runID = event.runID, !state.artifacts.contains(where: { $0.id == p.artifactID }) else { return }
            let type = p.name.hasSuffix(".md") ? "text/markdown" : p.name.hasSuffix(".png") ? "image/png" : "text/plain"
            state.artifacts.append(
                Artifact(
                    id: p.artifactID, instanceID: event.instanceID, runID: runID, name: p.name, version: p.version,
                    contentType: type, size: p.size, createdAt: event.createdAt))
            state.artifactContents[p.artifactID] = Data("（演示内容）\(p.name)".utf8)
        case .other(let raw) where event.kind == .agentUsage:
            guard let runID = event.runID, let i = state.runs.firstIndex(where: { $0.id == runID }) else { return }
            let usage = raw?["raw"] ?? raw
            state.runs[i].tokensUsed +=
                (usage?["input_tokens"]?.intValue ?? 0) + (usage?["output_tokens"]?.intValue ?? 0)
        default:
            break
        }
    }

    // MARK: 查找

    func instanceIndex(_ id: InstanceID) throws -> Int {
        guard let i = state.instances.firstIndex(where: { $0.id == id }) else { throw MockErrors.notFound("instance") }
        return i
    }

    func runIndex(_ id: RunID) throws -> Int {
        guard let i = state.runs.firstIndex(where: { $0.id == id }) else { throw MockErrors.notFound("run") }
        return i
    }

    func planIndex(_ id: PlanID) throws -> Int {
        guard let i = state.plans.firstIndex(where: { $0.id == id }) else { throw MockErrors.notFound("plan") }
        return i
    }

    func channelIndex(_ id: ImChannelID) throws -> Int {
        guard let i = state.imChannels.firstIndex(where: { $0.id == id }) else {
            throw MockErrors.notFound("im channel")
        }
        return i
    }

    func vaultIndex(_ id: VaultItemID) throws -> Int {
        guard let i = state.vaultItems.firstIndex(where: { $0.id == id }) else {
            throw MockErrors.notFound("vault item")
        }
        return i
    }

    func vaultRequestIndex(_ id: VaultRequestID) throws -> Int {
        guard let i = state.vaultRequests.firstIndex(where: { $0.id == id }) else {
            throw MockErrors.notFound("vault request")
        }
        return i
    }

    // MARK: 操作

    func runs(of instanceID: InstanceID, limit: Int) -> [Run] {
        let runs = state.runs.filter { $0.instanceID == instanceID }.sorted { $0.createdAt > $1.createdAt }
        return Array(runs.prefix(max(0, limit)))
    }

    func inbox(before: InboxItemID?, limit: Int) -> [InboxItem] {
        let start = before.flatMap { id in state.inbox.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        guard start < state.inbox.count else { return [] }
        return Array(state.inbox[start...].prefix(max(0, limit)))
    }

    mutating func createRun(instanceID: InstanceID, prompt: String) throws -> Run {
        _ = try instanceIndex(instanceID)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw MockErrors.invalid("empty prompt") }
        let run = Run(
            id: .random(), instanceID: instanceID, source: .user, prompt: prompt, state: .queued, createdAt: Date())
        state.runs.append(run)
        return run
    }

    mutating func createVaultItem(_ item: NewVaultItem) throws -> VaultItem {
        guard !item.name.isEmpty, item.name == MockSecretDetector.sanitizeName(item.name) else {
            throw MockErrors.invalid("bad name \(item.name)")
        }
        guard !state.vaultItems.contains(where: { $0.name == item.name }) else {
            throw MockErrors.conflict("name \(item.name) is taken")
        }
        guard !item.password.isEmpty else { throw MockErrors.invalid("empty password") }
        let created = VaultItem(
            id: .random(), name: item.name, purpose: item.purpose, hasUsername: !item.username.isEmpty,
            instanceIDs: item.instanceIDs, createdAt: Date())
        state.vaultItems.append(created)
        if !item.username.isEmpty { state.vaultUsernames[created.id] = item.username }
        return created
    }

    /// 取消所有运行、暂停所有计划。返回结果和取消了的运行。
    mutating func stopAll() -> (StopAllResult, Set<RunID>) {
        let active = state.runs.filter(\.state.isActive)
        for run in active {
            cancelledRuns.insert(run.id)
            emit(
                .runState, payload: ["state": "cancelled", "reason": "stopped by user"], runID: run.id,
                instanceID: run.instanceID, at: Date())
        }
        var paused = 0
        for i in state.plans.indices where !state.plans[i].isPaused {
            state.plans[i].isPaused = true
            paused += 1
        }
        return (
            StopAllResult(runsCancelled: active.count, grantsRevoked: active.count, plansPaused: paused),
            Set(active.map(\.id))
        )
    }

    func usage(group: UsageGroup) -> UsageSummary {
        let total = state.dailyUsage.reduce(UsageBucket(key: "total")) { sum, b in
            UsageBucket(
                key: "total", requests: sum.requests + b.requests, inputTokens: sum.inputTokens + b.inputTokens,
                cacheReadTokens: sum.cacheReadTokens + b.cacheReadTokens,
                cacheWriteTokens: sum.cacheWriteTokens + b.cacheWriteTokens,
                outputTokens: sum.outputTokens + b.outputTokens,
                chargedTokens: sum.chargedTokens + b.chargedTokens,
                estimatedRequests: sum.estimatedRequests + b.estimatedRequests,
                failedRequests: sum.failedRequests + b.failedRequests)
        }
        func split(_ keys: [(String, Double)]) -> [UsageBucket] {
            keys.map { key, share in
                UsageBucket(
                    key: key, requests: Int(Double(total.requests) * share),
                    inputTokens: Int(Double(total.inputTokens) * share),
                    cacheReadTokens: Int(Double(total.cacheReadTokens) * share),
                    cacheWriteTokens: Int(Double(total.cacheWriteTokens) * share),
                    outputTokens: Int(Double(total.outputTokens) * share),
                    chargedTokens: Int(Double(total.chargedTokens) * share),
                    estimatedRequests: 0, failedRequests: Int(Double(total.failedRequests) * share))
            }
        }
        let buckets: [UsageBucket]
        switch group {
        case .day:
            buckets = state.dailyUsage
        case .instance:
            let ids = state.instances.map(\.id.rawValue)
            buckets = split(ids.enumerated().map { ($1, $0 == 0 ? 0.7 : 0.3 / Double(max(1, ids.count - 1))) })
        case .model:
            buckets = split([("anthropic/claude-sonnet-5-5", 0.65), ("deepseek/deepseek-v4-pro", 0.35)])
        case .credential:
            let ids = state.credentials.filter { !$0.isDisabled }.map(\.id.rawValue)
            buckets = split(ids.enumerated().map { ($1, $0 == 0 ? 0.65 : 0.35 / Double(max(1, ids.count - 1))) })
        }
        return UsageSummary(buckets: buckets, total: total)
    }
}

/// Mock 抛的错误，和服务端的错误码一致。
enum MockErrors {
    static func notFound(_ what: String) -> ClientError {
        .api(status: 404, code: .notFound, message: "\(what) not found", retryAfterSecs: nil)
    }

    static func conflict(_ message: String) -> ClientError {
        .api(status: 409, code: .conflict, message: message, retryAfterSecs: nil)
    }

    static func invalid(_ message: String) -> ClientError {
        .api(status: 422, code: .invalid, message: message, retryAfterSecs: nil)
    }

    /// 从 webhook 地址认出 IM 平台。
    static func imVendor(webhookURL: String) throws -> ImVendor {
        guard let url = URL(string: webhookURL), url.scheme == "https", let host = url.host else {
            throw invalid("webhook must be an https URL")
        }
        if host.hasSuffix("feishu.cn") { return .feishu }
        if host.hasSuffix("larksuite.com") { return .lark }
        if host == "qyapi.weixin.qq.com" { return .wecom }
        if host == "oapi.dingtalk.com" { return .dingtalk }
        throw invalid("unsupported webhook host \(host)")
    }
}
