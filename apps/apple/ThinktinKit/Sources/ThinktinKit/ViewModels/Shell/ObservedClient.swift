import Foundation

/// `ObservedClient` 报给应用框架的事（`AppModel` 收）。回调在调用方的线程上，收的一方自己切回主线程。
public enum ClientActivity: Sendable {
    /// 一次调用抛了 `ClientError`。登录失效、冻结、要升级由 `AppModel` 切换全局状态；网络不通标“离线”。
    case failed(ClientError)
    /// 之前网络不通，这次调用成功了（只在离线 → 在线时报一次）。
    case reachable
    /// 登录成功（`login`）。
    case signedIn(LoginResult)
    /// 本地的登录状态没了：退出登录、注销账号、下线了这台设备。
    case signedOut
    /// 一个事件流的连接状态变了。
    case stream(StreamStatus, instanceID: InstanceID, subscription: UUID)
    /// 一个事件流停了（调用方 `stop()`、收到终止状态、强制升级时被停掉）。
    case streamEnded(subscription: UUID)
}

/// 包一层的客户端（WBS 12.16）：每个调用原样转给 `base`，同时把结果报给应用框架（`report`）。
///
/// `AppModel` 把它交给所有页面（`AppModel.client`、界面环境里的 `\.client`），所以任何功能的任何调用遇到
/// 登录失效、账号冻结、要升级都会切换全局状态，各功能不用自己处理；`login` 成功、`logout` / `deleteAccount` /
/// 下线本机之后也会自动切到对应的页面。事件流的连接状态汇总成顶部的连接横幅；强制升级时 `haltStreams()` 停掉
/// 所有事件流（每个订阅的一方收到一次 `.upgradeRequired`），之后的订阅直接抛 `upgradeRequired`，
/// `upgradeRequired()` 也一直是 true。
///
/// **`ClientProtocol` 加了方法，这里要加对应的转发**（编译器会提示：不实现就不符合协议）。
public final class ObservedClient: ClientProtocol, Sendable {
    /// 被包的客户端（Mock 或真核心）。
    public let base: any ClientProtocol
    private let report: @Sendable (ClientActivity) -> Void
    private let state = Locked(StreamRegistry())

    /// 正在进行的事件流（`haltStreams()` 要停掉它们）。
    private struct StreamRegistry {
        var isOffline = false
        var isHalted = false
        /// 订阅前先登记（回调在后台线程，终止状态可能比 `subscribe` 返回还早），返回后再填上句柄。
        var subscriptions: [UUID: StreamEntry] = [:]
    }

    private struct StreamEntry {
        let relay: RelayListener
        var handle: EventSubscriptionHandle?
    }

    /// - Parameters:
    ///   - base: 真正干活的客户端。
    ///   - report: 收报告的回调（在调用方的线程上，有时在锁里调）：只能把报告放进队列，不能再调这个客户端。
    public init(_ base: any ClientProtocol, report: @escaping @Sendable (ClientActivity) -> Void) {
        self.base = base
        self.report = report
    }

    /// 停掉所有事件流（强制升级，ios-packages.md 12.16），之后的订阅直接抛 `upgradeRequired`。
    /// 每个订阅的一方会收到一次 `.upgradeRequired`（和 client-core 遇到 426 时一样；`.stopped` 只表示调用方停的）。
    public func haltStreams() {
        let stopped = state.withLock { s in
            s.isHalted = true
            defer { s.subscriptions = [:] }
            return s.subscriptions
        }
        for (token, entry) in stopped {
            entry.handle?.stop()
            entry.relay.listener.onStatus(.upgradeRequired)
            report(.streamEnded(subscription: token))
        }
    }

    /// 已经 `haltStreams()` 过。
    public var isHalted: Bool { state.withLock { $0.isHalted } }

    /// 正在进行的事件流有几个。
    public var activeStreamCount: Int { state.withLock { $0.subscriptions.count } }

    // MARK: 报告

    private func observe<R>(_ body: () async throws -> R) async throws -> R {
        do {
            let result = try await body()
            succeeded()
            return result
        } catch {
            failed(error)
            throw error
        }
    }

