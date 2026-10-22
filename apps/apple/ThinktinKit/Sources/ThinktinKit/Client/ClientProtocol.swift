import Foundation

/// 平台客户端：和 ThinktinCore 的 `ThinktinClient`（crates/client-core/src/ffi.rs）的公开方法一一对应，
/// 参数和返回值换成领域模型（强类型 id、`Date`、枚举）。错误一律是 `ClientError`。
///
/// 实现：`CoreClient`（ThinktinCoreAdapter，经 UniFFI 调 Rust）、`MockClient`（演示数据，预览和测试用）。
/// 名字和 `ThinktinClient` 的方法相同，只是 id 参数去掉了重复的标签（`getRun(_:)` 对应 `get_run(run_id)`）。
/// 不带 `async` 的方法只读本地缓存，可以在主线程上调。
public protocol ClientProtocol: AnyObject, Sendable {
    /// 发送前的密码检查（`detect_secrets`、`redact_message`、`unique_vault_name`）。
    var secretDetector: any SecretDetector { get }

    // MARK: 账号

    /// 已经登录（有会话）。
    func signedIn() -> Bool
    func sendCode(phone: String) async throws
    /// 登录（没注册过的手机号自动注册）。`push` 是推送通道和令牌，可以登录后再用 `setPushToken` 给。
    func login(phone: String, code: String, push: PushRegistration?) async throws -> LoginResult
    func logout() async throws
    func me() async throws -> User
    /// 推送、收件箱用的语言（1.6）。用户在 App 里换语言时调一次。
    func setLocale(_ locale: UserLocale) async throws -> User
    /// 推送令牌变了（重装、系统重置）时更新。
    func setPushToken(_ push: PushRegistration) async throws
    /// 全部停止（4.6）：取消所有运行、吊销全部运行授权、暂停全部计划。
    func stopAll() async throws -> StopAllResult
    /// 下线其他设备（4.6），只留当前这台。`stopAgents` 时顺带全部停止（怀疑账号被盗时）。
    func signOutOtherDevices(stopAgents: Bool) async throws -> SignOutOthersResult
    /// 改昵称；传 nil 清掉（界面上显示打码的手机号）。1 到 64 个字符，空字符串抛 invalid。
    func updateProfile(displayName: String?) async throws -> User
    /// 给自己的手机号发验证码，做敏感操作前确认（注销账号、换手机号）。
    func sendSelfCode(purpose: SelfCodePurpose) async throws
    /// 注销账号（16.4）：用 `sendSelfCode(purpose: .deleteAccount)` 发来的验证码确认。内容全部删除、不能恢复；
    /// 成功后本地的登录状态和缓存一起清掉（`signedIn()` 变成 false，缓存类方法返回空）。
    func deleteAccount(code: String) async throws

    // MARK: 登录设备与设备消息（14.1）

    /// 登录着的设备（吊销了的不在里面），最近活跃的在前；`isCurrent` 的是这台，`isOnline` 的电脑连着设备中继。
    func devices() async throws -> [DeviceInfo]
    /// 吊销一台设备（丢了的手机、不用的电脑）：它的登录会话立即失效。吊销当前这台等于退出登录。
    func revokeDevice(_ deviceID: DeviceID) async throws
    /// 发给自己的另一台设备（手机发给电脑：配对应答、审批决定、能力令牌、吊销）。`bodyJSON` 是消息内容的 JSON，
    /// 格式和签名见 docs/pairing.md。电脑不在线时排队，连上设备中继后投递。不是 JSON 时抛 `invalidArgument`；
    /// 发给自己、方向不对（手机发给手机、电脑才能发的种类）时抛 invalid；对方不存在或已吊销时抛 not_found。
    func sendDeviceMessage(to deviceID: DeviceID, kind: DeviceMessageKind, bodyJSON: String) async throws
        -> DeviceMessage
    /// 别的设备发给这台、还没收下的消息（电脑发来的配对确认、审批请求），按发出的顺序；过期的不再返回。
    func deviceMessages() async throws -> [DeviceMessage]
    /// 收下了这些消息（验过签、处理完），之后不再返回。一次 1 到 200 条（不在范围抛 invalid）。返回确认的条数
    /// （已经收下过的、不是发给这台的不算）。
    func ackDeviceMessages(ids: [DeviceMessageID]) async throws -> Int

