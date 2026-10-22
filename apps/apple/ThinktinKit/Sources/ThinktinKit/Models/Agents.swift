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
    /// 一句话介绍（11.8），按请求的 `Accept-Language` 给中文或英文；老的服务端为空。是清单里人写的，不是 agent 生成的。
    public var description: String
    /// 上游仓库（https 地址，11.8）；老的服务端为空。可以点开的地址见 `upstreamURL`。
    public var upstream: String
    /// 许可说明（11.8，专有许可证必有），按 `Accept-Language` 给。领养前要给用户看。
    public var licenseNote: String?
    /// 能说的模型协议，按优先级（11.8）；老的服务端为空。
    public var protocols: [ModelProtocol]
    /// 运行时实际用的协议（11.8）：实例配的每把 key（包括降级的）都要支持它，选 key 时按它过滤（`canUse(_:)`）。
    /// 老的服务端为 nil。
    public var activeProtocol: ModelProtocol?

    public init(
        id: AgentID, name: String, version: String, license: String? = nil, sites: [String] = [],
        harnesses: [String] = [], defaultHarness: String, versions: [String] = [], description: String = "",
        upstream: String = "", licenseNote: String? = nil, protocols: [ModelProtocol] = [],
        activeProtocol: ModelProtocol? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.license = license
        self.sites = sites
        self.harnesses = harnesses
        self.defaultHarness = defaultHarness
        self.versions = versions
        self.description = description
        self.upstream = upstream
        self.licenseNote = licenseNote
        self.protocols = protocols
        self.activeProtocol = activeProtocol
    }

    /// 实例的版本不是最新的：可以提示升级。
    public func hasUpgrade(from instanceVersion: String) -> Bool {
        (versions.first ?? version) != instanceVersion
    }

    /// 上游仓库的地址：只认带主机名的 https 地址，别的（空的、http、写错的）为 nil，界面就不给链接。
    public var upstreamURL: URL? {
        guard let url = URL(string: upstream), url.scheme?.lowercased() == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// 这把 key 能不能配给这个 agent 的实例：key 要支持 agent 的 `activeProtocol`（模型网关不在协议之间转换，
    /// 配错了运行会卡在等 key）。两边有一边没给协议（老的服务端）时不拦。
    public func canUse(_ credential: Credential) -> Bool {
        credential.supports(activeProtocol)
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
