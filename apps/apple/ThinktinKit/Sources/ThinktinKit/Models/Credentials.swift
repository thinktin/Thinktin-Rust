import Foundation

/// 用户的模型 key（只有后 4 位，key 本身服务端从不返回）。
public struct Credential: Identifiable, Hashable, Codable, Sendable {
    public var id: CredentialID
    /// 厂商 id（`VendorInfo.id`，自定义地址是 `custom`）。
    public var vendor: String
    public var label: String
    public var last4: String
    public var dailyTokenLimit: Int?
    public var isDisabled: Bool
    public var createdAt: Date
    /// 能用哪些模型协议（11.8）：预置厂商按厂商算，自定义地址按配了哪几个地址算（服务端从不返回地址本身）。
    /// 老的服务端为空。
    public var protocols: [ModelProtocol]

    public init(
        id: CredentialID, vendor: String, label: String, last4: String, dailyTokenLimit: Int? = nil,
        isDisabled: Bool = false, createdAt: Date, protocols: [ModelProtocol] = []
    ) {
        self.id = id
        self.vendor = vendor
        self.label = label
        self.last4 = last4
        self.dailyTokenLimit = dailyTokenLimit
        self.isDisabled = isDisabled
        self.createdAt = createdAt
        self.protocols = protocols
    }

    /// 打码显示：`••••abcd`。
    public var maskedKey: String { "••••" + last4 }

    /// 支持这个协议（选 key 时按 agent 的 `activeProtocol` 过滤）。协议为 nil、或者 `protocols` 为空（老的服务端
    /// 没给）时算支持，不拦。
    public func supports(_ modelProtocol: ModelProtocol?) -> Bool {
        guard let modelProtocol, !protocols.isEmpty else { return true }
        return protocols.contains(modelProtocol)
    }

    /// 备注最长几个字符（可以为空）。
    public static let maxLabelLength = 64
}

/// 添加模型 key。描述里不打印 key。
public struct NewCredential: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var vendor: String
    public var label: String
    public var apiKey: String
    public var anthropicBase: String?
    public var openaiBase: String?
    public var responsesBase: String?
    public var dailyTokenLimit: Int?

    /// 自定义接口地址时的厂商 id。
    public static let customVendor = "custom"

    public init(
        vendor: String, label: String, apiKey: String, anthropicBase: String? = nil, openaiBase: String? = nil,
        responsesBase: String? = nil, dailyTokenLimit: Int? = nil
    ) {
        self.vendor = vendor
        self.label = label
        self.apiKey = apiKey
        self.anthropicBase = anthropicBase
        self.openaiBase = openaiBase
        self.responsesBase = responsesBase
        self.dailyTokenLimit = dailyTokenLimit
    }

    public var description: String { "NewCredential(vendor: \(vendor), label: \(label))" }
    public var debugDescription: String { description }

    /// 加好以后这把 key 能用哪些协议（和服务端一样算，11.8）：预置厂商按 `vendors` 里它的协议，其余（自定义地址）
    /// 按配了哪几个地址：Anthropic 地址 → anthropic，OpenAI 地址 → chat，Responses 地址 → responses。
    /// 添加 key 的表单可以据此提示“这把 key 不能给 Codex 用”。
    public func expectedProtocols(vendors: [VendorInfo]) -> [ModelProtocol] {
        if let preset = vendors.first(where: { $0.id == vendor }) { return preset.modelProtocols }
        let configured: [(String?, ModelProtocol)] = [
            (anthropicBase, .anthropic), (openaiBase, .chat), (responsesBase, .responses),
        ]
        return configured.compactMap { base, proto in base == nil ? nil : proto }
    }
}