    // MARK: 实时活动（10.6，只有 iPhone、iPad）

    /// 推送开启令牌（ActivityKit 的 `pushToStartTokenUpdates`，十六进制串，见 `LiveActivityToken`）：用户打开
    /// “计划运行时显示实时活动”时登记，计划到点开始的根运行就在这台设备上远程开启实时活动；关掉时传 nil 清掉。
    /// 只有 iPhone、iPad 能登记（别的设备、格式不对抛 invalid）。一个令牌只属于一台设备；设备下线、注销账号时服务端清掉。
    func setLiveActivityStartToken(_ token: String?) async throws
    /// 这个运行开了实时活动，或者远程开启的拿到了令牌：登记它的推送令牌（ActivityKit 的 `pushTokenUpdates`，
    /// 十六进制串）。之后运行的状态、步数变了、结束了，后台推送更新（docs/live-activities.md 第 3 节的
    /// `RunActivityAttributes`）。
    ///
    /// - 换了令牌（新的实时活动）：马上按现在的状态重发一次，8 小时从现在算；同一个令牌再登记什么都不变、不重发
    ///   （连着发送失败、后台放弃了的从头再来；`endLiveActivity` 关掉了的不重新打开，换了令牌才算新的）。
    /// - 运行结束 10 分钟以上的抛 invalid（422）：App 在本地结束这个实时活动。别人的运行、不存在的抛 not_found。
    /// - 只有 iPhone、iPad；一台设备同时最多 10 个（多了抛 invalid）。
    func registerLiveActivity(runID: RunID, token: String) async throws
    /// 这个运行的实时活动关掉了（用户划掉了、App 自己结束了）：后台不再推送。没登记过也算成功。
    func endLiveActivity(runID: RunID) async throws

    // MARK: agent 与实例

    func agents() async throws -> [AgentInfo]
    /// 拉实例列表（同时更新缓存）。
    func instances() async throws -> [Instance]
    /// 一个实例（从推送、深链进来时用）。
    func instance(_ instanceID: InstanceID) async throws -> Instance
    /// 缓存里的实例列表（离线、启动时先显示）。
    func cachedInstances() throws -> [Instance]
    func adopt(agentID: AgentID, name: String, harness: String?) async throws -> Instance
    func renameInstance(_ instanceID: InstanceID, name: String) async throws -> Instance
    /// 升级（`version` 为 nil）或回滚到旧版本：下次唤醒时生效，工作区保留。
    func setInstanceVersion(_ instanceID: InstanceID, version: String?) async throws -> Instance
    func modelRoutes(instanceID: InstanceID) async throws -> [ModelRoute]
    /// 整体替换实例的模型别名（叫 main 的是默认模型）。
    func setModelRoutes(instanceID: InstanceID, routes: [ModelRoute]) async throws
    func deleteInstance(_ instanceID: InstanceID) async throws

    // MARK: 运行

    func createRun(instanceID: InstanceID, prompt: String) async throws -> Run
    /// 实例最新的一页运行，新的在前（同时更新缓存）。
    func runs(instanceID: InstanceID, limit: Int) async throws -> [Run]
    /// 更早的一页运行：`before` 之前的（列表往下翻），新的在前。
    func olderRuns(instanceID: InstanceID, before: RunID, limit: Int) async throws -> [Run]
    func cachedRuns(instanceID: InstanceID, limit: Int) throws -> [Run]
    func getRun(_ runID: RunID) async throws -> Run
    /// 取消；`wholeTree` 时停掉整棵运行树（流水线）。
    func cancelRun(_ runID: RunID, wholeTree: Bool) async throws -> Run
    func runTree(_ runID: RunID) async throws -> [Run]
    func runArtifacts(_ runID: RunID) async throws -> [Artifact]
    /// 实例的产出物，新的在前（最多 `limit` 个，上限 500）。
    func instanceArtifacts(_ instanceID: InstanceID, limit: Int) async throws -> [Artifact]
    func artifactContent(_ artifactID: ArtifactID) async throws -> Data
    func deleteArtifact(_ artifactID: ArtifactID) async throws

