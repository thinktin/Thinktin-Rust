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

    public init(
        session: Session? = nil, user: User, verificationCode: String = "123456", agents: [AgentInfo] = [],
        instances: [Instance] = [], routes: [InstanceID: [ModelRoute]] = [:], runs: [Run] = [],
        events: [InstanceID: [InstanceEvent]] = [:], approvals: [Approval] = [], plans: [Plan] = [],
        inbox: [InboxItem] = [], vendors: [VendorInfo] = [], credentials: [Credential] = [],
        dailyUsage: [UsageBucket] = [], artifacts: [Artifact] = [], artifactContents: [ArtifactID: Data] = [:],
        vaultItems: [VaultItem] = [], vaultUsernames: [VaultItemID: String] = [:], vaultRequests: [VaultRequest] = [],
        imChannels: [ImChannel] = []
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
    }

    /// 实例最后一条事件的 seq（没有为 0）。
    public func lastSeq(of instanceID: InstanceID) -> UInt64 {
        events[instanceID]?.last?.seq ?? 0
    }

    /// 未读数。
    public var unreadCount: Int { inbox.filter { !$0.isRead }.count }
}
