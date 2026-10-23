import Foundation

/// `MockClient` 的全部内存状态。可以整体换掉（`MockClient(state:)`），测试里也可以直接改。
public struct MockState: Sendable {
    /// 当前会话；为 nil 表示没登录。
    public var session: Session?
    public var user: User
    /// 登录要填的验证码。
    public var verificationCode: String
    public var agents: [AgentInfo]
    public var instances: [Instance]
    public var routes: [InstanceID: [ModelRoute]]
    public var runs: [Run]
    /// 每个实例的事件（按 seq 升序）。
    public var events: [InstanceID: [InstanceEvent]]
    public var approvals: [Approval]
    public var plans: [Plan]
    /// 收件箱（最新的在前）。
    public var inbox: [InboxItem]
    public var vendors: [VendorInfo]
    public var credentials: [Credential]
    /// 按天的用量（`key` 是 `yyyy-MM-dd`）。
    public var dailyUsage: [UsageBucket]
    public var artifacts: [Artifact]
    public var artifactContents: [ArtifactID: Data]
    public var vaultItems: [VaultItem]
    public var vaultUsernames: [VaultItemID: String]
    public var vaultRequests: [VaultRequest]
    public var imChannels: [ImChannel]
    /// 登录着的设备（吊销了的删掉）。当前这台是 `session.deviceID` 那台，`isCurrent` 读出来时按会话算。
    public var devices: [DeviceInfo]
    /// 设备之间转发、还没收下的消息（发给谁的都在这里）。
    public var deviceMessages: [DeviceMessage]
    /// 这台设备上登记了的实时活动（10.6），按运行。
    public var liveActivities: [RunID: MockLiveActivity]
    /// 这台设备的推送开启令牌（10.6）；没登记为 nil。
    public var liveActivityStartToken: String?
    /// 团队（先建的在前）。
    public var teams: [Team]
    /// 团队模板（先建的在前）。
    public var teamTemplates: [TeamTemplate]
    /// 自己的内容举报（新的在前）。
    public var reports: [ContentReport]
    /// 请求带的 `Accept-Language`（11.8，`setAcceptLanguage`）；nil 是不带（服务端按中文）。新用户登录时按它定语言，
    /// `agents()` 的介绍和许可说明按它给中文或英文。
    public var acceptLanguage: String?
    /// 服务端说过这个版本太老了（11.8，`upgradeRequired()`）：任何调用抛过 `upgradeRequired` 后一直是 true，之后的
    /// 订阅直接以 `stopped` 结束。预览升级页时可以直接设成 true。
    public var isUpgradeRequired: Bool
    /// 账号最多几个没删除的实例（11.9，服务端的 `[api.limits] instances_per_user`）；0 不限（默认，和服务端一样）。
    /// 到了上限领养抛 409 `instance_limit`，团队模板放不下整个团队时一个也不领养。
    public var instancesPerUser: Int

    public init(
        session: Session? = nil, user: User, verificationCode: String = "123456", agents: [AgentInfo] = [],
        instances: [Instance] = [], routes: [InstanceID: [ModelRoute]] = [:], runs: [Run] = [],
        events: [InstanceID: [InstanceEvent]] = [:], approvals: [Approval] = [], plans: [Plan] = [],
        inbox: [InboxItem] = [], vendors: [VendorInfo] = [], credentials: [Credential] = [],
        dailyUsage: [UsageBucket] = [], artifacts: [Artifact] = [], artifactContents: [ArtifactID: Data] = [:],
        vaultItems: [VaultItem] = [], vaultUsernames: [VaultItemID: String] = [:], vaultRequests: [VaultRequest] = [],
        imChannels: [ImChannel] = [], devices: [DeviceInfo] = [], deviceMessages: [DeviceMessage] = [],
        liveActivities: [RunID: MockLiveActivity] = [:], liveActivityStartToken: String? = nil, teams: [Team] = [],
        teamTemplates: [TeamTemplate] = [], reports: [ContentReport] = [], acceptLanguage: String? = nil,
        isUpgradeRequired: Bool = false, instancesPerUser: Int = 0
    ) {
        self.session = session
        self.user = user
        self.verificationCode = verificationCode
        self.agents = agents
        self.instances = instances
        self.routes = routes
        self.runs = runs
        self.events = events
        self.approvals = approvals
        self.plans = plans
        self.inbox = inbox
        self.vendors = vendors
        self.credentials = credentials
        self.dailyUsage = dailyUsage
        self.artifacts = artifacts
        self.artifactContents = artifactContents
        self.vaultItems = vaultItems
        self.vaultUsernames = vaultUsernames
        self.vaultRequests = vaultRequests
        self.imChannels = imChannels
        self.devices = devices
        self.deviceMessages = deviceMessages
        self.liveActivities = liveActivities
        self.liveActivityStartToken = liveActivityStartToken
        self.teams = teams
        self.teamTemplates = teamTemplates
        self.reports = reports
        self.acceptLanguage = acceptLanguage
        self.isUpgradeRequired = isUpgradeRequired
        self.instancesPerUser = instancesPerUser
    }

    /// 按 `acceptLanguage` 认出的语言（服务端的规则，认不出时用中文）。
    public var requestLocale: UserLocale {
        acceptLanguage.flatMap { UserLocale(acceptLanguage: $0) } ?? .zhCN
    }

    /// 实例最后一条事件的 seq（没有为 0）。
    public func lastSeq(of instanceID: InstanceID) -> UInt64 {
        events[instanceID]?.last?.seq ?? 0
    }

    /// 未读数。
    public var unreadCount: Int { inbox.filter { !$0.isRead }.count }
}

/// Mock 里登记的一个实时活动（10.6）：这台设备上一个运行的推送令牌，以及后台按它推送了几次。
public struct MockLiveActivity: Hashable, Sendable {
    /// ActivityKit 给的推送令牌（十六进制）。
    public var token: String
    /// App 关掉了（`endLiveActivity`）：不再推送；同一个令牌再登记也不重新打开，换了令牌才算新的。
    public var isEnded: Bool
    /// 登记这个令牌的时间（实时活动最多显示 8 小时，从这里算）。
    public var registeredAt: Date
    /// 后台按当时的状态推送了几次：换令牌时马上重发一次，同一个令牌再登记不重发。
    public var pushCount: Int

    public init(token: String, isEnded: Bool = false, registeredAt: Date, pushCount: Int = 1) {
        self.token = token
        self.isEnded = isEnded
        self.registeredAt = registeredAt
        self.pushCount = pushCount
    }

    /// 还在推送（没关掉、没过 8 小时），占一台设备的名额。
    public func isOpen(now: Date = Date()) -> Bool {
        !isEnded && now.timeIntervalSince(registeredAt) < LiveActivityLimits.maxAge
    }
}
