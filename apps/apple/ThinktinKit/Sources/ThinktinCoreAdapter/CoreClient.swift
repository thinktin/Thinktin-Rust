import Foundation
import ThinktinKit

/// `ClientProtocol` 的真实实现：包装 ThinktinCore（UniFFI）的 `ThinktinClient`，经它调 Rust 的 client-core
/// （网络、令牌刷新、事件流续传、SQLite 缓存、密码识别都在那边）。
///
/// 这里只做三件事：参数从领域模型换成 ThinktinCore 的形式（强类型 id → 字符串、`Date` → 毫秒、枚举 → 字符串），
/// 结果换回领域模型（Conversions.swift），错误一律换成 ThinktinKit 的 `ClientError`。唯一多做的一步在 `revokeDevice`：
/// 吊销当前这台时接着退出登录，让本地状态和 `ClientProtocol` 的约定一致（见那里的说明）。
///
/// client-core 的网络操作跑在它自己的 tokio 运行时上，这里的 async 方法只是等结果，可以从任何线程、任何 actor 调；
/// 不带 async 的方法只读本地缓存。事件回调在 client-core 的后台线程上（见 `subscribe`）。
public final class CoreClient: ClientProtocol {
    public let secretDetector: any SecretDetector
    private let core: Core.Client
    /// 和交给 client-core 的是同一个存储：client-core 每次换会话都写进去，这里只读（`revokeDevice` 判断是不是这台）。
    private let sessions: any SessionStoring

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
        self.sessions = sessions
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

    // `ClientProtocol` 的每个方法 client-core 都有对应的。协议先于 client-core 加方法时，那个方法在这里临时抛
    // `ClientError.unsupported(feature:)`（界面提示“暂未开放”，见 docs/ios.md 第 6 节）。

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

    public func updateProfile(displayName: String?) async throws -> ThinktinKit.User {
        try await perform { ThinktinKit.User(core: try await core.updateProfile(displayName: displayName)) }
    }

    public func sendSelfCode(purpose: SelfCodePurpose) async throws {
        try await perform { try await core.sendSelfCode(purpose: purpose.rawValue) }
    }

    /// 成功后 client-core 清掉本地会话（经 `SessionStoring.save(nil)`）和缓存；失败（验证码不对）时什么都不动。
    public func deleteAccount(code: String) async throws {
        try await perform { try await core.deleteAccount(code: code) }
    }

    // MARK: 登录设备与设备消息（14.1）

    public func devices() async throws -> [ThinktinKit.DeviceInfo] {
        try await perform { try await core.devices().map { ThinktinKit.DeviceInfo(core: $0) } }
    }

    /// 吊销当前这台等于退出登录：client-core 只发吊销请求，本地会话要等下一个请求被拒（401）才清，所以这里接着调一次
    /// `logout`，让本地的登录状态和缓存马上清掉（和 `MockClient` 一样，`signedIn()` 立即变成 false）。
    /// 这一步的错误不抛：吊销已经成功，`logout` 无论成败都会清掉本地会话。是不是这台在发请求前判断（请求期间别的调用
    /// 被拒、会话先清掉了，也照样清缓存）。id 按 UUID 比，不分大小写（client-core 解析 id 时也不分）。
    public func revokeDevice(_ deviceID: DeviceID) async throws {
        let isCurrent = sessions.load()?.deviceID.rawValue.lowercased() == deviceID.rawValue.lowercased()
        try await perform { try await core.revokeDevice(deviceId: deviceID.rawValue) }
        if isCurrent {
            try? await core.logout()
        }
    }

    public func sendDeviceMessage(to deviceID: DeviceID, kind: DeviceMessageKind, bodyJSON: String) async throws
        -> ThinktinKit.DeviceMessage
    {
        try await perform {
            ThinktinKit.DeviceMessage(
                core: try await core.sendDeviceMessage(
                    toDeviceId: deviceID.rawValue, kind: kind.rawValue, bodyJson: bodyJSON))
        }
    }

    public func deviceMessages() async throws -> [ThinktinKit.DeviceMessage] {
        try await perform { try await core.deviceMessages().map { ThinktinKit.DeviceMessage(core: $0) } }
    }

