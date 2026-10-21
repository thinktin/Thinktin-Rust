import Foundation
import ThinktinKit

/// `ClientProtocol` 的真实实现：包装 ThinktinCore（UniFFI）的 `ThinktinClient`，经它调 Rust 的 client-core
/// （网络、令牌刷新、事件流续传、SQLite 缓存、密码识别都在那边）。
///
/// 这里只做三件事：参数从领域模型换成 ThinktinCore 的形式（强类型 id → 字符串、`Date` → 毫秒、枚举 → 字符串），
/// 结果换回领域模型（Conversions.swift），错误一律换成 ThinktinKit 的 `ClientError`。
///
/// client-core 的网络操作跑在它自己的 tokio 运行时上，这里的 async 方法只是等结果，可以从任何线程、任何 actor 调；
/// 不带 async 的方法只读本地缓存。事件回调在 client-core 的后台线程上（见 `subscribe`）。
public final class CoreClient: ClientProtocol {
    public let secretDetector: any SecretDetector
    private let core: Core.Client

    /// - Parameters:
    ///   - baseURL: 接口地址，比如 `https://api.thinktin.cn`。
    ///   - cachePath: 缓存数据库文件（App 的私有目录）；为 nil 时不缓存（`cached*` 都返回空）。
    ///   - platform: 设备平台，登录时报给服务端（设备管理里显示）。
    ///   - deviceName: 设备名（“张三的 iPhone”），显示在设备管理里。
    ///   - timeout: 单个请求的超时（秒），client-core 里最少 5 秒。
    ///   - sessions: 会话存储（App 里是 Keychain）。已经登录过的会话从这里恢复。
    /// - Throws: `ClientError`：平台名不对（`invalidArgument`）、缓存库打不开（`cache`）。接口地址这里不校验，
    ///   地址不对时之后的请求抛 `network`。
    public init(
        baseURL: String, cachePath: String? = nil, platform: DevicePlatform = .current, deviceName: String,
        timeout: TimeInterval = 30, sessions: any SessionStoring
    ) throws {
        let config = Core.ClientConfig(
            baseUrl: baseURL, cachePath: cachePath, platform: platform.rawValue, deviceName: deviceName,
            timeoutSecs: Self.wholeSeconds(timeout))
        do {
            core = try Core.makeClient(config: config, sessions: SessionStoreBridge(sessions))
        } catch {
            throw ThinktinKit.ClientError(error)
        }
        secretDetector = CoreSecretDetector()
    }

    // MARK: 调用与错误转换