    private func observeSync<R>(_ body: () throws -> R) throws -> R {
        do {
            return try body()
        } catch {
            failed(error)
            throw error
        }
    }

    // 离线标记的变化和报告放在同一把锁里：多个线程同时成功、失败时，报告的顺序和标记的变化一致，
    // 收的一方最后看到的就是最后一次调用的结果。
    private func succeeded() {
        state.withLock { s in
            guard s.isOffline else { return }
            s.isOffline = false
            report(.reachable)
        }
    }

    private func failed(_ error: any Error) {
        guard let error = error as? ClientError else { return }
        state.withLock { s in
            if error.isOffline { s.isOffline = true }
            report(.failed(error))
        }
    }

    /// 改登录状态的调用（退出、注销、下线设备）之后：本地没有会话了就报 `signedOut`。
    private func reportIfSignedOut() {
        if !base.signedIn() { report(.signedOut) }
    }

    // MARK: 事件流

    private func streamStatusChanged(_ status: StreamStatus, instanceID: InstanceID, token: UUID) {
        report(.stream(status, instanceID: instanceID, subscription: token))
        if status.isFinal { endSubscription(token) }
    }

    private func endSubscription(_ token: UUID) {
        let removed = state.withLock { $0.subscriptions.removeValue(forKey: token) != nil }
        if removed { report(.streamEnded(subscription: token)) }
    }

    public var secretDetector: any SecretDetector { base.secretDetector }

    public func subscribe(instanceID: InstanceID, afterSeq: UInt64?, listener: any EventListening) throws
        -> EventSubscriptionHandle
    {
        if isHalted {
            report(.failed(.upgradeRequired))
            throw ClientError.upgradeRequired
        }
        let token = UUID()
        let relay = RelayListener(listener) { [weak self] status in
            self?.streamStatusChanged(status, instanceID: instanceID, token: token)
        }
        state.withLock { $0.subscriptions[token] = StreamEntry(relay: relay) }
        let handle: EventSubscriptionHandle
        do {
            handle = try observeSync {
                try base.subscribe(instanceID: instanceID, afterSeq: afterSeq, listener: relay)
            }
        } catch {
            state.withLock { _ = $0.subscriptions.removeValue(forKey: token) }
            throw error
        }
        let halted = state.withLock { s -> Bool in
            // 已经结束了的（终止状态比返回还早）不在表里，不用再填。
            s.subscriptions[token]?.handle = handle
            return s.isHalted
        }
        // 订阅的同时被强制升级停掉了。
        if halted { handle.stop() }
        return EventSubscriptionHandle { [weak self] in
            handle.stop()
            self?.endSubscription(token)
        }
    }

    public func cachedEvents(instanceID: InstanceID, afterSeq: UInt64, limit: Int) throws -> [InstanceEvent] {
        try observeSync { try base.cachedEvents(instanceID: instanceID, afterSeq: afterSeq, limit: limit) }
    }

    public func cachedEventsBefore(instanceID: InstanceID, beforeSeq: UInt64?, limit: Int) throws -> [InstanceEvent] {
        try observeSync { try base.cachedEventsBefore(instanceID: instanceID, beforeSeq: beforeSeq, limit: limit) }
    }

    // MARK: 账号

    public func signedIn() -> Bool { base.signedIn() }

    public func sendCode(phone: String) async throws {
        try await observe { try await base.sendCode(phone: phone) }
    }

    public func login(phone: String, code: String, push: PushRegistration?) async throws -> LoginResult {
        let result = try await observe { try await base.login(phone: phone, code: code, push: push) }
        report(.signedIn(result))
        return result
    }

    public func logout() async throws {
        defer { reportIfSignedOut() }
        try await observe { try await base.logout() }
    }

    public func me() async throws -> User {
        try await observe { try await base.me() }
    }

    public func setLocale(_ locale: UserLocale) async throws -> User {
        try await observe { try await base.setLocale(locale) }
    }

    public func setPushToken(_ push: PushRegistration) async throws {
        try await observe { try await base.setPushToken(push) }
    }