    public func ackDeviceMessages(ids: [DeviceMessageID]) async throws -> Int {
        try await perform { Int(clamping: try await core.ackDeviceMessages(ids: ids.map(\.rawValue))) }
    }

    // MARK: 实时活动（10.6）

    public func setLiveActivityStartToken(_ token: String?) async throws {
        try await perform { try await core.setLiveActivityStartToken(token: token) }
    }

    /// 同一个令牌再登记服务端什么都不变（不重发）；运行结束 10 分钟以上的抛 `api(status: 422, code: .invalid)`，
    /// App 在本地结束这个实时活动（`LiveActivityLimits.isTooLateToRegister` 可以先判断，省一次请求）。
    public func registerLiveActivity(runID: RunID, token: String) async throws {
        try await perform { try await core.registerLiveActivity(runId: runID.rawValue, token: token) }
    }

    public func endLiveActivity(runID: RunID) async throws {
        try await perform { try await core.endLiveActivity(runId: runID.rawValue) }
    }

    // MARK: agent 与实例

    public func agents() async throws -> [ThinktinKit.AgentInfo] {
        try await perform { try await core.agents().map { ThinktinKit.AgentInfo(core: $0) } }
    }

    public func instances() async throws -> [ThinktinKit.Instance] {
        try await perform { try await core.instances().map { ThinktinKit.Instance(core: $0) } }
    }

