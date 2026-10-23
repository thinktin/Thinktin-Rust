import Foundation

/// 团队里的一个实例（8.1）。
public struct TeamMember: Identifiable, Hashable, Codable, Sendable {
    public var instanceID: InstanceID
    /// 负责人（一个团队最多一个）或普通成员。
    public var role: TeamRole
    /// 显示顺序，从 0 开始。
    public var position: Int

    public var id: InstanceID { instanceID }

    public init(instanceID: InstanceID, role: TeamRole = .member, position: Int = 0) {
        self.instanceID = instanceID
        self.role = role
        self.position = position
    }

    public var isLead: Bool { role == .lead }
}

/// 团队（8.1）：同一用户的几个实例，委派时由负责人分工。
public struct Team: Identifiable, Hashable, Codable, Sendable {
    public var id: TeamID
    public var name: String
    /// 服务端按 `position` 排好。实例删掉后自动移出。
    public var members: [TeamMember]
    public var createdAt: Date

    public init(id: TeamID, name: String, members: [TeamMember], createdAt: Date) {
        self.id = id
        self.name = name
        self.members = members
        self.createdAt = createdAt
    }

    /// 一个团队（和团队模板）最多几个成员。至少要有一个。
    public static let maxMembers = 12

    /// 团队名、成员名最长几个字符。
    public static let maxNameLength = 64

    /// 负责人（没指定时为 nil）。
    public var lead: TeamMember? { members.first(where: \.isLead) }

    public func contains(_ instanceID: InstanceID) -> Bool {
        members.contains { $0.instanceID == instanceID }
    }

    /// 按给定的顺序编成员：第一个是负责人（`leadFirst` 时），`position` 从 0 起。
    public static func members(_ instanceIDs: [InstanceID], leadFirst: Bool = true) -> [TeamMember] {
        instanceIDs.enumerated().map { i, id in
            TeamMember(instanceID: id, role: leadFirst && i == 0 ? .lead : .member, position: i)
        }
    }
}

/// 团队模板里的一个成员：领养时用这个 agent 新领养一个实例。
public struct TemplateMember: Hashable, Codable, Sendable {
    public var agentID: AgentID
    /// 接入方式（同一个 agent 的几种，比如 claude 的 acp、cli）；nil 用 agent 默认的。
    public var harness: String?
    /// 领养出来的实例叫什么。
    public var name: String
    public var role: TeamRole

    public init(agentID: AgentID, harness: String? = nil, name: String, role: TeamRole = .member) {
        self.agentID = agentID
        self.harness = harness
        self.name = name
        self.role = role
    }

    public var isLead: Bool { role == .lead }
}

/// 团队模板：一键领养一整个团队（`adoptTeamTemplate`）。
public struct TeamTemplate: Identifiable, Hashable, Codable, Sendable {
    public var id: TeamTemplateID
    public var name: String
    public var members: [TemplateMember]
    public var createdAt: Date

    public init(id: TeamTemplateID, name: String, members: [TemplateMember], createdAt: Date) {
        self.id = id
        self.name = name
        self.members = members
        self.createdAt = createdAt
    }

    public var lead: TemplateMember? { members.first(where: \.isLead) }
}