    public func stopAll() async throws -> StopAllResult {
        try await observe { try await base.stopAll() }
    }

    public func signOutOtherDevices(stopAgents: Bool) async throws -> SignOutOthersResult {
        try await observe { try await base.signOutOtherDevices(stopAgents: stopAgents) }
    }

    public func updateProfile(displayName: String?) async throws -> User {
        try await observe { try await base.updateProfile(displayName: displayName) }
    }

    public func sendSelfCode(purpose: SelfCodePurpose) async throws {
        try await observe { try await base.sendSelfCode(purpose: purpose) }
    }

    public func deleteAccount(code: String) async throws {
        try await observe { try await base.deleteAccount(code: code) }
        reportIfSignedOut()
    }

    // MARK: 请求语言与版本（11.8）

    public func setAcceptLanguage(_ acceptLanguage: String?) throws {
        try observeSync { try base.setAcceptLanguage(acceptLanguage) }
    }

    /// `base` 说过要升级，或者已经 `haltStreams()` 过（应用框架只在要升级时停事件流，两边说法一致）。
    public func upgradeRequired() -> Bool {
        isHalted || base.upgradeRequired()
    }

    // MARK: 登录设备与设备消息

    public func devices() async throws -> [DeviceInfo] {
        try await observe { try await base.devices() }
    }

    public func revokeDevice(_ deviceID: DeviceID) async throws {
        try await observe { try await base.revokeDevice(deviceID) }
        // 下线的是这台：本地登录状态清掉了。
        reportIfSignedOut()
    }

    public func sendDeviceMessage(to deviceID: DeviceID, kind: DeviceMessageKind, bodyJSON: String) async throws
        -> DeviceMessage
    {
        try await observe { try await base.sendDeviceMessage(to: deviceID, kind: kind, bodyJSON: bodyJSON) }
    }

    public func deviceMessages() async throws -> [DeviceMessage] {
        try await observe { try await base.deviceMessages() }
    }

    public func ackDeviceMessages(ids: [DeviceMessageID]) async throws -> Int {
        try await observe { try await base.ackDeviceMessages(ids: ids) }
    }

    // MARK: 实时活动

    public func setLiveActivityStartToken(_ token: String?) async throws {
        try await observe { try await base.setLiveActivityStartToken(token) }
    }

    public func registerLiveActivity(runID: RunID, token: String) async throws {
        try await observe { try await base.registerLiveActivity(runID: runID, token: token) }
    }

    public func endLiveActivity(runID: RunID) async throws {
        try await observe { try await base.endLiveActivity(runID: runID) }
    }

    // MARK: agent 与实例

    public func agents() async throws -> [AgentInfo] {
        try await observe { try await base.agents() }
    }

    public func instances() async throws -> [Instance] {
        try await observe { try await base.instances() }
    }

    public func instance(_ instanceID: InstanceID) async throws -> Instance {
        try await observe { try await base.instance(instanceID) }
    }

    public func cachedInstances() throws -> [Instance] {
        try observeSync { try base.cachedInstances() }
    }

    public func adopt(agentID: AgentID, name: String, harness: String?) async throws -> Instance {
        try await observe { try await base.adopt(agentID: agentID, name: name, harness: harness) }
    }

    public func renameInstance(_ instanceID: InstanceID, name: String) async throws -> Instance {
        try await observe { try await base.renameInstance(instanceID, name: name) }
    }

    public func setInstanceVersion(_ instanceID: InstanceID, version: String?) async throws -> Instance {
        try await observe { try await base.setInstanceVersion(instanceID, version: version) }
    }

    public func modelRoutes(instanceID: InstanceID) async throws -> [ModelRoute] {
        try await observe { try await base.modelRoutes(instanceID: instanceID) }
    }

    public func setModelRoutes(instanceID: InstanceID, routes: [ModelRoute]) async throws {
        try await observe { try await base.setModelRoutes(instanceID: instanceID, routes: routes) }
    }