    public func instance(_ instanceID: InstanceID) async throws -> ThinktinKit.Instance {
        try await perform { ThinktinKit.Instance(core: try await core.instance(instanceId: instanceID.rawValue)) }
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

    public func olderRuns(instanceID: InstanceID, before: RunID, limit: Int) async throws -> [ThinktinKit.Run] {
        try await perform {
            let runs = try await core.olderRuns(
                instanceId: instanceID.rawValue, beforeRunId: before.rawValue, limit: Self.count(limit))
            return runs.map { ThinktinKit.Run(core: $0) }
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

    public func instanceArtifacts(_ instanceID: InstanceID, limit: Int) async throws -> [ThinktinKit.Artifact] {
        try await perform {
            try await core.instanceArtifacts(instanceId: instanceID.rawValue, limit: Self.count(limit)).map {
                ThinktinKit.Artifact(core: $0)
            }
        }
    }

    public func artifactContent(_ artifactID: ArtifactID) async throws -> Data {
        try await perform { try await core.artifactContent(artifactId: artifactID.rawValue) }
    }

    public func deleteArtifact(_ artifactID: ArtifactID) async throws {
        try await perform { try await core.deleteArtifact(artifactId: artifactID.rawValue) }
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

    public func updatePlan(_ planID: PlanID, change: ThinktinKit.PlanChange) async throws -> ThinktinKit.Plan {
        try await perform {
            ThinktinKit.Plan(core: try await core.updatePlan(planId: planID.rawValue, change: change.core))
        }
    }

    public func addTrigger(planID: PlanID, schedule: ThinktinKit.Schedule) async throws -> ThinktinKit.Trigger {
        try await perform {
            ThinktinKit.Trigger(core: try await core.addTrigger(planId: planID.rawValue, schedule: schedule.core))
        }
    }

    public func deleteTrigger(_ triggerID: TriggerID) async throws {
        try await perform { try await core.deleteTrigger(triggerId: triggerID.rawValue) }
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

    public func inboxItem(_ itemID: InboxItemID) async throws -> ThinktinKit.InboxItem {
        try await perform { ThinktinKit.InboxItem(core: try await core.inboxItem(itemId: itemID.rawValue)) }
    }

    /// 有缓存时未读数取缓存里的（改完本地的那条），没有缓存时 client-core 再问一次服务端。
    public func markInboxUnread(_ itemID: InboxItemID) async throws -> Int {
        try await perform { Int(clamping: try await core.markInboxUnread(itemId: itemID.rawValue)) }
    }

    public func deleteInboxItem(_ itemID: InboxItemID) async throws {
        try await perform { try await core.deleteInboxItem(itemId: itemID.rawValue) }
    }

    // MARK: 团队与团队模板（8.1）

    public func teams() async throws -> [ThinktinKit.Team] {
        try await perform { try await core.teams().map { ThinktinKit.Team(core: $0) } }
    }

    public func team(_ teamID: TeamID) async throws -> ThinktinKit.Team {
        try await perform { ThinktinKit.Team(core: try await core.team(teamId: teamID.rawValue)) }
    }

    public func createTeam(name: String, members: [ThinktinKit.TeamMember]) async throws -> ThinktinKit.Team {
        try await perform {
            ThinktinKit.Team(core: try await core.createTeam(name: name, members: members.map(\.core)))
        }
    }

    public func updateTeam(_ teamID: TeamID, name: String?, members: [ThinktinKit.TeamMember]?) async throws
        -> ThinktinKit.Team
    {
        try await perform {
            ThinktinKit.Team(
                core: try await core.updateTeam(teamId: teamID.rawValue, name: name, members: members?.map(\.core)))
        }
    }

    public func deleteTeam(_ teamID: TeamID) async throws {
        try await perform { try await core.deleteTeam(teamId: teamID.rawValue) }
    }

    public func teamTemplates() async throws -> [ThinktinKit.TeamTemplate] {
        try await perform { try await core.teamTemplates().map { ThinktinKit.TeamTemplate(core: $0) } }
    }

    public func createTeamTemplate(name: String, members: [ThinktinKit.TemplateMember]) async throws
        -> ThinktinKit.TeamTemplate
    {
        try await perform {
            ThinktinKit.TeamTemplate(
                core: try await core.createTeamTemplate(name: name, members: members.map(\.core)))
        }
    }

    public func createTeamTemplateFromTeam(name: String, teamID: TeamID) async throws -> ThinktinKit.TeamTemplate {
        try await perform {
            ThinktinKit.TeamTemplate(
                core: try await core.createTeamTemplateFromTeam(name: name, teamId: teamID.rawValue))
        }
    }

    public func deleteTeamTemplate(_ templateID: TeamTemplateID) async throws {
        try await perform { try await core.deleteTeamTemplate(templateId: templateID.rawValue) }
    }

    public func adoptTeamTemplate(_ templateID: TeamTemplateID, name: String?) async throws -> ThinktinKit.Team {
        try await perform {
            ThinktinKit.Team(core: try await core.adoptTeamTemplate(templateId: templateID.rawValue, name: name))
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

    public func updateCredential(_ credentialID: CredentialID, label: String?, disabled: Bool?) async throws
        -> ThinktinKit.Credential
    {
        try await perform {
            ThinktinKit.Credential(
                core: try await core.updateCredential(
                    credentialId: credentialID.rawValue, label: label, disabled: disabled))
        }
    }

    public func replaceCredentialSecret(_ credentialID: CredentialID, apiKey: String) async throws
        -> ThinktinKit.Credential
    {
        try await perform {
            ThinktinKit.Credential(
                core: try await core.replaceCredentialSecret(credentialId: credentialID.rawValue, apiKey: apiKey))
        }
    }

    public func deleteCredential(_ credentialID: CredentialID) async throws {
        try await perform { try await core.deleteCredential(credentialId: credentialID.rawValue) }
    }

    // MARK: 内容举报（5.5）

    /// `reason` 是不认识的取值（`.unknown`）时 client-core 不发请求，抛 `invalidArgument`。
    public func reportContent(
        runID: RunID, eventSeq: UInt64?, artifactID: ArtifactID?, reason: ReportReason, note: String?
    ) async throws -> ThinktinKit.ContentReport {
        try await perform {
            ThinktinKit.ContentReport(
                core: try await core.reportContent(
                    runId: runID.rawValue, eventSeq: eventSeq, artifactId: artifactID?.rawValue,
                    reason: reason.rawValue, note: note))
        }
    }

    public func reports() async throws -> [ThinktinKit.ContentReport] {
        try await perform { try await core.reports().map { ThinktinKit.ContentReport(core: $0) } }
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
