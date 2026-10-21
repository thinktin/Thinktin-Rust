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

    public init(
        id: CredentialID, vendor: String, label: String, last4: String, dailyTokenLimit: Int? = nil,
        isDisabled: Bool = false, createdAt: Date
    ) {
        self.id = id
        self.vendor = vendor
        self.label = label
        self.last4 = last4
        self.dailyTokenLimit = dailyTokenLimit
        self.isDisabled = isDisabled
        self.createdAt = createdAt
    }

    /// 打码显示：`••••abcd`。
    public var maskedKey: String { "••••" + last4 }
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

    public init(id: String, name: String, protocols: [String], models: [String], notes: String = "") {
        self.id = id
        self.name = name
        self.protocols = protocols
        self.models = models
        self.notes = notes
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