    /// 等 client-core 的结果，错误换成 ThinktinKit 的 `ClientError`。
    private func perform<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw ThinktinKit.ClientError(error)
        }
    }

    /// 同步版（只读缓存的方法）。
    private func performSync<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw ThinktinKit.ClientError(error)
        }
    }

    /// 个数参数：界面里是 `Int`，client-core 是 `u32`（负数当 0）。
    private static func count(_ n: Int) -> UInt32 { UInt32(clamping: n) }

    /// 超时秒数向上取整成 `u32`；负数当 0（client-core 会提到最少 5 秒），NaN、无穷大用默认的 30 秒。
    static func wholeSeconds(_ interval: TimeInterval) -> UInt32 {
        guard interval.isFinite else { return 30 }
        return UInt32(min(max(interval.rounded(.up), 0), Double(UInt32.max)))
    }

    /// client-core 还没导出的接口（WBS 11.7 落地前）：`ClientProtocol` 里有、`ThinktinClient` 里没有的方法
    /// 一律 `try unsupported()`，抛 `ClientError.unsupported`（界面提示“暂未开放”，见 docs/ios.md 第 6 节）。
    private func unsupported<T>(_ feature: String = #function) throws -> T {
        throw ThinktinKit.ClientError.unsupported(feature: feature)
    }

    // MARK: 账号

    public func signedIn() -> Bool {
        core.signedIn()
    }

    public func sendCode(phone: String) async throws {
        try await perform { try await core.sendCode(phone: phone) }
    }

    public func login(phone: String, code: String, push: PushRegistration?) async throws -> ThinktinKit.LoginResult {
        try await perform {
            ThinktinKit.LoginResult(
                core: try await core.login(
                    phone: phone, code: code, pushChannel: push?.channel.rawValue, pushToken: push?.token))
        }
    }

    public func logout() async throws {
        try await perform { try await core.logout() }
    }

    public func me() async throws -> ThinktinKit.User {
        try await perform { ThinktinKit.User(core: try await core.me()) }
    }

    public func setLocale(_ locale: UserLocale) async throws -> ThinktinKit.User {
        try await perform { ThinktinKit.User(core: try await core.setLocale(locale: locale.rawValue)) }
    }

    public func setPushToken(_ push: PushRegistration) async throws {
        try await perform { try await core.setPushToken(channel: push.channel.rawValue, token: push.token) }
    }

    public func stopAll() async throws -> ThinktinKit.StopAllResult {
        try await perform { ThinktinKit.StopAllResult(core: try await core.stopAll()) }
    }

    public func signOutOtherDevices(stopAgents: Bool) async throws -> ThinktinKit.SignOutOthersResult {
        try await perform {
            ThinktinKit.SignOutOthersResult(core: try await core.signOutOtherDevices(stopAgents: stopAgents))
        }
    }

    // MARK: agent 与实例

    public func agents() async throws -> [ThinktinKit.AgentInfo] {
        try await perform { try await core.agents().map { ThinktinKit.AgentInfo(core: $0) } }
    }

    public func instances() async throws -> [ThinktinKit.Instance] {
        try await perform { try await core.instances().map { ThinktinKit.Instance(core: $0) } }
    }

    public func cachedInstances() throws -> [ThinktinKit.Instance] {
        try performSync { try core.cachedInstances().map { ThinktinKit.Instance(core: $0) } }
    }

    public func adopt(agentID: AgentID, name: String, harness: String?) async throws -> ThinktinKit.Instance {
        try await perform {
            ThinktinKit.Instance(core: try await core.adopt(agentId: agentID.rawValue, name: name, harness: harness))
        }
    }

    public func renameInstance(_ instanceID: InstanceID, name: String) async throws -> ThinktinKit.Instance {
        try await perform {
            ThinktinKit.Instance(core: try await core.renameInstance(instanceId: instanceID.rawValue, name: name))
        }
    }

    public func setInstanceVersion(_ instanceID: InstanceID, version: String?) async throws -> ThinktinKit.Instance {
        try await perform {
            ThinktinKit.Instance(
                core: try await core.setInstanceVersion(instanceId: instanceID.rawValue, version: version))
        }
    }

    public func modelRoutes(instanceID: InstanceID) async throws -> [ThinktinKit.ModelRoute] {
        try await perform {
            try await core.modelRoutes(instanceId: instanceID.rawValue).map { ThinktinKit.ModelRoute(core: $0) }
        }
    }

    public func setModelRoutes(instanceID: InstanceID, routes: [ThinktinKit.ModelRoute]) async throws {
        try await perform {
            try await core.setModelRoutes(instanceId: instanceID.rawValue, routes: routes.map(\.core))
        }
    }

    public func deleteInstance(_ instanceID: InstanceID) async throws {
        try await perform { try await core.deleteInstance(instanceId: instanceID.rawValue) }
    }

    // MARK: 运行

    public func createRun(instanceID: InstanceID, prompt: String) async throws -> ThinktinKit.Run {
        try await perform {
            ThinktinKit.Run(core: try await core.createRun(instanceId: instanceID.rawValue, prompt: prompt))
        }
    }

    public func runs(instanceID: InstanceID, limit: Int) async throws -> [ThinktinKit.Run] {
        try await perform {
            try await core.runs(instanceId: instanceID.rawValue, limit: Self.count(limit)).map {
                ThinktinKit.Run(core: $0)
            }
        }
    }

    public func cachedRuns(instanceID: InstanceID, limit: Int) throws -> [ThinktinKit.Run] {
        try performSync {
            try core.cachedRuns(instanceId: instanceID.rawValue, limit: Self.count(limit)).map {
                ThinktinKit.Run(core: $0)
            }
        }
    }

    public func getRun(_ runID: RunID) async throws -> ThinktinKit.Run {
        try await perform { ThinktinKit.Run(core: try await core.getRun(runId: runID.rawValue)) }
    }

    public func cancelRun(_ runID: RunID, wholeTree: Bool) async throws -> ThinktinKit.Run {
        try await perform {
            ThinktinKit.Run(core: try await core.cancelRun(runId: runID.rawValue, wholeTree: wholeTree))
        }
    }

    public func runTree(_ runID: RunID) async throws -> [ThinktinKit.Run] {
        try await perform { try await core.runTree(runId: runID.rawValue).map { ThinktinKit.Run(core: $0) } }
    }

    public func runArtifacts(_ runID: RunID) async throws -> [ThinktinKit.Artifact] {
        try await perform {
            try await core.runArtifacts(runId: runID.rawValue).map { ThinktinKit.Artifact(core: $0) }
        }
    }

    public func artifactContent(_ artifactID: ArtifactID) async throws -> Data {
        try await perform { try await core.artifactContent(artifactId: artifactID.rawValue) }
    }

    // MARK: 事件流

    /// 回调在 client-core 的后台线程上（同一个订阅按顺序回调）。返回的句柄 `stop()` 或释放就停止。
    /// 实例 id 格式不对时抛 `invalidArgument`；没登录、实例不存在不抛错，而是回调最终状态（`signedOut`、`notFound`）。
    ///
    /// `listener` 被订阅强引用，直到收到最终状态（和 `MockClient` 一样）：`events(instanceID:)` 的 `StreamListener`
    /// 只有订阅持有它。所以视图模型不要只靠自己的 `deinit` 停订阅（它被订阅持有，不会释放），离开页面时调 `stop()`。
    public func subscribe(instanceID: InstanceID, afterSeq: UInt64?, listener: any EventListening) throws
        -> EventSubscriptionHandle
    {
        let bridge = EventListenerBridge(listener, afterSeq: afterSeq)
        let subscription = try performSync { try core.subscribe(instanceId: instanceID.rawValue, listener: bridge) }
        return EventSubscriptionHandle { subscription.stop() }
    }

    public func cachedEvents(instanceID: InstanceID, afterSeq: UInt64, limit: Int) throws -> [ThinktinKit.InstanceEvent]
    {
        try performSync {
            try core.cachedEvents(instanceId: instanceID.rawValue, afterSeq: afterSeq, limit: Self.count(limit)).map {
                ThinktinKit.InstanceEvent(core: $0)
            }
        }
    }

    // MARK: 审批

    public func approvals() async throws -> [ThinktinKit.Approval] {
        try await perform { try await core.approvals().map { ThinktinKit.Approval(core: $0) } }
    }

    public func decideApproval(_ approvalID: ApprovalID, optionID: String) async throws -> ThinktinKit.Approval {
        try await perform {
            ThinktinKit.Approval(
                core: try await core.decideApproval(approvalId: approvalID.rawValue, optionId: optionID))
        }
    }

    // MARK: 计划

    public func plans(instanceID: InstanceID?) async throws -> [ThinktinKit.Plan] {
        try await perform {
            try await core.plans(instanceId: instanceID?.rawValue).map { ThinktinKit.Plan(core: $0) }
        }
    }

    public func getPlan(_ planID: PlanID) async throws -> ThinktinKit.Plan {
        try await perform { ThinktinKit.Plan(core: try await core.getPlan(planId: planID.rawValue)) }
    }

    public func createPlan(_ plan: ThinktinKit.NewPlan) async throws -> ThinktinKit.Plan {
        try await perform { ThinktinKit.Plan(core: try await core.createPlan(plan: plan.core)) }
    }

    public func setPlanPaused(_ planID: PlanID, paused: Bool) async throws -> ThinktinKit.Plan {
        try await perform {
            ThinktinKit.Plan(core: try await core.setPlanPaused(planId: planID.rawValue, paused: paused))
        }
    }

    public func confirmPlan(_ planID: PlanID, revision: Int) async throws -> ThinktinKit.Plan {
        try await perform {
            ThinktinKit.Plan(
                core: try await core.confirmPlan(planId: planID.rawValue, revision: UInt32(clamping: revision)))
        }
    }

    public func deletePlan(_ planID: PlanID) async throws {
        try await perform { try await core.deletePlan(planId: planID.rawValue) }
    }

    // MARK: 收件箱

    public func syncInbox(limit: Int) async throws -> ThinktinKit.InboxPage {
        try await perform { ThinktinKit.InboxPage(core: try await core.syncInbox(limit: Self.count(limit))) }
    }

    public func olderInbox(before: InboxItemID, limit: Int) async throws -> [ThinktinKit.InboxItem] {
        try await perform {
            try await core.olderInbox(beforeId: before.rawValue, limit: Self.count(limit)).map {
                ThinktinKit.InboxItem(core: $0)
            }
        }
    }

    public func cachedInbox(before: InboxItemID?, limit: Int) throws -> [ThinktinKit.InboxItem] {
        try performSync {
            try core.cachedInbox(beforeId: before?.rawValue, limit: Self.count(limit)).map {
                ThinktinKit.InboxItem(core: $0)
            }
        }
    }

    public func cachedUnread() throws -> Int {
        try performSync { Int(clamping: try core.cachedUnread()) }
    }

    public func markInboxRead(ids: [InboxItemID], upTo: InboxItemID?) async throws -> Int {
        try await perform {
            Int(clamping: try await core.markInboxRead(ids: ids.map(\.rawValue), upToId: upTo?.rawValue))
        }
    }

    // MARK: 用量

    public func usage(group: UsageGroup, from: Date?, to: Date?, timeZone: TimeZone?) async throws
        -> ThinktinKit.UsageSummary
    {
        try await perform {
            ThinktinKit.UsageSummary(
                core: try await core.usage(
                    group: group.rawValue, fromMs: from?.unixMilliseconds, toMs: to?.unixMilliseconds,
                    tz: timeZone?.identifier))
        }
    }

    // MARK: 模型 key

    public func vendors() async throws -> [ThinktinKit.VendorInfo] {
        try await perform { try await core.vendors().map { ThinktinKit.VendorInfo(core: $0) } }
    }

    public func credentials() async throws -> [ThinktinKit.Credential] {
        try await perform { try await core.credentials().map { ThinktinKit.Credential(core: $0) } }
    }

    public func addCredential(_ credential: ThinktinKit.NewCredential) async throws -> ThinktinKit.Credential {
        try await perform { ThinktinKit.Credential(core: try await core.addCredential(credential: credential.core)) }
    }

    public func deleteCredential(_ credentialID: CredentialID) async throws {
        try await perform { try await core.deleteCredential(credentialId: credentialID.rawValue) }
    }

    // MARK: IM 渠道

    public func imChannels() async throws -> [ThinktinKit.ImChannel] {
        try await perform { try await core.imChannels().map { ThinktinKit.ImChannel(core: $0) } }
    }

    public func addImChannel(_ channel: ThinktinKit.NewImChannel) async throws -> ThinktinKit.ImChannel {
        try await perform { ThinktinKit.ImChannel(core: try await core.addImChannel(channel: channel.core)) }
    }

    public func updateImChannel(_ channelID: ImChannelID, label: String?, events: [ImEvent]?, enabled: Bool?)
        async throws -> ThinktinKit.ImChannel
    {
        try await perform {
            ThinktinKit.ImChannel(
                core: try await core.updateImChannel(
                    channelId: channelID.rawValue, label: label, events: events?.map(\.rawValue), enabled: enabled))
        }
    }

    public func replaceImWebhook(_ channelID: ImChannelID, webhookURL: String, secret: String?) async throws
        -> ThinktinKit.ImChannel
    {
        try await perform {
            ThinktinKit.ImChannel(
                core: try await core.replaceImWebhook(
                    channelId: channelID.rawValue, webhookUrl: webhookURL, secret: secret))
        }
    }

    public func testImChannel(_ channelID: ImChannelID) async throws {
        try await perform { try await core.testImChannel(channelId: channelID.rawValue) }
    }

    public func deleteImChannel(_ channelID: ImChannelID) async throws {
        try await perform { try await core.deleteImChannel(channelId: channelID.rawValue) }
    }

    // MARK: 消息与保险箱

    public func sendMessage(instanceID: InstanceID, text: String, allowSecrets: Bool) async throws -> ThinktinKit.Run {
        try await perform {
            ThinktinKit.Run(
                core: try await core.sendMessage(
                    instanceId: instanceID.rawValue, text: text, allowSecrets: allowSecrets))
        }
    }

    public func saveSecretFromMessage(message: String, value: String, item: ThinktinKit.NewVaultItem) async throws
        -> ThinktinKit.SavedSecret
    {
        try await perform {
            ThinktinKit.SavedSecret(
                core: try await core.saveSecretFromMessage(message: message, value: value, item: item.core))
        }
    }

    public func vaultItems() async throws -> [ThinktinKit.VaultItem] {
        try await perform { try await core.vaultItems().map { ThinktinKit.VaultItem(core: $0) } }
    }

    public func vaultItem(_ itemID: VaultItemID) async throws -> ThinktinKit.VaultItemDetail {
        try await perform { ThinktinKit.VaultItemDetail(core: try await core.vaultItem(itemId: itemID.rawValue)) }
    }

    public func createVaultItem(_ item: ThinktinKit.NewVaultItem) async throws -> ThinktinKit.VaultItem {
        try await perform { ThinktinKit.VaultItem(core: try await core.createVaultItem(item: item.core)) }
    }

    public func updateVaultItem(_ itemID: VaultItemID, change: ThinktinKit.VaultItemUpdate) async throws
        -> ThinktinKit.VaultItem
    {
        try await perform {
            ThinktinKit.VaultItem(core: try await core.updateVaultItem(itemId: itemID.rawValue, change: change.core))
        }
    }

    public func deleteVaultItem(_ itemID: VaultItemID) async throws {
        try await perform { try await core.deleteVaultItem(itemId: itemID.rawValue) }
    }

    public func vaultRequests(all: Bool) async throws -> [ThinktinKit.VaultRequest] {
        try await perform { try await core.vaultRequests(all: all).map { ThinktinKit.VaultRequest(core: $0) } }
    }

    public func fulfillVaultRequest(_ requestID: VaultRequestID, username: String, password: String, purpose: String?)
        async throws -> ThinktinKit.VaultRequest
    {
        try await perform {
            ThinktinKit.VaultRequest(
                core: try await core.fulfillVaultRequest(
                    requestId: requestID.rawValue, username: username, password: password, purpose: purpose))
        }
    }

    public func declineVaultRequest(_ requestID: VaultRequestID) async throws -> ThinktinKit.VaultRequest {
        try await perform {
            ThinktinKit.VaultRequest(core: try await core.declineVaultRequest(requestId: requestID.rawValue))
        }
    }
}
