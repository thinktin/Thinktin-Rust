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
    /// 下线其他设备（4.6）。`stopAgents` 时顺带全部停止（怀疑账号被盗时）。
    func signOutOtherDevices(stopAgents: Bool) async throws -> SignOutOthersResult

    // MARK: agent 与实例

    func agents() async throws -> [AgentInfo]
    /// 拉实例列表（同时更新缓存）。
    func instances() async throws -> [Instance]
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
    func runs(instanceID: InstanceID, limit: Int) async throws -> [Run]
    func cachedRuns(instanceID: InstanceID, limit: Int) throws -> [Run]
    func getRun(_ runID: RunID) async throws -> Run
    /// 取消；`wholeTree` 时停掉整棵运行树（流水线）。
    func cancelRun(_ runID: RunID, wholeTree: Bool) async throws -> Run
    func runTree(_ runID: RunID) async throws -> [Run]
    func runArtifacts(_ runID: RunID) async throws -> [Artifact]
    func artifactContent(_ artifactID: ArtifactID) async throws -> Data

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

    // MARK: 用量

    /// 用量汇总。时间不给就是最近 30 天；`timeZone` 是按天分组的时区（默认 Asia/Shanghai）。
    func usage(group: UsageGroup, from: Date?, to: Date?, timeZone: TimeZone?) async throws -> UsageSummary

    // MARK: 模型 key

    /// 预置的模型厂商（添加 key 时选）。
    func vendors() async throws -> [VendorInfo]
    func credentials() async throws -> [Credential]
    func addCredential(_ credential: NewCredential) async throws -> Credential
    func deleteCredential(_ credentialID: CredentialID) async throws

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
