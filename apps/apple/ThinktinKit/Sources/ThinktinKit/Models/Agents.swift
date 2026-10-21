import Foundation

/// 目录里的一个 agent。
public struct AgentInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: AgentID
    public var name: String
    /// 当前版本。
    public var version: String
    /// SPDX 许可证或 `LicenseRef-…`。
    public var license: String?
    /// 能用的站点（`cn`、`global`）。
    public var sites: [String]
    /// 接入方式（`acp`、`cli`）。
    public var harnesses: [String]
    public var defaultHarness: String
    /// 可以用的版本，当前版本在前。
    public var versions: [String]

    public init(
        id: AgentID, name: String, version: String, license: String? = nil, sites: [String] = [],
        harnesses: [String] = [], defaultHarness: String, versions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.license = license
        self.sites = sites
        self.harnesses = harnesses
        self.defaultHarness = defaultHarness
        self.versions = versions
    }

    /// 实例的版本不是最新的：可以提示升级。
    public func hasUpgrade(from instanceVersion: String) -> Bool {
        (versions.first ?? version) != instanceVersion
    }
}

/// 领养的 agent 实例（一个沙箱）。
public struct Instance: Identifiable, Hashable, Codable, Sendable {
    public var id: InstanceID
    public var agentID: AgentID
    public var agentVersion: String
    public var harness: String
    public var name: String
    public var state: InstanceState
    public var createdAt: Date
    public var lastActiveAt: Date

    public init(
        id: InstanceID, agentID: AgentID, agentVersion: String, harness: String, name: String,
        state: InstanceState, createdAt: Date, lastActiveAt: Date
    ) {
        self.id = id
        self.agentID = agentID
        self.agentVersion = agentVersion
        self.harness = harness
        self.name = name
        self.state = state
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

/// 模型别名：agent 用别名调模型，平台按它找到用户的哪把 key、哪个上游模型。叫 `main` 的是默认模型。
public struct ModelRoute: Identifiable, Hashable, Codable, Sendable {
    public var alias: String
    public var credentialID: CredentialID
    public var upstreamModel: String
    /// 降级链：主 key 失效、欠费、被限流或连不上时按顺序换用，最多 3 个。
    public var fallbacks: [RouteFallback]

    public var id: String { alias }

    /// 默认模型的别名。
    public static let mainAlias = "main"

    /// 降级链最多几项。
    public static let maxFallbacks = 3

    public init(alias: String, credentialID: CredentialID, upstreamModel: String, fallbacks: [RouteFallback] = []) {
        self.alias = alias
        self.credentialID = credentialID
        self.upstreamModel = upstreamModel
        self.fallbacks = fallbacks
    }

    public var isMain: Bool { alias == Self.mainAlias }
}

/// 降级链里的一项：备用的 key 和它那边的上游模型。
public struct RouteFallback: Hashable, Codable, Sendable {
    public var credentialID: CredentialID
    public var upstreamModel: String

    public init(credentialID: CredentialID, upstreamModel: String) {
        self.credentialID = credentialID
        self.upstreamModel = upstreamModel
    }
}