    public func deleteInstance(_ instanceID: InstanceID) async throws {
        try await observe { try await base.deleteInstance(instanceID) }
    }

    // MARK: 运行

    public func createRun(instanceID: InstanceID, prompt: String) async throws -> Run {
        try await observe { try await base.createRun(instanceID: instanceID, prompt: prompt) }
    }

    public func runs(instanceID: InstanceID, limit: Int) async throws -> [Run] {
        try await observe { try await base.runs(instanceID: instanceID, limit: limit) }
    }

    public func olderRuns(instanceID: InstanceID, before: RunID, limit: Int) async throws -> [Run] {
        try await observe { try await base.olderRuns(instanceID: instanceID, before: before, limit: limit) }
    }

    public func listRuns(filter: RunFilter, before: RunID?, limit: Int) async throws -> [Run] {
        try await observe { try await base.listRuns(filter: filter, before: before, limit: limit) }
    }

    public func cachedRuns(instanceID: InstanceID, limit: Int) throws -> [Run] {
        try observeSync { try base.cachedRuns(instanceID: instanceID, limit: limit) }
    }

    public func getRun(_ runID: RunID) async throws -> Run {
        try await observe { try await base.getRun(runID) }
    }

    public func cancelRun(_ runID: RunID, wholeTree: Bool) async throws -> Run {
        try await observe { try await base.cancelRun(runID, wholeTree: wholeTree) }
    }

    public func runTree(_ runID: RunID) async throws -> [Run] {
        try await observe { try await base.runTree(runID) }
    }

    public func runArtifacts(_ runID: RunID) async throws -> [Artifact] {
        try await observe { try await base.runArtifacts(runID) }
    }

    public func instanceArtifacts(_ instanceID: InstanceID, limit: Int) async throws -> [Artifact] {
        try await observe { try await base.instanceArtifacts(instanceID, limit: limit) }
    }

    public func artifactContent(_ artifactID: ArtifactID) async throws -> Data {
        try await observe { try await base.artifactContent(artifactID) }
    }

    public func deleteArtifact(_ artifactID: ArtifactID) async throws {
        try await observe { try await base.deleteArtifact(artifactID) }
    }

    // MARK: 审批

    public func approvals() async throws -> [Approval] {
        try await observe { try await base.approvals() }
    }

    public func getApproval(_ approvalID: ApprovalID) async throws -> Approval {
        try await observe { try await base.getApproval(approvalID) }
    }

    public func decideApproval(_ approvalID: ApprovalID, optionID: String) async throws -> Approval {
        try await observe { try await base.decideApproval(approvalID, optionID: optionID) }
    }

    // MARK: 计划

    public func plans(instanceID: InstanceID?) async throws -> [Plan] {
        try await observe { try await base.plans(instanceID: instanceID) }
    }

    public func getPlan(_ planID: PlanID) async throws -> Plan {
        try await observe { try await base.getPlan(planID) }
    }

    public func createPlan(_ plan: NewPlan) async throws -> Plan {
        try await observe { try await base.createPlan(plan) }
    }

    public func updatePlan(_ planID: PlanID, change: PlanChange) async throws -> Plan {
        try await observe { try await base.updatePlan(planID, change: change) }
    }

    public func addTrigger(planID: PlanID, schedule: Schedule) async throws -> Trigger {
        try await observe { try await base.addTrigger(planID: planID, schedule: schedule) }
    }

    public func deleteTrigger(_ triggerID: TriggerID) async throws {
        try await observe { try await base.deleteTrigger(triggerID) }
    }

    public func setPlanPaused(_ planID: PlanID, paused: Bool) async throws -> Plan {
        try await observe { try await base.setPlanPaused(planID, paused: paused) }
    }

    public func confirmPlan(_ planID: PlanID, revision: Int) async throws -> Plan {
        try await observe { try await base.confirmPlan(planID, revision: revision) }
    }

    public func deletePlan(_ planID: PlanID) async throws {
        try await observe { try await base.deletePlan(planID) }
    }

    // MARK: 收件箱

    public func syncInbox(limit: Int) async throws -> InboxPage {
        try await observe { try await base.syncInbox(limit: limit) }
    }

