import Foundation

/// 强类型的 id：底层是服务端给的字符串（UUID），`Tag` 只用来区分种类，防止把运行 id 传给要实例 id 的地方。
///
/// 编码成单个字符串（和接口、缓存里的一致）。
public struct EntityID<Tag>: RawRepresentable, Hashable, Codable, Sendable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// 新的随机 id（Mock、预览用；真实的 id 都由服务端生成）。
    public static func random() -> Self {
        Self(UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// `EntityID` 的种类标记（只作类型参数，没有值）。
public enum IDTag {
    public enum User {}
    public enum Device {}
    public enum Agent {}
    public enum Instance {}
    public enum Run {}
    public enum Plan {}
    public enum Trigger {}
    public enum Approval {}
    public enum InboxItem {}
    public enum Credential {}
    public enum Artifact {}
    public enum VaultItem {}
    public enum VaultRequest {}
    public enum ImChannel {}
    public enum Team {}
    public enum TeamTemplate {}
    public enum DeviceMessage {}
}

public typealias UserID = EntityID<IDTag.User>
public typealias DeviceID = EntityID<IDTag.Device>
/// agent 在目录里的 id（`claude`、`codex`），不是 UUID。
public typealias AgentID = EntityID<IDTag.Agent>
public typealias InstanceID = EntityID<IDTag.Instance>
public typealias RunID = EntityID<IDTag.Run>
public typealias PlanID = EntityID<IDTag.Plan>
public typealias TriggerID = EntityID<IDTag.Trigger>
public typealias ApprovalID = EntityID<IDTag.Approval>
public typealias InboxItemID = EntityID<IDTag.InboxItem>
public typealias CredentialID = EntityID<IDTag.Credential>
public typealias ArtifactID = EntityID<IDTag.Artifact>
public typealias VaultItemID = EntityID<IDTag.VaultItem>
public typealias VaultRequestID = EntityID<IDTag.VaultRequest>
public typealias ImChannelID = EntityID<IDTag.ImChannel>
public typealias TeamID = EntityID<IDTag.Team>
public typealias TeamTemplateID = EntityID<IDTag.TeamTemplate>
/// 手机和电脑之间转发的一条消息（`DeviceMessage`）。
public typealias DeviceMessageID = EntityID<IDTag.DeviceMessage>