/// 预置的模型厂商（9.12）。
public struct VendorInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// `anthropic`、`chat`、`responses` 中的若干个：Claude 走 anthropic，Codex 只会 responses，其余走 chat。
    public var protocols: [String]
    /// 推荐的上游模型。
    public var models: [String]
    public var notes: String
    /// 订阅类 key 的前缀（11.9）：选这家时，粘贴的 key（去掉首尾空白）以其中一个开头（区分大小写）的服务端不收，
    /// 添加 key 时可以先在本地提示（服务端照样检查）。空的就不用查；老的服务端没给时也是空的。
    public var subscriptionKeyPrefixes: [String]
    /// 这家套餐专用地址的前缀（11.9，小写、不带结尾的 `/`）：自定义端点（`custom`）的地址去掉首尾空白、转小写后等于
    /// **任何一家**的其中一个、或者接着是 `/` 的，服务端不收。只是提前提示，服务端照样检查。
    public var planOnlyBases: [String]

    public init(
        id: String, name: String, protocols: [String], models: [String], notes: String = "",
        subscriptionKeyPrefixes: [String] = [], planOnlyBases: [String] = []
    ) {
        self.id = id
        self.name = name
        self.protocols = protocols
        self.models = models
        self.notes = notes
        self.subscriptionKeyPrefixes = subscriptionKeyPrefixes
        self.planOnlyBases = planOnlyBases
    }

    /// `protocols` 换成 `ModelProtocol`（和 `AgentInfo.activeProtocol`、`Credential.protocols` 比较用）。
    public var modelProtocols: [ModelProtocol] {
        protocols.map { ModelProtocol(rawValue: $0) }
    }

    /// 粘贴的 key 是这家的订阅类 key（11.9，服务端不收）：去掉首尾空白后以 `subscriptionKeyPrefixes` 里的一个开头
    /// （区分大小写）。返回命中的前缀；不是为 nil。只用来提前提示，服务端照样检查。
    public func subscriptionKeyPrefix(of apiKey: String) -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 按字节比（和服务端的 `starts_with` 一样）。
        return subscriptionKeyPrefixes.first { !$0.isEmpty && key.utf8.starts(with: $0.utf8) }
    }

    /// 自定义端点的地址是某一家的套餐专用地址（11.9，服务端不收）：去掉首尾空白、转小写（只转 ASCII，和服务端一样）后
    /// 等于 `vendors` 里任何一家的 `planOnlyBases` 的一个，或者接着是 `/`。返回命中的前缀；不是为 nil。
    public static func planOnlyBase(of url: String, vendors: [VendorInfo]) -> String? {
        // 按字节比（和服务端的 `strip_prefix` 一样），大写的 ASCII 字母换成小写。
        let base = url.trimmingCharacters(in: .whitespacesAndNewlines).utf8.map {
            (65...90).contains($0) ? $0 + 32 : $0
        }
        for prefix in vendors.lazy.flatMap(\.planOnlyBases) where !prefix.isEmpty {
            let head = Array(prefix.utf8)
            guard base.starts(with: head) else { continue }
            if base.count == head.count || base[head.count] == UInt8(ascii: "/") { return prefix }
        }
        return nil
    }
}

/// 用量的一组汇总：`key` 按分组是日期、实例 id、`厂商/模型` 或 key 的 id。
public struct UsageBucket: Identifiable, Hashable, Codable, Sendable {
    public var key: String
    public var requests: Int
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var outputTokens: Int
    /// 计费的 token 数。
    public var chargedTokens: Int
    /// 上游没给用量、按估算计的请求数。
    public var estimatedRequests: Int
    public var failedRequests: Int

    public var id: String { key }

    public init(
        key: String, requests: Int = 0, inputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0,
        outputTokens: Int = 0, chargedTokens: Int = 0, estimatedRequests: Int = 0, failedRequests: Int = 0
    ) {
        self.key = key
        self.requests = requests
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.chargedTokens = chargedTokens
        self.estimatedRequests = estimatedRequests
        self.failedRequests = failedRequests
    }

    /// 输入（含缓存读写）加输出。
    public var totalTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens }
}

/// 用量汇总。
public struct UsageSummary: Hashable, Codable, Sendable {
    public var buckets: [UsageBucket]
    public var total: UsageBucket

    public init(buckets: [UsageBucket], total: UsageBucket) {
        self.buckets = buckets
        self.total = total
    }
}