    public func olderInbox(before: InboxItemID, limit: Int) async throws -> [InboxItem] {
        try await observe { try await base.olderInbox(before: before, limit: limit) }
    }

    public func cachedInbox(before: InboxItemID?, limit: Int) throws -> [InboxItem] {
        try observeSync { try base.cachedInbox(before: before, limit: limit) }
    }

    public func cachedUnread() throws -> Int {
        try observeSync { try base.cachedUnread() }
    }

    public func markInboxRead(ids: [InboxItemID], upTo: InboxItemID?) async throws -> Int {
        try await observe { try await base.markInboxRead(ids: ids, upTo: upTo) }
    }

    public func inboxItem(_ itemID: InboxItemID) async throws -> InboxItem {
        try await observe { try await base.inboxItem(itemID) }
    }

    public func markInboxUnread(_ itemID: InboxItemID) async throws -> Int {
        try await observe { try await base.markInboxUnread(itemID) }
    }

    public func deleteInboxItem(_ itemID: InboxItemID) async throws {
        try await observe { try await base.deleteInboxItem(itemID) }
    }

    // MARK: 团队与团队模板

    public func teams() async throws -> [Team] {
        try await observe { try await base.teams() }
    }

    public func team(_ teamID: TeamID) async throws -> Team {
        try await observe { try await base.team(teamID) }
    }

    public func createTeam(name: String, members: [TeamMember]) async throws -> Team {
        try await observe { try await base.createTeam(name: name, members: members) }
    }

    public func updateTeam(_ teamID: TeamID, name: String?, members: [TeamMember]?) async throws -> Team {
        try await observe { try await base.updateTeam(teamID, name: name, members: members) }
    }

    public func deleteTeam(_ teamID: TeamID) async throws {
        try await observe { try await base.deleteTeam(teamID) }
    }

    public func teamTemplates() async throws -> [TeamTemplate] {
        try await observe { try await base.teamTemplates() }
    }

    public func createTeamTemplate(name: String, members: [TemplateMember]) async throws -> TeamTemplate {
        try await observe { try await base.createTeamTemplate(name: name, members: members) }
    }

    public func createTeamTemplateFromTeam(name: String, teamID: TeamID) async throws -> TeamTemplate {
        try await observe { try await base.createTeamTemplateFromTeam(name: name, teamID: teamID) }
    }

    public func deleteTeamTemplate(_ templateID: TeamTemplateID) async throws {
        try await observe { try await base.deleteTeamTemplate(templateID) }
    }

    public func adoptTeamTemplate(_ templateID: TeamTemplateID, name: String?) async throws -> Team {
        try await observe { try await base.adoptTeamTemplate(templateID, name: name) }
    }

    // MARK: 用量

    public func usage(group: UsageGroup, from: Date?, to: Date?, timeZone: TimeZone?) async throws -> UsageSummary {
        try await observe { try await base.usage(group: group, from: from, to: to, timeZone: timeZone) }
    }

    // MARK: 模型 key

    public func vendors() async throws -> [VendorInfo] {
        try await observe { try await base.vendors() }
    }

    public func credentials() async throws -> [Credential] {
        try await observe { try await base.credentials() }
    }

    public func addCredential(_ credential: NewCredential) async throws -> Credential {
        try await observe { try await base.addCredential(credential) }
    }

    public func updateCredential(_ credentialID: CredentialID, label: String?, disabled: Bool?) async throws
        -> Credential
    {
        try await observe { try await base.updateCredential(credentialID, label: label, disabled: disabled) }
    }

    public func replaceCredentialSecret(_ credentialID: CredentialID, apiKey: String) async throws -> Credential {
        try await observe { try await base.replaceCredentialSecret(credentialID, apiKey: apiKey) }
    }

    public func deleteCredential(_ credentialID: CredentialID) async throws {
        try await observe { try await base.deleteCredential(credentialID) }
    }

    // MARK: 内容举报