    // MARK: 事件流

    /// 开始收实例的事件：先补发缓存续传位置之后的，再实时推送。`afterSeq` 之前（含）的事件不再回调
    /// （已经从 `cachedEvents` 显示过的）；为 nil 时全部回调。回调在后台线程上。
    func subscribe(instanceID: InstanceID, afterSeq: UInt64?, listener: any EventListening) throws
        -> EventSubscriptionHandle
    /// 缓存里 `afterSeq` 之后的事件（打开页面时先显示）。
    func cachedEvents(instanceID: InstanceID, afterSeq: UInt64, limit: Int) throws -> [InstanceEvent]

    // MARK: 审批

    func approvals() async throws -> [Approval]
    /// 选一个选项。批准前 App 要先做生物识别确认。
    func decideApproval(_ approvalID: ApprovalID, optionID: String) async throws -> Approval

    // MARK: 计划

    /// `instanceID` 为 nil 时是全部实例的计划。
    func plans(instanceID: InstanceID?) async throws -> [Plan]
    func getPlan(_ planID: PlanID) async throws -> Plan
    func createPlan(_ plan: NewPlan) async throws -> Plan
    /// 改计划：标题、目标、策略、补跑方式、流水线步骤，给了才改（见 `PlanChange`）。返回改完的计划（带触发器和步骤），
    /// 版本号加一。
    func updatePlan(_ planID: PlanID, change: PlanChange) async throws -> Plan
    /// 给计划加一个触发器（一个计划最多 10 个）。
    func addTrigger(planID: PlanID, schedule: Schedule) async throws -> Trigger
    func deleteTrigger(_ triggerID: TriggerID) async throws
    /// 暂停或恢复用户自己的计划。等确认的计划要用 `confirmPlan`。
    func setPlanPaused(_ planID: PlanID, paused: Bool) async throws -> Plan
    /// 确认 agent 新建或修改的计划。`revision` 是界面上展示的那个版本，之后又被改过会返回冲突。
    func confirmPlan(_ planID: PlanID, revision: Int) async throws -> Plan
    func deletePlan(_ planID: PlanID) async throws

    // MARK: 收件箱

    /// 同步收件箱：补发离线已读，拉最新一页，合并进缓存。
    func syncInbox(limit: Int) async throws -> InboxPage
    func olderInbox(before: InboxItemID, limit: Int) async throws -> [InboxItem]
    func cachedInbox(before: InboxItemID?, limit: Int) throws -> [InboxItem]
    func cachedUnread() throws -> Int
    /// 标已读（没网也立即生效，联网后补发）。`ids` 为空表示全部已读，到 `upTo` 为止。返回未读数。
    func markInboxRead(ids: [InboxItemID], upTo: InboxItemID?) async throws -> Int
    /// 一条通知（从推送点进来时用），同时更新缓存。
    func inboxItem(_ itemID: InboxItemID) async throws -> InboxItem
    /// 标回未读（要联网：先补发离线时标的已读，免得之后又被标成已读）。返回未读数。
    func markInboxUnread(_ itemID: InboxItemID) async throws -> Int
    /// 删一条通知（缓存里一起删）。
    func deleteInboxItem(_ itemID: InboxItemID) async throws

    // MARK: 团队与团队模板（8.1）

