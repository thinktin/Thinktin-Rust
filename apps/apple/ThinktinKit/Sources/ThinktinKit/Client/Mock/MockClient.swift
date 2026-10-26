import Foundation

/// 内存里的 `ClientProtocol` 实现，带演示数据（`DemoData`）。预览、快照测试、Linux 上的单元测试、
/// Debug 版 App（`THINKTIN_MOCK=1`）都用它。
///
/// - 状态可以直接读写（`state`、`update(_:)`），也可以整体换掉（`MockClient(state:)`）；
/// - 发消息（`sendMessage` / `createRun`）后自动播放一段 agent 回答（`DemoData.replyScript`），
///   审批、保险箱请求处理后接着播；`setScript(_:for:)` 设定下一次订阅时回放的事件；
/// - `failNext(with:)` 让下一次调用抛错（`failNext(_:with:)` 只拦某个方法的下一次）；`latency` 模拟网络延迟；
///   抛过 `upgradeRequired` 之后 `upgradeRequired()` 一直是 true（也可以直接设 `MockState.isUpgradeRequired`）；
/// - `deliverDeviceMessage(from:kind:body:)` 模拟电脑发来的消息，`resolveReport(_:resolution:)` 模拟运营处理了举报；
/// - `callCount(_:)` 数某个方法被调了几次（测试里确认“没调 setLocale”这类）；
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

    /// 只让这个方法的下一次调用抛错（别的方法照常），可以连续排几个。`method` 的写法和 `callCount(_:)` 一样，比如
    /// `"me()"`、`"setLocale(_:)"`。`failNext(with:)` 排着的先抛。
    public func failNext(_ method: String, with error: ClientError) {
        inner.withLock { $0.methodFailures[method, default: []].append(error) }
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

    /// 模拟另一台设备（比如在线的 Mac）发来一条消息，之后 `deviceMessages()` 能收到（不校验方向和签名）。
    @discardableResult
    public func deliverDeviceMessage(
        from deviceID: DeviceID, kind: DeviceMessageKind, body: JSONValue = [:], at date: Date = Date()
    ) -> DeviceMessage {
        inner.withLock { s in
            let message = DeviceMessage(
                id: .random(), fromDeviceID: deviceID, toDeviceID: s.state.session?.deviceID ?? DemoData.deviceID,
                kind: kind, bodyJSON: body.compactString(), createdAt: date)
            s.state.deviceMessages.append(message)
            return message
        }
    }

    /// 模拟运营处理了一条举报（`admin close-report`）：标成已处理、写上结果，并发一条收件箱通知。找不到时返回 nil。
    @discardableResult
    public func resolveReport(_ reportID: ContentReportID, resolution: String, at date: Date = Date())
        -> ContentReport?
    {
        inner.withLock { s in
            guard let i = s.state.reports.firstIndex(where: { $0.id == reportID }) else { return nil }
            s.state.reports[i].state = .closed
            s.state.reports[i].resolution = resolution
            s.state.reports[i].handledAt = date
            s.state.inbox.insert(
                InboxItem(
                    id: .random(), kind: .info, title: "举报已处理", body: "感谢你的举报，我们已经处理：\(resolution)",
                    createdAt: date), at: 0)
            return s.state.reports[i]
        }
    }

    /// 模拟平台判的审批超时（4.7）：审批变成已过期、收件箱里那一条标已读，运行日志里记一条 `permission_resolved`
    /// （shim 回的是 `by: user`、不带选项，平台加上 `approval_state: expired`，docs/agent-integration.md 第 6 节）。
    /// 不是待处理的、找不到的返回 nil。
    @discardableResult
    public func expireApproval(_ approvalID: ApprovalID, at date: Date = Date()) -> Approval? {
        inner.withLock { s in
            guard let i = s.state.approvals.firstIndex(where: { $0.id == approvalID }), s.state.approvals[i].isPending
            else { return nil }
            s.state.approvals[i].state = .expired
            s.state.approvals[i].decidedAt = date
            let approval = s.state.approvals[i]
            s.permissions[approvalID] = nil
            for j in s.state.inbox.indices where s.state.inbox[j].approvalID == approvalID {
                s.state.inbox[j].isRead = true
            }
            s.emit(
                .permissionResolved, payload: ["request_id": .string(approval.requestID), "by": "user"],
                runID: approval.runID, instanceID: approval.instanceID, at: date)
            return approval
        }
    }

    /// 某个方法被调了几次（包括被 `failNext` 拦下、没登录被拒的）。`method` 是方法名，和 `#function` 一样写，比如
    /// `"setLocale(_:)"`、`"me()"`。只数经过 Mock 的调用：`signedIn()`、`upgradeRequired()`、`subscribe` 不数。
    public func callCount(_ method: String) -> Int {
        inner.withLock { $0.callCounts[method] ?? 0 }
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

    /// `method` 是调用它的方法名（默认参数 `#function` 取的是调用方的名字），记进 `callCount(_:)`。
    private func call<R>(
        signedIn required: Bool = true, method: String = #function, _ body: (inout Inner) throws -> R
    ) async throws -> R {
        let latency = inner.withLock { $0.latency }
        if latency > 0 { try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        return try syncCall(signedIn: required, method: method, body)
    }

    private func syncCall<R>(
        signedIn required: Bool = true, method: String = #function, _ body: (inout Inner) throws -> R
    ) throws -> R {
        try inner.withLock { s in
            s.callCounts[method, default: 0] += 1
            var failure: ClientError?
            if !s.failures.isEmpty {
                failure = s.failures.removeFirst()
            } else if var queued = s.methodFailures[method], !queued.isEmpty {
                failure = queued.removeFirst()
                s.methodFailures[method] = queued.isEmpty ? nil : queued
            }
            if let failure {
                // 和 client-core 一样：任何请求说过版本太老，之后一直记着（11.8）。
                if failure.requiresUpgrade { s.state.isUpgradeRequired = true }
                throw failure
            }
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

    private func cancelAllPlayback() {
        let tasks = inner.withLock { s -> [Task<Void, Never>] in
            defer { s.playbacks.removeAll() }
            return s.playbacks.values.map(\.task)
        }
        for task in tasks { task.cancel() }
    }

    private func autoReply(to run: Run) {
        guard inner.withLock({ $0.autoReply }) else { return }
        play(DemoData.replyScript(for: run), instanceID: run.instanceID)
    }

    /// 等额度的运行马上接着跑（服务端的 `wake_waiting_runs(waiting_quota)`：加了 key、启用、放宽或取消每日上限、换 key、
    /// 改模型路由之后，7.11）。开着自动回答时从头播一遍回答；不然只记一条“开始”（之后的进展由测试自己播）。
    private func wakeRunsWaitingForQuota() {
        let (woken, replay) = inner.withLock { s -> ([Run], Bool) in
            let waiting = s.state.runs.filter { $0.state == .waitingQuota }
            if !s.autoReply {
                for run in waiting {
                    _ = s.emit(
                        .runState, payload: ["state": "starting"], runID: run.id, instanceID: run.instanceID, at: Date()
                    )
                }
            }
            return (waiting, s.autoReply)
        }
        guard replay else { return }
        for run in woken { play(DemoData.replyScript(for: run), instanceID: run.instanceID) }
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
            // 新用户的语言按请求的 Accept-Language 定（11.8，服务端的规则；认不出时不改）。
            if isNew, let locale = s.state.acceptLanguage.flatMap({ UserLocale(acceptLanguage: $0) }) {
                s.state.user.locale = locale
            }
            s.state.session = Session(
                userID: s.state.user.id, deviceID: DemoData.deviceID, accessToken: "mock-access-\(UUID().uuidString)",
                refreshToken: "mock-refresh-\(UUID().uuidString)")
            s.registerCurrentDevice(push: push?.channel)
            return LoginResult(user: s.state.user, isNewUser: isNew)
        }
    }

    /// 退出登录：服务端吊销这台设备（和 `revokeDevice` 当前这台一样）。
    public func logout() async throws {
        try await call(signedIn: false) { s in s.signOutLocally() }
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
        try await call { s in
            guard !push.token.isEmpty else { throw MockErrors.invalid("empty push token") }
            s.registerCurrentDevice(push: push.channel)
        }
    }

    public func stopAll() async throws -> StopAllResult {
        let (result, cancelled) = try await call { s in s.stopAll() }
        cancelPlayback(runIDs: cancelled)
        return result
    }

    public func signOutOtherDevices(stopAgents: Bool) async throws -> SignOutOthersResult {
        let (result, cancelled) = try await call { s -> (SignOutOthersResult, Set<RunID>) in
            let others = s.state.devices.map(\.id).filter { $0 != s.state.session?.deviceID }
            for id in others { s.removeDevice(id) }
            guard stopAgents else { return (SignOutOthersResult(devicesSignedOut: others.count), []) }
            let (stopped, cancelled) = s.stopAll()
            return (SignOutOthersResult(devicesSignedOut: others.count, stopped: stopped), cancelled)
        }
        cancelPlayback(runIDs: cancelled)
        return result
    }

    public func updateProfile(displayName: String?) async throws -> User {
        try await call { s in
            if let name = displayName, !(1...User.maxDisplayNameLength).contains(name.unicodeScalars.count) {
                throw MockErrors.invalid("display_name must be 1-\(User.maxDisplayNameLength) characters")
            }
            s.state.user.displayName = displayName
            return s.state.user
        }
    }

    /// 验证码固定是 `state.verificationCode`（和登录的一样）。
    public func sendSelfCode(purpose: SelfCodePurpose) async throws {
        try await call { s in _ = s.selfCodes.insert(purpose) }
    }

    /// 先要 `sendSelfCode(purpose: .deleteAccount)`。成功后除了 agent 目录和厂商，状态全部清空（缓存类方法返回空、
    /// 事件流收到 `signedOut`）；之后用同一个手机号登录算新用户。
    public func deleteAccount(code: String) async throws {
        try await call { s in
            guard s.selfCodes.contains(.deleteAccount), code == s.state.verificationCode else {
                throw MockErrors.invalid("wrong verification code")
            }
            s.eraseAccount()
        }
        cancelAllPlayback()
    }

    // MARK: 请求语言与版本

    /// 和 client-core 一样校验（`AcceptLanguage.validated`）；不对时原来的值不变。
    public func setAcceptLanguage(_ acceptLanguage: String?) throws {
        try syncCall(signedIn: false) { s in s.state.acceptLanguage = try AcceptLanguage.validated(acceptLanguage) }
    }

    public func upgradeRequired() -> Bool {
        inner.withLock { $0.state.isUpgradeRequired }
    }

    // MARK: 登录设备与设备消息

    public func devices() async throws -> [DeviceInfo] {
        try await call { s in s.devicesForDisplay() }
    }

    /// 吊销当前这台等于退出登录（会话、这台的实时活动一起清掉）。
    public func revokeDevice(_ deviceID: DeviceID) async throws {
        try await call { s in
            guard s.state.devices.contains(where: { $0.id == deviceID }) else { throw MockErrors.notFound("device") }
            if deviceID == s.state.session?.deviceID {
                s.signOutLocally()
            } else {
                s.removeDevice(deviceID)
            }
        }
    }

    public func sendDeviceMessage(to deviceID: DeviceID, kind: DeviceMessageKind, bodyJSON: String) async throws
        -> DeviceMessage
    {
        try await call { s in
            // 这两个 client-core 在发请求前就拒。
            guard kind.isKnown else {
                throw ClientError.invalidArgument(message: "unknown device message kind \(kind)")
            }
            guard JSONValue.parse(bodyJSON) != nil else {
                throw ClientError.invalidArgument(message: "body_json is not JSON")
            }
            guard bodyJSON.utf8.count <= DeviceMessage.maxBodyBytes else {
                throw MockErrors.invalid("body is larger than \(DeviceMessage.maxBodyBytes) bytes")
            }
            let from = try s.currentDeviceID()
            guard deviceID != from else { throw MockErrors.invalid("a device cannot message itself") }
            guard let sender = s.state.devices.first(where: { $0.id == from }),
                let recipient = s.state.devices.first(where: { $0.id == deviceID })
            else { throw MockErrors.notFound("device") }
            // 方向：电脑发的种类只能电脑发给手机，其余只能手机发给电脑。
            guard kind.isFromComputer == sender.isComputer, sender.isComputer != recipient.isComputer else {
                throw MockErrors.invalid(
                    "\(kind) cannot go from a \(sender.platform) device to a \(recipient.platform) device")
            }
            let message = DeviceMessage(
                id: .random(), fromDeviceID: from, toDeviceID: deviceID, kind: kind, bodyJSON: bodyJSON,
                createdAt: Date())
            s.state.deviceMessages.append(message)
            return message
        }
    }

    public func deviceMessages() async throws -> [DeviceMessage] {
        try await call { s in
            let me = try s.currentDeviceID()
            let now = Date()
            let pending = s.state.deviceMessages.filter { $0.toDeviceID == me && !$0.isExpired(now: now) }
            return Array(pending.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }.prefix(100))
        }
    }

    public func ackDeviceMessages(ids: [DeviceMessageID]) async throws -> Int {
        try await call { s in
            guard (1...DeviceMessage.maxAckCount).contains(ids.count) else {
                throw MockErrors.invalid("give 1 to \(DeviceMessage.maxAckCount) ids")
            }
            let me = try s.currentDeviceID()
            let acked = Set(ids)
            let before = s.state.deviceMessages.count
            s.state.deviceMessages.removeAll { $0.toDeviceID == me && acked.contains($0.id) }
            return before - s.state.deviceMessages.count
        }
    }

    // MARK: 实时活动

    public func setLiveActivityStartToken(_ token: String?) async throws {
        try await call { s in
            guard let token else {
                s.state.liveActivityStartToken = nil
                return
            }
            guard LiveActivityToken.isValid(token) else { throw MockErrors.badLiveActivityToken }
            try s.requireLiveActivityDevice()
            s.state.liveActivityStartToken = token
        }
    }

    /// 后台推送的次数记在 `state.liveActivities[runID].pushCount`：换令牌加一，同一个令牌再登记不变。
    public func registerLiveActivity(runID: RunID, token: String) async throws {
        try await call { s in
            guard LiveActivityToken.isValid(token) else { throw MockErrors.badLiveActivityToken }
            let now = Date()
            let run = s.state.runs[try s.runIndex(runID)]
            guard !LiveActivityLimits.isTooLateToRegister(run, now: now) else {
                throw MockErrors.invalid("the run has already finished")
            }
            try s.requireLiveActivityDevice()
            let open = s.state.liveActivities.filter { $0.key != runID && $0.value.isOpen(now: now) }.count
            guard open < LiveActivityLimits.maxOpenPerDevice else {
                throw MockErrors.invalid(
                    "at most \(LiveActivityLimits.maxOpenPerDevice) live activities at a time on one device")
            }
            let existing = s.state.liveActivities[runID]
            // 同一个令牌：什么都不变（不重发；关掉了的也不重新打开）。
            if existing?.token == token { return }
            s.state.liveActivities[runID] = MockLiveActivity(
                token: token, registeredAt: now, pushCount: (existing?.pushCount ?? 0) + 1)
        }
    }

    public func endLiveActivity(runID: RunID) async throws {
        try await call { s in s.state.liveActivities[runID]?.isEnded = true }
    }

    // MARK: agent 与实例

    /// 介绍和许可说明按请求语言给（11.8）：`acceptLanguage` 认出是英文时换成英文文案（`DemoData` 里有的）。
    public func agents() async throws -> [AgentInfo] {
        try await call { s in
            guard s.state.requestLocale == .en else { return s.state.agents }
            return s.state.agents.map(DemoData.inEnglish)
        }
    }

    public func instances() async throws -> [Instance] {
        try await call { s in s.state.instances }
    }

    public func instance(_ instanceID: InstanceID) async throws -> Instance {
        try await call { s in s.state.instances[try s.instanceIndex(instanceID)] }
    }

    public func cachedInstances() throws -> [Instance] {
        try syncCall(signedIn: false) { s in s.state.instances }
    }

    /// 和服务端一样先查 agent、名字、接入方式，再查实例数上限（`MockState.instancesPerUser`，到了抛 409 `instance_limit`）。
    public func adopt(agentID: AgentID, name: String, harness: String?) async throws -> Instance {
        try await call { s in
            _ = try s.checkAdoption(agentID: agentID, name: name, harness: harness)
            try s.checkInstanceCapacity(adding: 1)
            return try s.adoptInstance(agentID: agentID, name: name, harness: harness)
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

    /// 整体替换。key 要是自己的、没删除的；新引用的不能是停用的（422），实例原来就用着的停用 key（主路由或降级链，
    /// 任何别名）可以留着（11.9，服务端照样在运行时跳过它），所以从别名里去掉别的 key 不会因为它保存不了。
    public func setModelRoutes(instanceID: InstanceID, routes: [ModelRoute]) async throws {
        try await call { s in
            _ = try s.instanceIndex(instanceID)
            guard Set(routes.map(\.alias)).count == routes.count else { throw MockErrors.invalid("duplicate alias") }
            let kept = Set(
                (s.state.routes[instanceID] ?? []).flatMap { [$0.credentialID] + $0.fallbacks.map(\.credentialID) })
            for r in routes {
                guard !r.alias.isEmpty else { throw MockErrors.invalid("empty alias") }
                guard r.fallbacks.count <= ModelRoute.maxFallbacks else {
                    throw MockErrors.invalid("too many fallbacks")
                }
                for id in [r.credentialID] + r.fallbacks.map(\.credentialID) {
                    guard let key = s.state.credentials.first(where: { $0.id == id }) else {
                        throw MockErrors.invalid("credential \(id) is not usable")
                    }
                    if key.isDisabled && !kept.contains(id) { throw MockErrors.invalid("credential \(id) is disabled") }
                }
            }
            s.state.routes[instanceID] = routes
        }
        // 换了 key 或者加了备用 key：等额度的运行接着跑。
        wakeRunsWaitingForQuota()
    }

    /// 和服务端一致（11.9）：模型别名一起删（只有它用着的 key 之后能删了）；它自己的计划一起删掉（服务端是标记删除，
    /// 列表和详情里都没有了，Mock 直接拿掉）；别的实例的流水线计划有一步在它上面、正在生效的（没暂停、不在等确认，服务端的
    /// `status = 'active'`）暂停，已经暂停、等确认的不动；之后恢复、确认都报 409，改了步骤才行（`setPlanPaused`、
    /// `confirmPlan`）；删掉的实例自动移出团队（团队留着）。
    public func deleteInstance(_ instanceID: InstanceID) async throws {
        try await call { s in
            let i = try s.instanceIndex(instanceID)
            s.state.instances.remove(at: i)
            s.state.routes[instanceID] = nil
            s.state.plans.removeAll { $0.instanceID == instanceID }
            for p in s.state.plans.indices
            where !s.state.plans[p].isPaused && !s.state.plans[p].awaitingConfirmation
                && s.state.plans[p].steps.contains(where: { $0.instanceID == instanceID })
            {
                s.state.plans[p].isPaused = true
            }
            for t in s.state.teams.indices { s.state.teams[t].members.removeAll { $0.instanceID == instanceID } }
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

    public func olderRuns(instanceID: InstanceID, before: RunID, limit: Int) async throws -> [Run] {
        try await call { s in
            _ = try s.instanceIndex(instanceID)
            let all = s.sortedRuns(of: instanceID)
            guard let k = all.firstIndex(where: { $0.id == before }) else { throw MockErrors.notFound("run") }
            return Array(all[(k + 1)...].prefix(max(0, limit)))
        }
    }

    /// 跨实例，新的在前（同一时刻的按 id 排）。`before` 按它在全部运行里的位置往后数（它自己现在不满足条件也行，
    /// 和服务端按 id 比较一样）；找不到这个运行时返回空。`limit` 夹到 1…200。
    public func listRuns(filter: RunFilter, before: RunID?, limit: Int) async throws -> [Run] {
        try await call { s in
            var all = s.state.runs.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }[...]
            if let before {
                guard let k = all.firstIndex(where: { $0.id == before }) else { return [] }
                all = all[(k + 1)...]
            }
            return Array(all.filter(filter.matches).prefix(RunFilter.clampedLimit(limit)))
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

    public func instanceArtifacts(_ instanceID: InstanceID, limit: Int) async throws -> [Artifact] {
        try await call { s in
            _ = try s.instanceIndex(instanceID)
            let list = s.state.artifacts.filter { $0.instanceID == instanceID }
                .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            return Array(list.prefix(min(max(limit, 1), Artifact.maxListLimit)))
        }
    }

    public func artifactContent(_ artifactID: ArtifactID) async throws -> Data {
        try await call { s in
            guard let data = s.state.artifactContents[artifactID] else { throw MockErrors.notFound("artifact") }
            return data
        }
    }

    public func deleteArtifact(_ artifactID: ArtifactID) async throws {
        try await call { s in
            guard let i = s.state.artifacts.firstIndex(where: { $0.id == artifactID }) else {
                throw MockErrors.notFound("artifact")
            }
            s.state.artifacts.remove(at: i)
            s.state.artifactContents[artifactID] = nil
        }
    }

    // MARK: 事件流

    public func subscribe(instanceID: InstanceID, afterSeq: UInt64?, listener: any EventListening) throws
        -> EventSubscriptionHandle
    {
        let (stream, continuation) = AsyncStream.makeStream(of: EventStreamElement.self, bufferingPolicy: .unbounded)
        let id = UUID()
        let script = try syncCall(signedIn: false) { s -> MockEventScript? in
            // 版本太老（11.8）：和 client-core 一样不再连，直接以 upgradeRequired 结束。
            guard !s.state.isUpgradeRequired else {
                continuation.yield(.status(.upgradeRequired))
                continuation.finish()
                return nil
            }
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

    /// `beforeSeq` 之前的最后 `limit` 条，旧的在前（演示数据都算在缓存里，不限 2000 条）；没登录时返回空。
    public func cachedEventsBefore(instanceID: InstanceID, beforeSeq: UInt64?, limit: Int) throws -> [InstanceEvent] {
        try syncCall(signedIn: false) { s in
            guard s.state.session != nil else { return [] }
            let older = (s.state.events[instanceID] ?? []).filter { e in beforeSeq.map { e.seq < $0 } ?? true }
            return Array(older.suffix(max(0, limit)))
        }
    }

    // MARK: 审批

    public func approvals() async throws -> [Approval] {
        try await call { s in s.state.approvals.filter(\.isPending) }
    }

    /// 什么状态都能查；没有这条审批抛 `not_found`（服务端对别人的审批也是 `not_found`）。
    public func getApproval(_ approvalID: ApprovalID) async throws -> Approval {
        try await call { s in
            guard let approval = s.state.approvals.first(where: { $0.id == approvalID }) else {
                throw MockErrors.notFound("approval")
            }
            return approval
        }
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
            let now = Date()
            s.state.approvals[i].state = option.kind.isAllow ? .approved : .rejected
            s.state.approvals[i].decidedOption = optionID
            s.state.approvals[i].decidedAt = now
            let approval = s.state.approvals[i]
            s.emit(
                .approvalDecided,
                payload: [
                    "approval_id": .string(approvalID.rawValue), "state": .string(approval.state.rawValue),
                    "option_id": .string(optionID), "request_id": .string(approval.requestID),
                    "attempt": .number(Double(approval.attempt)),
                ], runID: approval.runID, instanceID: approval.instanceID, at: now)
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

    /// 和接口一致（11.8）：列表里也带触发器、步骤、下一次运行的时间和失效的触发器数。
    public func plans(instanceID: InstanceID?) async throws -> [Plan] {
        try await call { s in
            s.state.plans.filter { instanceID == nil || $0.instanceID == instanceID }.map(Inner.planView)
        }
    }

    public func getPlan(_ planID: PlanID) async throws -> Plan {
        try await call { s in Inner.planView(s.state.plans[try s.planIndex(planID)]) }
    }

    public func createPlan(_ plan: NewPlan) async throws -> Plan {
        try await call { s in
            _ = try s.instanceIndex(plan.instanceID)
            let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            try s.checkPlan(title: title, goal: goal, policy: plan.policy, catchUp: plan.catchUp, steps: plan.steps)
            // 和服务端一样可以没有触发规则（团队建的流水线先建好，再去计划详情加）。
            guard plan.triggers.count <= Plan.maxTriggers else {
                throw MockErrors.invalid("at most \(Plan.maxTriggers) triggers")
            }
            let created = Plan(
                id: .random(), instanceID: plan.instanceID, title: title, goal: goal, createdBy: .user, revision: 1,
                policy: plan.policy ?? PlanPolicy(), catchUp: plan.catchUp ?? .default, createdAt: Date(),
                triggers: try plan.triggers.map { try Inner.makeTrigger($0) }, steps: plan.steps)
            s.state.plans.append(created)
            return Inner.planView(created)
        }
    }

    /// 只改给了的字段，版本号加一（agent 改计划时的“重新待确认”不模拟）。
    public func updatePlan(_ planID: PlanID, change: PlanChange) async throws -> Plan {
        try await call { s in
            let i = try s.planIndex(planID)
            var plan = change.applied(to: s.state.plans[i])
            plan.title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.goal = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            try s.checkPlan(
                title: plan.title, goal: plan.goal, policy: change.policy, catchUp: change.catchUp, steps: change.steps)
            plan.revision += 1
            s.state.plans[i] = plan
            return Inner.planView(plan)
        }
    }

    public func addTrigger(planID: PlanID, schedule: Schedule) async throws -> Trigger {
        try await call { s in
            let trigger = try Inner.makeTrigger(schedule)
            let i = try s.planIndex(planID)
            guard s.state.plans[i].triggers.count < Plan.maxTriggers else {
                throw MockErrors.invalid("at most \(Plan.maxTriggers) triggers")
            }
            s.state.plans[i].triggers.append(trigger)
            return trigger
        }
    }

    public func deleteTrigger(_ triggerID: TriggerID) async throws {
        try await call { s in
            guard let i = s.state.plans.firstIndex(where: { $0.triggers.contains { $0.id == triggerID } }) else {
                throw MockErrors.notFound("trigger")
            }
            s.state.plans[i].triggers.removeAll { $0.id == triggerID }
        }
    }

    /// 恢复时流水线有一步在已删除的实例上抛 409（11.9：先改步骤）；暂停不查。
    public func setPlanPaused(_ planID: PlanID, paused: Bool) async throws -> Plan {
        try await call { s in
            let i = try s.planIndex(planID)
            if !paused { try s.refuseDeletedSteps(s.state.plans[i]) }
            if s.state.plans[i].awaitingConfirmation && !paused {
                throw MockErrors.conflict("the plan is awaiting confirmation")
            }
            s.state.plans[i].isPaused = paused
            return Inner.planView(s.state.plans[i])
        }
    }

    /// 流水线有一步在已删除的实例上时抛 409（11.9：先改步骤）。
    public func confirmPlan(_ planID: PlanID, revision: Int) async throws -> Plan {
        try await call { s in
            let i = try s.planIndex(planID)
            try s.refuseDeletedSteps(s.state.plans[i])
            guard s.state.plans[i].awaitingConfirmation else { throw MockErrors.conflict("nothing to confirm") }
            guard s.state.plans[i].revision == revision else { throw MockErrors.conflict("the plan changed") }
            s.state.plans[i].awaitingConfirmation = false
            return Inner.planView(s.state.plans[i])
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

    public func inboxItem(_ itemID: InboxItemID) async throws -> InboxItem {
        try await call { s in s.state.inbox[try s.inboxIndex(itemID)] }
    }

    public func markInboxUnread(_ itemID: InboxItemID) async throws -> Int {
        try await call { s in
            s.state.inbox[try s.inboxIndex(itemID)].isRead = false
            return s.state.unreadCount
        }
    }

    public func deleteInboxItem(_ itemID: InboxItemID) async throws {
        try await call { s in _ = s.state.inbox.remove(at: try s.inboxIndex(itemID)) }
    }

    // MARK: 团队与团队模板

    public func teams() async throws -> [Team] {
        try await call { s in s.state.teams.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }
    }

    public func team(_ teamID: TeamID) async throws -> Team {
        try await call { s in s.state.teams[try s.teamIndex(teamID)] }
    }

    public func createTeam(name: String, members: [TeamMember]) async throws -> Team {
        try await call { s in
            let members = try s.checkTeamMembers(members)
            let team = Team(id: .random(), name: try Inner.checkName(name), members: members, createdAt: Date())
            s.state.teams.append(team)
            return team
        }
    }

    public func updateTeam(_ teamID: TeamID, name: String?, members: [TeamMember]?) async throws -> Team {
        try await call { s in
            let members = try members.map { try s.checkTeamMembers($0) }
            let name = try name.map { try Inner.checkName($0) }
            let i = try s.teamIndex(teamID)
            if let name { s.state.teams[i].name = name }
            if let members { s.state.teams[i].members = members }
            return s.state.teams[i]
        }
    }

    public func deleteTeam(_ teamID: TeamID) async throws {
        try await call { s in _ = s.state.teams.remove(at: try s.teamIndex(teamID)) }
    }

    public func teamTemplates() async throws -> [TeamTemplate] {
        try await call { s in s.state.teamTemplates.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }
    }

    public func createTeamTemplate(name: String, members: [TemplateMember]) async throws -> TeamTemplate {
        try await call { s in
            let members = try s.checkTemplateMembers(members)
            let template = TeamTemplate(
                id: .random(), name: try Inner.checkName(name), members: members, createdAt: Date())
            s.state.teamTemplates.append(template)
            return template
        }
    }

    public func createTeamTemplateFromTeam(name: String, teamID: TeamID) async throws -> TeamTemplate {
        try await call { s in
            let name = try Inner.checkName(name)
            let team = s.state.teams[try s.teamIndex(teamID)]
            // 每个成员记下它的 agent、接入方式、名字、角色。
            var members: [TemplateMember] = []
            for m in team.members {
                let instance = s.state.instances[try s.instanceIndex(m.instanceID)]
                members.append(
                    TemplateMember(
                        agentID: instance.agentID, harness: instance.harness, name: instance.name, role: m.role))
            }
            let template = TeamTemplate(
                id: .random(), name: name, members: try s.checkTemplateMembers(members), createdAt: Date())
            s.state.teamTemplates.append(template)
            return template
        }
    }

    public func deleteTeamTemplate(_ templateID: TeamTemplateID) async throws {
        try await call { s in _ = s.state.teamTemplates.remove(at: try s.templateIndex(templateID)) }
    }

    /// 每个成员新领养一个实例（没有模型路由），再编成团队。和服务端一样全成或全不成（11.9）：先查团队名（422），
    /// 再查放不放得下整个团队（实例数上限，409 `instance_limit`），再查每个成员，都过了才领养，不会留下半个团队的实例。
    public func adoptTeamTemplate(_ templateID: TeamTemplateID, name: String?) async throws -> Team {
        try await call { s in
            let template = s.state.teamTemplates[try s.templateIndex(templateID)]
            let teamName = try Inner.checkName(name ?? template.name)
            try s.checkInstanceCapacity(adding: template.members.count)
            for m in template.members { _ = try s.checkAdoption(agentID: m.agentID, name: m.name, harness: m.harness) }
            var members: [TeamMember] = []
            for (i, m) in template.members.enumerated() {
                let instance = try s.adoptInstance(agentID: m.agentID, name: m.name, harness: m.harness)
                members.append(TeamMember(instanceID: instance.id, role: m.isLead ? .lead : .member, position: i))
            }
            let team = Team(id: .random(), name: teamName, members: members, createdAt: Date())
            s.state.teams.append(team)
            return team
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

    /// 和服务端一样拒收这家的订阅类 key、填了套餐专用地址的（11.9 起厂商表带着前缀和地址，按 `MockState.vendors` 查）。
    public func addCredential(_ credential: NewCredential) async throws -> Credential {
        let added = try await call { s in
            let key = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count >= 8 else { throw MockErrors.invalid("api key is too short") }
            let vendor = s.state.vendors.first { $0.id == credential.vendor }
            try Inner.checkSubscriptionKey(key, vendor: vendor)
            let bases = [
                ("anthropic_base", credential.anthropicBase), ("openai_base", credential.openaiBase),
                ("responses_base", credential.responsesBase),
            ]
            for case (let field, let base?) in bases {
                if let plan = VendorInfo.planOnlyBase(of: base, vendors: s.state.vendors) {
                    throw MockErrors.invalid(
                        "\(field): \(plan) is a coding or subscription plan address, which only works in the vendor's "
                            + "own tools; use the pay-as-you-go address")
                }
            }
            if vendor == nil {
                guard credential.vendor == NewCredential.customVendor,
                    credential.anthropicBase != nil || credential.openaiBase != nil || credential.responsesBase != nil
                else { throw MockErrors.invalid("unknown vendor \(credential.vendor)") }
            }
            let label = credential.label.isEmpty ? (vendor?.name ?? credential.vendor) : credential.label
            let created = Credential(
                id: .random(), vendor: credential.vendor, label: label, last4: String(key.suffix(4)),
                dailyTokenLimit: credential.dailyTokenLimit, createdAt: Date(),
                protocols: credential.expectedProtocols(vendors: s.state.vendors))
            s.state.credentials.append(created)
            return created
        }
        wakeRunsWaitingForQuota()
        return added
    }

    public func updateCredential(_ credentialID: CredentialID, label: String?, disabled: Bool?) async throws
        -> Credential
    {
        let updated = try await call { s in
            let i = try s.credentialIndex(credentialID)
            if let label, label.unicodeScalars.count > Credential.maxLabelLength {
                throw MockErrors.invalid("label must be 0-\(Credential.maxLabelLength) characters")
            }
            if let label { s.state.credentials[i].label = label }
            if let disabled { s.state.credentials[i].isDisabled = disabled }
            return s.state.credentials[i]
        }
        // 重新启用了：等额度的运行接着跑。
        if disabled == false { wakeRunsWaitingForQuota() }
        return updated
    }

    /// 和服务端一样（11.9）：nil 取消上限；0、超出范围抛 invalid（先查这个，再查 key 在不在）。放宽或取消上限时
    /// 等额度的运行接着跑。
    public func setCredentialDailyLimit(_ credentialID: CredentialID, dailyTokenLimit: UInt64?) async throws
        -> Credential
    {
        let (changed, raised) = try await call { s -> (Credential, Bool) in
            var limit: Int?
            if let dailyTokenLimit {
                guard dailyTokenLimit > 0 else { throw MockErrors.invalid("daily_token_limit must be positive") }
                // 服务端存成 i64：超过 Int64.max（64 位平台上就是 Int.max）的不收。
                guard let value = Int(exactly: dailyTokenLimit) else {
                    throw MockErrors.invalid("daily_token_limit too large: \(dailyTokenLimit)")
                }
                limit = value
            }
            let i = try s.credentialIndex(credentialID)
            let old = s.state.credentials[i].dailyTokenLimit
            s.state.credentials[i].dailyTokenLimit = limit
            let raised: Bool =
                switch (old, limit) {
                case (.some, nil): true
                case (.some(let old), .some(let new)): new > old
                default: false
                }
            return (s.state.credentials[i], raised)
        }
        if raised { wakeRunsWaitingForQuota() }
        return changed
    }

    public func replaceCredentialSecret(_ credentialID: CredentialID, apiKey: String) async throws -> Credential {
        let replaced = try await call { s in
            let i = try s.credentialIndex(credentialID)
            guard (8...4096).contains(apiKey.utf8.count), !apiKey.contains(where: { $0.isWhitespace }) else {
                throw MockErrors.invalid("api_key must be 8-4096 bytes without spaces")
            }
            let vendor = s.state.vendors.first { $0.id == s.state.credentials[i].vendor }
            try Inner.checkSubscriptionKey(apiKey, vendor: vendor)
            s.state.credentials[i].last4 = String(apiKey.suffix(4))
            return s.state.credentials[i]
        }
        wakeRunsWaitingForQuota()
        return replaced
    }

    /// 还有实例的别名（主路由或降级链）用着时抛 409（和服务端一样，已删除实例的别名不算：删除实例时一起删掉了）。
    public func deleteCredential(_ credentialID: CredentialID) async throws {
        try await call { s in
            let i = try s.credentialIndex(credentialID)
            let live = Set(s.state.instances.filter { $0.state != .deleted }.map(\.id))
            let used = s.state.routes.filter { live.contains($0.key) }.values.joined().reduce(0) { n, route in
                n + (route.credentialID == credentialID ? 1 : 0)
                    + route.fallbacks.filter { $0.credentialID == credentialID }.count
            }
            guard used == 0 else { throw MockErrors.conflict("credential is used by \(used) model route(s)") }
            s.state.credentials.remove(at: i)
        }
    }

    // MARK: 内容举报

    public func reportContent(
        runID: RunID, eventSeq: UInt64?, artifactID: ArtifactID?, reason: ReportReason, note: String?
    ) async throws -> ContentReport {
        try await call { s in
            // client-core 发请求前就拒不认识的原因。
            guard reason.isKnown else { throw ClientError.invalidArgument(message: "unknown report reason \(reason)") }
            let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNote = (note?.isEmpty ?? true) ? nil : note
            if let trimmedNote, trimmedNote.unicodeScalars.count > ContentReport.maxNoteLength {
                throw MockErrors.invalid("note must be 1-\(ContentReport.maxNoteLength) characters")
            }
            // 和服务端一致：限流在查找之前，再举报同一条也算一次。
            let now = Date()
            s.reportAttempts.removeAll { now.timeIntervalSince($0) >= 3600 }
            if s.reportAttempts.count >= ContentReport.maxPerHour, let oldest = s.reportAttempts.first {
                let wait = Int((3600 - now.timeIntervalSince(oldest)).rounded(.up))
                throw MockErrors.rateLimited("too many reports", retryAfter: max(1, wait))
            }
            s.reportAttempts.append(now)
            let run = s.state.runs[try s.runIndex(runID)]
            if let seq = eventSeq,
                !(s.state.events[run.instanceID] ?? []).contains(where: { $0.seq == seq && $0.runID == runID })
            {
                throw MockErrors.notFound("event")
            }
            if let artifactID,
                !s.state.artifacts.contains(where: { $0.id == artifactID && $0.instanceID == run.instanceID })
            {
                throw MockErrors.notFound("artifact")
            }
            // 同一条内容还有待处理的举报：返回那一条。
            if let existing = s.state.reports.first(where: {
                $0.isOpen && $0.runID == runID && $0.eventSeq == eventSeq && $0.artifactID == artifactID
            }) {
                return existing
            }
            let report = ContentReport(
                id: .random(), runID: runID, instanceID: run.instanceID, eventSeq: eventSeq, artifactID: artifactID,
                reason: reason, note: trimmedNote, createdAt: now)
            s.state.reports.insert(report, at: 0)
            return report
        }
    }

    public func reports() async throws -> [ContentReport] {
        // 排序是稳定的：同一时刻的保持“新的在前”的存放顺序。
        try await call { s in Array(s.state.reports.sorted { $0.createdAt > $1.createdAt }.prefix(100)) }
    }

    // MARK: IM 渠道

    public func imChannels() async throws -> [ImChannel] {
        try await call { s in s.state.imChannels }
    }

    public func addImChannel(_ channel: NewImChannel) async throws -> ImChannel {
        try await call { s in
            let (vendor, token) = try MockErrors.imWebhook(channel.webhookURL, secret: channel.secret)
            if ImChannelRules.checkLabel(channel.label) != nil {
                throw MockErrors.invalid("label must be 0-64 characters")
            }
            if let events = channel.events, events.isEmpty {
                throw MockErrors.invalid("events must name at least one of run_finished, run_failed, approval")
            }
            guard s.state.imChannels.count < ImChannelRules.maxChannels else {
                throw MockErrors.invalid("at most \(ImChannelRules.maxChannels) IM channels per account")
            }
            let created = ImChannel(
                id: .random(), vendor: vendor, label: channel.label, hint: ImChannelRules.hint(token),
                hasSecret: !(channel.secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                events: channel.events ?? ImEvent.knownCases, createdAt: Date())
            s.state.imChannels.append(created)
            return created
        }
    }

    public func updateImChannel(_ channelID: ImChannelID, label: String?, events: [ImEvent]?, enabled: Bool?)
        async throws -> ImChannel
    {
        try await call { s in
            if let label, ImChannelRules.checkLabel(label) != nil {
                throw MockErrors.invalid("label must be 0-64 characters")
            }
            if let events, events.isEmpty {
                throw MockErrors.invalid("events must name at least one of run_finished, run_failed, approval")
            }
            let i = try s.channelIndex(channelID)
            if let label { s.state.imChannels[i].label = label }
            if let events { s.state.imChannels[i].events = events }
            if let enabled { s.state.imChannels[i].isEnabled = enabled }
            return s.state.imChannels[i]
        }
    }

    /// 换地址：清掉之前的错误；机器人失效被后台停掉的（Mock 里按“关着、有错误”算）重新打开，用户自己关的还关着。
    public func replaceImWebhook(_ channelID: ImChannelID, webhookURL: String, secret: String?) async throws
        -> ImChannel
    {
        try await call { s in
            let (vendor, token) = try MockErrors.imWebhook(webhookURL, secret: secret)
            let i = try s.channelIndex(channelID)
            let wasAutoDisabled = !s.state.imChannels[i].isEnabled && s.state.imChannels[i].lastError != nil
            s.state.imChannels[i].vendor = vendor
            s.state.imChannels[i].hint = ImChannelRules.hint(token)
            s.state.imChannels[i].hasSecret = !(secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            s.state.imChannels[i].lastError = nil
            if wasAutoDisabled { s.state.imChannels[i].isEnabled = true }
            return s.state.imChannels[i]
        }
    }

    /// 测试消息：关着的不发；每小时最多 10 条（多了 429）。
    public func testImChannel(_ channelID: ImChannelID) async throws {
        try await call { s in
            let i = try s.channelIndex(channelID)
            guard s.state.imChannels[i].isEnabled else {
                throw MockErrors.invalid("the channel is turned off; turn it on first")
            }
            let now = Date()
            s.state.imTests = s.state.imTests.filter { now.timeIntervalSince($0) < 3600 }
            guard s.state.imTests.count < ImChannelRules.testsPerHour else {
                throw MockErrors.rateLimited("too many IM test messages", retryAfter: 3600)
            }
            s.state.imTests.append(now)
            s.state.imChannels[i].lastSentAt = now
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
            if let purpose = change.purpose { try Inner.checkVaultText(purpose, max: VaultRules.maxPurpose) }
            if let username = change.username { try Inner.checkVaultText(username, max: VaultRules.maxUsername) }
            if let password = change.password { try Inner.checkVaultPassword(password) }
            if let ids = change.instanceIDs, ids.count > VaultRules.maxInstances {
                throw MockErrors.invalid("at most \(VaultRules.maxInstances) instance_ids")
            }
            if let purpose = change.purpose {
                s.state.vaultItems[i].purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            }
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
            try Inner.checkVaultText(username, max: VaultRules.maxUsername)
            try Inner.checkVaultPassword(password)
            if let purpose { try Inner.checkVaultText(purpose, max: VaultRules.maxPurpose) }
            guard request.status == .pending else { throw MockErrors.conflict("request already handled") }
            let item: VaultItem
            // 和服务端一样：已经有同名的条目就更新它（换账号密码、用途；限定了实例的把这个实例加上），没有才新建。
            if let j = s.state.vaultItems.firstIndex(where: { $0.name == request.name }) {
                s.state.vaultItems[j].purpose = (purpose ?? request.purpose).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                s.state.vaultItems[j].hasUsername = !username.isEmpty
                s.state.vaultUsernames[s.state.vaultItems[j].id] = username.isEmpty ? nil : username
                if !s.state.vaultItems[j].instanceIDs.isEmpty,
                    !s.state.vaultItems[j].instanceIDs.contains(request.instanceID)
                {
                    s.state.vaultItems[j].instanceIDs.append(request.instanceID)
                }
                s.state.vaultItems[j].updatedAt = Date()
                item = s.state.vaultItems[j]
            } else {
                item = try s.createVaultItem(
                    NewVaultItem(
                        name: request.name, purpose: purpose ?? request.purpose, username: username, password: password,
                        instanceIDs: [request.instanceID]))
            }
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
    /// 只拦某个方法的错误（`failNext(_:with:)`），按方法名。
    var methodFailures: [String: [ClientError]] = [:]
    var scripts: [InstanceID: MockEventScript] = [:]
    var subscribers: [UUID: Subscriber] = [:]
    var playbacks: [UUID: Playback] = [:]
    var permissions: [ApprovalID: PendingPermission] = [:]
    /// 用户取消了的运行：回放中的脚本不再给它们出事件。
    var cancelledRuns: Set<RunID> = []
    /// 发过验证码的用途（`sendSelfCode`），用掉一次就删。
    var selfCodes: Set<SelfCodePurpose> = []
    /// 最近一小时的举报时间（每人每小时 30 次）。
    var reportAttempts: [Date] = []
    /// 每个方法被调了几次（`MockClient.callCount(_:)`）。
    var callCounts: [String: Int] = [:]

    init(state: MockState) {
        self.state = state
    }

    /// 把现有的未决审批和事件里的 `permission_requested` 对上：有审批 id 的按它，否则按请求 id（和尝试），
    /// 老数据（审批没有请求 id）按运行和标题。
    mutating func indexPendingPermissions() {
        for approval in state.approvals where approval.isPending {
            let requested = (state.events[approval.instanceID] ?? []).filter {
                $0.runID == approval.runID && $0.kind == .permissionRequested
            }
            for e in requested {
                guard case .permissionRequested(let p) = e.payload else { continue }
                let matches: Bool
                if let id = p.approvalID {
                    matches = id == approval.id
                } else if !approval.requestID.isEmpty {
                    matches = p.requestID == approval.requestID && (p.attempt == nil || p.attempt == approval.attempt)
                } else {
                    matches = p.title == approval.title
                }
                guard matches else { continue }
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
        let payload = addPlatformKeys(kind, to: payload, runID: runID, instanceID: instanceID, at: date)
        let event = InstanceEvent(
            instanceID: instanceID, seq: state.lastSeq(of: instanceID) + 1, runID: runID, kind: kind,
            payloadJSON: payload.compactString(), createdAt: date)
        state.events[instanceID, default: []].append(event)
        applySideEffects(of: event)
        broadcast(.event(event), to: instanceID)
        return event
    }

    /// 平台写运行日志时给审批事件加的键（11.8，docs/agent-integration.md 第 6 节）；脚本里已经写了的不动：
    ///
    /// - `permission_requested`：先建审批记录（和收件箱里的提醒），再带上 `attempt`（运行当前的尝试）和 `approval_id`；
    /// - `permission_resolved`：带上 `attempt`；对得上审批记录的带 `approval_id`，记录已经有结果（用户决定、超时）的
    ///   再带 `approval_state`（平台把结果交给 shim 的情况）。
    private mutating func addPlatformKeys(
        _ kind: InstanceEventKind, to payload: JSONValue, runID: RunID?, instanceID: InstanceID, at date: Date
    ) -> JSONValue {
        guard kind == .permissionRequested || kind == .permissionResolved, let runID,
            var object = payload.objectValue, let requestID = object["request_id"]?.stringValue
        else { return payload }
        let attempt = object["attempt"]?.intValue ?? state.runs.first(where: { $0.id == runID })?.attempt ?? 1
        object["attempt"] = .number(Double(attempt))
        let existing = state.approvals.lastIndex {
            $0.runID == runID && $0.attempt == attempt && $0.requestID == requestID
        }
        if kind == .permissionRequested {
            let index: Int
            if let existing {
                index = existing
            } else {
                guard let p = EventPayload.decode(PermissionRequestedPayload.self, from: payload.compactString()) else {
                    return .object(object)
                }
                index = createApproval(p, attempt: attempt, runID: runID, instanceID: instanceID, at: date)
            }
            if object["approval_id"] == nil { object["approval_id"] = .string(state.approvals[index].id.rawValue) }
        } else if let existing {
            let approval = state.approvals[existing]
            if object["approval_id"] == nil { object["approval_id"] = .string(approval.id.rawValue) }
            switch approval.state {
            case .approved, .rejected, .expired:
                if object["approval_state"] == nil { object["approval_state"] = .string(approval.state.rawValue) }
            default:
                break
            }
        }
        return .object(object)
    }

    /// 作废这个运行里还没处理、符合条件的审批，收件箱里对应的提醒标已读。
    private mutating func cancelPendingApprovals(runID: RunID, at date: Date, where matches: (Approval) -> Bool) {
        var cancelled: Set<ApprovalID> = []
        for j in state.approvals.indices
        where state.approvals[j].runID == runID && state.approvals[j].isPending && matches(state.approvals[j]) {
            state.approvals[j].state = .cancelled
            state.approvals[j].decidedAt = date
            permissions[state.approvals[j].id] = nil
            cancelled.insert(state.approvals[j].id)
        }
        for j in state.inbox.indices where state.inbox[j].approvalID.map(cancelled.contains) ?? false {
            state.inbox[j].isRead = true
        }
    }

    /// 建一条待处理的审批（平台收到 `permission_requested` 时做的）和收件箱里的提醒。返回审批的下标。
    private mutating func createApproval(
        _ p: PermissionRequestedPayload, attempt: Int, runID: RunID, instanceID: InstanceID, at date: Date
    ) -> Int {
        let instanceName = state.instances.first { $0.id == instanceID }?.name ?? ""
        let approval = Approval(
            id: .random(), runID: runID, instanceID: instanceID, title: p.title, options: p.options,
            toolCallJSON: p.toolCall?.compactString() ?? "{}", state: .pending,
            expiresAt: date.addingTimeInterval(24 * 3600), createdAt: date, requestID: p.requestID, attempt: attempt)
        state.approvals.append(approval)
        permissions[approval.id] = PendingPermission(
            requestID: p.requestID, toolCallID: p.toolCall?["toolCallId"]?.stringValue)
        state.inbox.insert(
            InboxItem(
                id: .random(), instanceID: instanceID, runID: runID, approvalID: approval.id, kind: .approval,
                title: "\(instanceName) 等你审批", body: p.title ?? "", isAIGenerated: p.title != nil, createdAt: date),
            at: 0)
        return state.approvals.count - 1
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
            // 每次状态变化都覆盖等待原因码，只在等 key、等电脑时留着（和服务端一样，旧的不会残留）。
            state.runs[i].waitCode = RunWaitCode.applies(to: p.state) ? p.waitCode : nil
            if let attempt = p.attempt { state.runs[i].attempt = attempt }
            if p.state == .running && state.runs[i].startedAt == nil { state.runs[i].startedAt = event.createdAt }
            // 一次尝试结束时它没处理的审批会被取消：新的尝试开始了，旧尝试的待处理审批作废。
            let attempt = state.runs[i].attempt
            cancelPendingApprovals(runID: runID, at: event.createdAt) { $0.attempt > 0 && $0.attempt < attempt }
            guard p.state.isTerminal else { return }
            state.runs[i].finishedAt = event.createdAt
            // 运行结束时还没决定的审批一并作废，收件箱里的审批提醒标已读（和服务端的 cancel_run_approvals 一致；
            // 之后再决定返回 conflict）。
            cancelPendingApprovals(runID: runID, at: event.createdAt) { _ in true }
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

    func inboxIndex(_ id: InboxItemID) throws -> Int {
        guard let i = state.inbox.firstIndex(where: { $0.id == id }) else { throw MockErrors.notFound("inbox item") }
        return i
    }

    func teamIndex(_ id: TeamID) throws -> Int {
        guard let i = state.teams.firstIndex(where: { $0.id == id }) else { throw MockErrors.notFound("team") }
        return i
    }

    func templateIndex(_ id: TeamTemplateID) throws -> Int {
        guard let i = state.teamTemplates.firstIndex(where: { $0.id == id }) else {
            throw MockErrors.notFound("template")
        }
        return i
    }

    func credentialIndex(_ id: CredentialID) throws -> Int {
        guard let i = state.credentials.firstIndex(where: { $0.id == id }) else {
            throw MockErrors.notFound("credential")
        }
        return i
    }

    /// 当前这台设备（调用方已经确认登录了）。
    func currentDeviceID() throws -> DeviceID {
        guard let id = state.session?.deviceID else { throw ClientError.signedOut }
        return id
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

    /// 实例的运行，新的在前（同一时刻的按 id 排，翻页稳定）。
    func sortedRuns(of instanceID: InstanceID) -> [Run] {
        state.runs.filter { $0.instanceID == instanceID }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    func runs(of instanceID: InstanceID, limit: Int) -> [Run] {
        Array(sortedRuns(of: instanceID).prefix(max(0, limit)))
    }

    // MARK: 设备与账号

    /// 登录设备，最近活跃的在前；`isCurrent` 按会话算，手机的 `isOnline` 总是 false。
    func devicesForDisplay() -> [DeviceInfo] {
        let current = state.session?.deviceID
        return state.devices.map { device in
            var d = device
            d.isCurrent = d.id == current
            if !d.isComputer { d.isOnline = false }
            return d
        }.sorted { ($0.lastSeenAt, $0.id) > ($1.lastSeenAt, $1.id) }
    }

    /// 登录、报推送令牌时：这台设备记在登录设备里（吊销过、注销过的重新登记），最近活跃时间是现在。
    mutating func registerCurrentDevice(push channel: PushChannel?) {
        guard let id = state.session?.deviceID else { return }
        let now = Date()
        if let i = state.devices.firstIndex(where: { $0.id == id }) {
            state.devices[i].lastSeenAt = now
            if let channel { state.devices[i].pushChannel = channel }
        } else {
            var device = DemoData.currentDevice(now: now)
            device.id = id
            device.pushChannel = channel
            state.devices.append(device)
        }
    }

    /// 吊销一台设备：从登录设备里去掉，发给它的、它发的还没收下的消息一起丢掉。
    mutating func removeDevice(_ id: DeviceID) {
        state.devices.removeAll { $0.id == id }
        state.deviceMessages.removeAll { $0.toDeviceID == id || $0.fromDeviceID == id }
    }

    /// 这台设备下线（退出登录、吊销了这台、注销账号）：会话、这台登记的实时活动和推送开启令牌一起清掉
    /// （服务端吊销设备时清掉这些），订阅着的事件流收到 `signedOut` 后结束。
    mutating func signOutLocally() {
        if let id = state.session?.deviceID { removeDevice(id) }
        state.session = nil
        state.liveActivities = [:]
        state.liveActivityStartToken = nil
        selfCodes = []
        for sub in subscribers.values {
            sub.continuation.yield(.status(.signedOut))
            sub.continuation.finish()
        }
        subscribers = [:]
    }

    /// 注销账号：服务端删掉这个人的全部内容，本地登录状态和缓存一起清掉。agent 目录、厂商、验证码留着，客户端自己的
    /// 设置（请求语言、版本太老的标记）也留着；用户换成一个没有手机号的新用户，之后用同一个手机号登录算新用户。
    mutating func eraseAccount() {
        cancelledRuns.formUnion(state.runs.map(\.id))
        signOutLocally()
        state = MockState(
            user: User(id: .random(), phone: "", createdAt: Date()), verificationCode: state.verificationCode,
            agents: state.agents, vendors: state.vendors, acceptLanguage: state.acceptLanguage,
            isUpgradeRequired: state.isUpgradeRequired, instancesPerUser: state.instancesPerUser)
        permissions = [:]
        scripts = [:]
        reportAttempts = []
    }

    /// 只有 iPhone、iPad 能登记实时活动（10.6）。
    func requireLiveActivityDevice() throws {
        let id = try currentDeviceID()
        guard state.devices.first(where: { $0.id == id })?.supportsLiveActivities == true else {
            throw MockErrors.invalid("live activities are only available on iPhone and iPad")
        }
    }

    // MARK: 领养

    /// 领养前的校验：agent 在目录里、名字不空、接入方式是这个 agent 的。返回 agent、去掉首尾空白的名字、接入方式。
    func checkAdoption(agentID: AgentID, name: String, harness: String?) throws -> (AgentInfo, String, String) {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { throw MockErrors.notFound("agent") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MockErrors.invalid("name is empty") }
        let harness = harness ?? agent.defaultHarness
        guard agent.harnesses.isEmpty || agent.harnesses.contains(harness) else {
            throw MockErrors.invalid("unknown harness \(harness)")
        }
        return (agent, name, harness)
    }

    /// 这家的订阅类 key（服务端 `check_key` 的说法，`CredentialRejection` 认得出）。
    static func checkSubscriptionKey(_ key: String, vendor: VendorInfo?) throws {
        guard let vendor, let prefix = vendor.subscriptionKeyPrefix(of: key) else { return }
        throw MockErrors.invalid(
            "\(vendor.name) subscription keys (\(prefix)...) can only be used in the vendor's own tools; use a "
                + "pay-as-you-go API key")
    }

    /// 实例数上限（11.9，`MockState.instancesPerUser`，0 不限）：没删除的实例（归档的也算）再加 `count` 个超过上限时
    /// 抛 409 `instance_limit`。
    func checkInstanceCapacity(adding count: Int) throws {
        let max = state.instancesPerUser
        guard max > 0 else { return }
        let existing = state.instances.filter { $0.state != .deleted }.count
        if existing + count > max { throw MockErrors.instanceLimit(max: max) }
    }

    /// 领养一个新实例（还没有模型路由）。
    mutating func adoptInstance(agentID: AgentID, name: String, harness: String?) throws -> Instance {
        let (agent, name, harness) = try checkAdoption(agentID: agentID, name: name, harness: harness)
        let now = Date()
        let instance = Instance(
            id: .random(), agentID: agent.id, agentVersion: agent.version, harness: harness, name: name,
            state: .running, createdAt: now, lastActiveAt: now)
        state.instances.append(instance)
        return instance
    }

    // MARK: 计划

    /// 计划字段的校验（和服务端的 `check_policy`、`check_steps` 一致）。`policy`、`catchUp`、`steps` 为 nil 的不查。
    func checkPlan(title: String, goal: String, policy: PlanPolicy?, catchUp: CatchUp?, steps: [PlanStep]?) throws {
        guard (1...Plan.maxTitleLength).contains(title.unicodeScalars.count) else {
            throw MockErrors.invalid("title must be 1-\(Plan.maxTitleLength) characters")
        }
        guard (1...Plan.maxGoalLength).contains(goal.unicodeScalars.count) else {
            throw MockErrors.invalid("goal must be 1-\(Plan.maxGoalLength) characters")
        }
        // 不认识的取值 client-core 转换时就拒（不发请求）。
        if let action = policy?.onApprovalTimeout, !action.isKnown {
            throw ClientError.invalidArgument(message: "unknown approval timeout action \(action)")
        }
        if let catchUp, !catchUp.isKnown { throw ClientError.invalidArgument(message: "unknown catch up \(catchUp)") }
        if let policy, !policy.isValid { throw MockErrors.invalid("policy is out of range") }
        if let steps { try checkSteps(steps) }
    }

    /// 流水线步骤：最多 20 步，步骤名合法且不重复，提示词不空，依赖只引用已有的步骤、不成环，实例要在。
    func checkSteps(_ steps: [PlanStep]) throws {
        guard steps.count <= Plan.maxSteps else { throw MockErrors.invalid("at most \(Plan.maxSteps) steps") }
        var keys = Set<String>()
        for step in steps {
            guard PlanStep.isValidKey(step.key) else { throw MockErrors.invalid("bad step key \(step.key)") }
            guard keys.insert(step.key).inserted else { throw MockErrors.invalid("duplicate step key \(step.key)") }
            let prompt = step.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...8000).contains(prompt.unicodeScalars.count) else {
                throw MockErrors.invalid("step prompt must be 1-8000 characters")
            }
        }
        for step in steps {
            if let missing = step.dependsOn.first(where: { !keys.contains($0) }) {
                throw MockErrors.invalid("step \(step.key) depends on unknown step \(missing)")
            }
        }
        var done = Set<String>()
        var remaining = steps
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.dependsOn.allSatisfy(done.contains) }
            guard !ready.isEmpty else { throw MockErrors.invalid("steps depend on each other in a cycle") }
            done.formUnion(ready.map(\.key))
            remaining.removeAll { done.contains($0.key) }
        }
        for step in steps { _ = try instanceIndex(step.instanceID) }
    }

    /// 流水线有一步在已删除的实例上（删除实例时暂停了它，11.9）：恢复、确认前要先改步骤，抛 409。Mock 里删掉的实例
    /// 直接从列表里拿掉，所以“不在实例列表里”就是删掉了。
    func refuseDeletedSteps(_ plan: Plan) throws {
        let live = Set(state.instances.filter { $0.state != .deleted }.map(\.id))
        if let step = plan.steps.first(where: { !live.contains($0.instanceID) }) {
            throw MockErrors.conflict("step \(step.key) runs on a deleted instance; change the steps first")
        }
    }

    /// 接口返回的计划：下一次运行的时间、失效的触发器数按服务端的规则重新算（状态里的触发器、暂停状态可能被直接改过）。
    static func planView(_ plan: Plan) -> Plan {
        var p = plan
        p.refreshSchedule()
        return p
    }

    /// 新的触发器：一次性的要在将来，cron 要五段、时区认得，rrule 不能为空。下一次触发时间只有一次性的算得出来。
    static func makeTrigger(_ schedule: Schedule, now: Date = Date()) throws -> Trigger {
        switch schedule {
        case .once: break
        case .cron(let expression, let timeZone):
            guard expression.split(separator: " ").count == 5, TimeZone(identifier: timeZone) != nil else {
                throw MockErrors.invalid("bad cron schedule")
            }
        case .rrule(let rule):
            guard !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MockErrors.invalid("empty rrule")
            }
        }
        // 下次触发时间和服务端一样按规则算（本地算不了的写法留空，服务端会算）；再也不会触发的规则不收。
        let next = ScheduleForecast.nextFires(schedule, after: now, count: 1)
        if next?.isEmpty == true { throw MockErrors.invalid("the schedule never fires after now") }
        return Trigger(id: .random(), schedule: schedule, nextFireAt: next?.first)
    }

    // MARK: 保险箱

    /// 用途、账号：最多 `max` 个字符，不能有控制字符（服务端的 `check_text`）。
    static func checkVaultText(_ text: String, max: Int) throws {
        guard text.unicodeScalars.count <= max else { throw MockErrors.invalid("at most \(max) characters") }
        guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw MockErrors.invalid("control characters")
        }
    }

    /// 密码：至少 4 个字符、最多 4096 字节、不能有控制字符（服务端的 `check_password`）。
    static func checkVaultPassword(_ password: String) throws {
        guard VaultRules.passwordProblem(password) == nil else {
            throw MockErrors.invalid("password must be \(VaultRules.minPassword) characters to 4096 bytes")
        }
    }

    // MARK: 团队

    /// 团队名、模板名：去掉首尾空白后 1 到 64 个字符。
    static func checkName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Team.maxNameLength).contains(name.unicodeScalars.count) else {
            throw MockErrors.invalid("name must be 1-\(Team.maxNameLength) characters")
        }
        return name
    }

    /// 团队成员：1 到 12 个、最多一个负责人、实例要在、不能重复。返回按 `position` 排好的成员。
    func checkTeamMembers(_ members: [TeamMember]) throws -> [TeamMember] {
        if let bad = members.first(where: { !$0.role.isKnown }) {
            throw ClientError.invalidArgument(message: "unknown team role \(bad.role)")
        }
        guard (1...Team.maxMembers).contains(members.count) else {
            throw MockErrors.invalid("a team has 1-\(Team.maxMembers) members")
        }
        guard members.filter(\.isLead).count <= 1 else { throw MockErrors.invalid("a team has at most one lead") }
        for m in members { _ = try instanceIndex(m.instanceID) }
        guard Set(members.map(\.instanceID)).count == members.count else {
            throw MockErrors.conflict("an instance is in the team twice")
        }
        return members.sorted { ($0.position, $0.instanceID) < ($1.position, $1.instanceID) }
    }

    /// 模板成员：1 到 12 个、名字 1 到 64 个字符、agent 要在目录里、最多一个负责人。
    func checkTemplateMembers(_ members: [TemplateMember]) throws -> [TemplateMember] {
        if let bad = members.first(where: { !$0.role.isKnown }) {
            throw ClientError.invalidArgument(message: "unknown team role \(bad.role)")
        }
        guard (1...Team.maxMembers).contains(members.count) else {
            throw MockErrors.invalid("a template has 1-\(Team.maxMembers) members")
        }
        for m in members {
            guard (1...Team.maxNameLength).contains(m.name.unicodeScalars.count) else {
                throw MockErrors.invalid("member name must be 1-\(Team.maxNameLength) characters")
            }
            guard state.agents.contains(where: { $0.id == m.agentID }) else {
                throw MockErrors.invalid("unknown agent \(m.agentID)")
            }
        }
        guard members.filter(\.isLead).count <= 1 else { throw MockErrors.invalid("a team has at most one lead") }
        return members
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

    /// 和服务端（gateway `routes/vault.rs`）一样的顺序：名字、用途、账号、密码、实例数，再看条数上限，最后才是重名。
    mutating func createVaultItem(_ item: NewVaultItem) throws -> VaultItem {
        guard VaultNameProblem.check(item.name) == nil, item.name == item.name.trimmingCharacters(in: .whitespaces)
        else {
            throw MockErrors.invalid("bad name \(item.name)")
        }
        try Inner.checkVaultText(item.purpose, max: VaultRules.maxPurpose)
        try Inner.checkVaultText(item.username, max: VaultRules.maxUsername)
        try Inner.checkVaultPassword(item.password)
        guard item.instanceIDs.count <= VaultRules.maxInstances else {
            throw MockErrors.invalid("at most \(VaultRules.maxInstances) instance_ids")
        }
        guard state.vaultItems.count < VaultRules.maxItems else {
            throw MockErrors.invalid("the vault holds at most \(VaultRules.maxItems) items")
        }
        guard !state.vaultItems.contains(where: { $0.name == item.name }) else {
            throw MockErrors.conflict("name \(item.name) is taken")
        }
        let created = VaultItem(
            id: .random(), name: item.name, purpose: item.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
            hasUsername: !item.username.isEmpty, instanceIDs: Array(Set(item.instanceIDs)).sorted(), createdAt: Date())
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

    /// 实例数到了账号的上限（11.9）。
    static func instanceLimit(max: Int) -> ClientError {
        .api(status: 409, code: .instanceLimit, message: "at most \(max) instances per account", retryAfterSecs: nil)
    }

    static func rateLimited(_ message: String, retryAfter: Int?) -> ClientError {
        .api(status: 429, code: .rateLimited, message: message, retryAfterSecs: retryAfter)
    }

    /// 实时活动的令牌格式不对。
    static let badLiveActivityToken = invalid("token must be the hex push token ActivityKit gave the app")

    /// 从 webhook 地址认出 IM 平台。
    /// webhook 地址和签名密钥，按服务端的规则（`ImChannelRules`）查。
    static func imWebhook(_ url: String, secret: String?) throws -> (ImVendor, String) {
        guard url.count <= 512 else { throw invalid("webhook_url must be 1-512 characters") }
        switch ImChannelRules.parseWebhook(url) {
        case .failure(.badToken):
            throw invalid("webhook_url: the token after the address is missing or malformed")
        case .failure:
            throw invalid(
                "webhook_url must be a Feishu, Lark, WeCom or DingTalk group bot webhook address, copied as is")
        case .success(let parsed):
            switch ImChannelRules.checkSecret(secret ?? "", vendor: parsed.vendor) {
            case .secretNotSupported?: throw invalid("secret: WeCom bots have no signing secret")
            case .some: throw invalid("secret must be 8-128 visible characters (DingTalk secrets start with SEC)")
            case nil: return (parsed.vendor, parsed.token)
            }
        }
    }
}