    public func reportContent(
        runID: RunID, eventSeq: UInt64?, artifactID: ArtifactID?, reason: ReportReason, note: String?
    ) async throws -> ContentReport {
        try await observe {
            try await base.reportContent(
                runID: runID, eventSeq: eventSeq, artifactID: artifactID, reason: reason, note: note)
        }
    }

    public func reports() async throws -> [ContentReport] {
        try await observe { try await base.reports() }
    }

    // MARK: IM 渠道

    public func imChannels() async throws -> [ImChannel] {
        try await observe { try await base.imChannels() }
    }

    public func addImChannel(_ channel: NewImChannel) async throws -> ImChannel {
        try await observe { try await base.addImChannel(channel) }
    }

    public func updateImChannel(_ channelID: ImChannelID, label: String?, events: [ImEvent]?, enabled: Bool?)
        async throws -> ImChannel
    {
        try await observe {
            try await base.updateImChannel(channelID, label: label, events: events, enabled: enabled)
        }
    }

    public func replaceImWebhook(_ channelID: ImChannelID, webhookURL: String, secret: String?) async throws
        -> ImChannel
    {
        try await observe { try await base.replaceImWebhook(channelID, webhookURL: webhookURL, secret: secret) }
    }

    public func testImChannel(_ channelID: ImChannelID) async throws {
        try await observe { try await base.testImChannel(channelID) }
    }

    public func deleteImChannel(_ channelID: ImChannelID) async throws {
        try await observe { try await base.deleteImChannel(channelID) }
    }

    // MARK: 消息与保险箱

    public func sendMessage(instanceID: InstanceID, text: String, allowSecrets: Bool) async throws -> Run {
        try await observe { try await base.sendMessage(instanceID: instanceID, text: text, allowSecrets: allowSecrets) }
    }

    public func saveSecretFromMessage(message: String, value: String, item: NewVaultItem) async throws
        -> SavedSecret
    {
        try await observe { try await base.saveSecretFromMessage(message: message, value: value, item: item) }
    }

    public func vaultItems() async throws -> [VaultItem] {
        try await observe { try await base.vaultItems() }
    }

    public func vaultItem(_ itemID: VaultItemID) async throws -> VaultItemDetail {
        try await observe { try await base.vaultItem(itemID) }
    }

    public func createVaultItem(_ item: NewVaultItem) async throws -> VaultItem {
        try await observe { try await base.createVaultItem(item) }
    }

    public func updateVaultItem(_ itemID: VaultItemID, change: VaultItemUpdate) async throws -> VaultItem {
        try await observe { try await base.updateVaultItem(itemID, change: change) }
    }

    public func deleteVaultItem(_ itemID: VaultItemID) async throws {
        try await observe { try await base.deleteVaultItem(itemID) }
    }

    public func vaultRequests(all: Bool) async throws -> [VaultRequest] {
        try await observe { try await base.vaultRequests(all: all) }
    }

    public func fulfillVaultRequest(_ requestID: VaultRequestID, username: String, password: String, purpose: String?)
        async throws -> VaultRequest
    {
        try await observe {
            try await base.fulfillVaultRequest(requestID, username: username, password: password, purpose: purpose)
        }
    }

    public func declineVaultRequest(_ requestID: VaultRequestID) async throws -> VaultRequest {
        try await observe { try await base.declineVaultRequest(requestID) }
    }
}

/// 转发事件流回调，顺带把连接状态报给 `ObservedClient`。
private final class RelayListener: EventListening, Sendable {
    let listener: any EventListening
    private let statusChanged: @Sendable (StreamStatus) -> Void

    init(_ listener: any EventListening, statusChanged: @escaping @Sendable (StreamStatus) -> Void) {
        self.listener = listener
        self.statusChanged = statusChanged
    }

    func onEvent(_ event: InstanceEvent) { listener.onEvent(event) }

    func onReset(oldestSeq: UInt64, latestSeq: UInt64?) {
        listener.onReset(oldestSeq: oldestSeq, latestSeq: latestSeq)
    }

    func onStatus(_ status: StreamStatus) {
        statusChanged(status)
        listener.onStatus(status)
    }
}