    /// 全部团队，先建的在前。
    func teams() async throws -> [Team]
    func team(_ teamID: TeamID) async throws -> Team
    /// 把几个实例编成团队：1 到 12 个成员，最多一个负责人（`role = .lead`）。名字 1 到 64 个字符。
    func createTeam(name: String, members: [TeamMember]) async throws -> Team
    /// 改名、换成员（整体替换）；给了才改。
    func updateTeam(_ teamID: TeamID, name: String?, members: [TeamMember]?) async throws -> Team
    /// 删团队（实例不删）。
    func deleteTeam(_ teamID: TeamID) async throws
    func teamTemplates() async throws -> [TeamTemplate]
    /// 新建团队模板，直接给成员（1 到 12 个，agent 要在目录里）。
    func createTeamTemplate(name: String, members: [TemplateMember]) async throws -> TeamTemplate
    /// 从现有团队生成模板（每个成员记下它的 agent、接入方式、名字、角色）。
    func createTeamTemplateFromTeam(name: String, teamID: TeamID) async throws -> TeamTemplate
    func deleteTeamTemplate(_ templateID: TeamTemplateID) async throws
    /// 一键领养一整个团队：每个成员领养一个新实例（还没有模型路由，要再配），再编成团队。`name` 不给就用模板的名字。
    func adoptTeamTemplate(_ templateID: TeamTemplateID, name: String?) async throws -> Team

    // MARK: 用量

    /// 用量汇总。时间不给就是最近 30 天；`timeZone` 是按天分组的时区（默认 Asia/Shanghai）。
    func usage(group: UsageGroup, from: Date?, to: Date?, timeZone: TimeZone?) async throws -> UsageSummary

    // MARK: 模型 key

    /// 预置的模型厂商（添加 key 时选）。
    func vendors() async throws -> [VendorInfo]
    func credentials() async throws -> [Credential]
    func addCredential(_ credential: NewCredential) async throws -> Credential
    /// 改备注（最长 64 个字符，可以为空）、停用或重新启用一把 key；给了才改。
    func updateCredential(_ credentialID: CredentialID, label: String?, disabled: Bool?) async throws -> Credential
    /// 换 key（同一个厂商、同一条记录：模型路由不用改）。等 key 的运行会接着跑。
    func replaceCredentialSecret(_ credentialID: CredentialID, apiKey: String) async throws -> Credential
    func deleteCredential(_ credentialID: CredentialID) async throws

    // MARK: 内容举报（5.5）

    /// 举报 agent 的输出（长按回复或产出物）：`eventSeq` 是那条事件的序号，`artifactID` 是产出物，都不给就是整个运行。
    /// `note` 最多 1000 个字符（去掉首尾空白后为空的当作没写）。只能举报自己的运行（别人的、不存在的抛 not_found；
    /// 事件不属于这个运行、产出物不属于这个运行所在的实例也是）。同一条内容还有待处理的举报时，再举报一次返回那一条
    /// （不重复建）。
    /// 每人每小时 30 次，超了抛 rate_limited。处理结果发到收件箱和推送。`reason` 是不认识的取值时抛 `invalidArgument`。
    func reportContent(runID: RunID, eventSeq: UInt64?, artifactID: ArtifactID?, reason: ReportReason, note: String?)
        async throws -> ContentReport
    /// 自己的举报和处理结果，新的在前（最多 100 条）。
    func reports() async throws -> [ContentReport]

    // MARK: IM 渠道（10.5）

    func imChannels() async throws -> [ImChannel]
    func addImChannel(_ channel: NewImChannel) async throws -> ImChannel
    /// 只改给了的字段。
    func updateImChannel(_ channelID: ImChannelID, label: String?, events: [ImEvent]?, enabled: Bool?) async throws
        -> ImChannel
    func replaceImWebhook(_ channelID: ImChannelID, webhookURL: String, secret: String?) async throws -> ImChannel
    func testImChannel(_ channelID: ImChannelID) async throws
    func deleteImChannel(_ channelID: ImChannelID) async throws

    // MARK: 消息与保险箱（9.11、11.6）

    /// 发一条消息（起一次运行）。消息里有像密码的内容时不发，抛 `containsSecrets`；用户确认要发时带 `allowSecrets`。
    func sendMessage(instanceID: InstanceID, text: String, allowSecrets: Bool) async throws -> Run
    /// 把消息里拦下的值存进保险箱，返回条目和换成引用后的消息。重名时抛 conflict，消息不动。
    func saveSecretFromMessage(message: String, value: String, item: NewVaultItem) async throws -> SavedSecret
    func vaultItems() async throws -> [VaultItem]
    func vaultItem(_ itemID: VaultItemID) async throws -> VaultItemDetail
    func createVaultItem(_ item: NewVaultItem) async throws -> VaultItem
    func updateVaultItem(_ itemID: VaultItemID, change: VaultItemUpdate) async throws -> VaultItem
    func deleteVaultItem(_ itemID: VaultItemID) async throws
    /// agent 请用户填的表单。默认只要还在等的，`all` 时带上处理过的。
    func vaultRequests(all: Bool) async throws -> [VaultRequest]
    /// 填好 agent 要的账号密码。`purpose` 不给就用 agent 写的。
    func fulfillVaultRequest(_ requestID: VaultRequestID, username: String, password: String, purpose: String?)
        async throws -> VaultRequest
    func declineVaultRequest(_ requestID: VaultRequestID) async throws -> VaultRequest
}

extension ClientProtocol {
    /// 登录，推送令牌之后再给。
    public func login(phone: String, code: String) async throws -> LoginResult {
        try await login(phone: phone, code: code, push: nil)
    }

    public func sendMessage(instanceID: InstanceID, text: String) async throws -> Run {
        try await sendMessage(instanceID: instanceID, text: text, allowSecrets: false)
    }

    public func cancelRun(_ runID: RunID) async throws -> Run {
        try await cancelRun(runID, wholeTree: false)
    }

    public func usage(group: UsageGroup) async throws -> UsageSummary {
        try await usage(group: group, from: nil, to: nil, timeZone: nil)
    }

    /// 发设备消息，内容给 `JSONValue`（编成紧凑的 JSON 文本）。
    public func sendDeviceMessage(to deviceID: DeviceID, kind: DeviceMessageKind, body: JSONValue) async throws
        -> DeviceMessage
    {
        try await sendDeviceMessage(to: deviceID, kind: kind, bodyJSON: body.compactString())
    }

    /// 实时活动的推送令牌直接给 ActivityKit 的 `Data`。
    public func registerLiveActivity(runID: RunID, token: Data) async throws {
        try await registerLiveActivity(runID: runID, token: LiveActivityToken.hex(token))
    }

    /// 推送开启令牌直接给 ActivityKit 的 `Data`（清掉用 `setLiveActivityStartToken(nil)`）。
    public func setLiveActivityStartToken(_ token: Data) async throws {
        try await setLiveActivityStartToken(LiveActivityToken.hex(token))
    }

    /// 举报整个运行（它的回复）。
    public func reportRun(_ runID: RunID, reason: ReportReason, note: String? = nil) async throws -> ContentReport {
        try await reportContent(runID: runID, eventSeq: nil, artifactID: nil, reason: reason, note: note)
    }

    /// 举报运行里的一条事件（长按的那条回复）。不属于任何运行的事件不能举报（抛 `invalidArgument`）。
    public func reportEvent(_ event: InstanceEvent, reason: ReportReason, note: String? = nil) async throws
        -> ContentReport
    {
        guard let runID = event.runID else {
            throw ClientError.invalidArgument(message: "event \(event.seq) does not belong to a run")
        }
        return try await reportContent(runID: runID, eventSeq: event.seq, artifactID: nil, reason: reason, note: note)
    }

    /// 举报一个产出物。
    public func reportArtifact(_ artifact: Artifact, reason: ReportReason, note: String? = nil) async throws
        -> ContentReport
    {
        try await reportContent(
            runID: artifact.runID, eventSeq: nil, artifactID: artifact.id, reason: reason, note: note)
    }

    public func detectSecrets(in text: String) -> [DetectedSecret] {
        secretDetector.detectSecrets(in: text)
    }

    /// 事件流转成 `AsyncStream`：循环结束（`break` 或任务取消）时自动停止订阅。
    /// 订阅失败（id 不对）时抛错。
    public func events(instanceID: InstanceID, afterSeq: UInt64? = nil) throws -> AsyncStream<EventStreamElement> {
        let (stream, continuation) = AsyncStream<EventStreamElement>.makeStream(bufferingPolicy: .unbounded)
        let handle = try subscribe(instanceID: instanceID, afterSeq: afterSeq, listener: StreamListener(continuation))
        continuation.onTermination = { _ in handle.stop() }
        return stream
    }
}
