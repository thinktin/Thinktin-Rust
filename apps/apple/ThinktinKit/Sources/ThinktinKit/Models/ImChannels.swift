import Foundation

/// IM 群机器人（10.5）。token 和签名密钥服务端从不返回，`hint` 是 token 后 4 位。
public struct ImChannel: Identifiable, Hashable, Codable, Sendable {
    public var id: ImChannelID
    public var vendor: ImVendor
    public var label: String
    public var hint: String
    public var hasSecret: Bool
    public var events: [ImEvent]
    public var isEnabled: Bool
    public var lastSentAt: Date?
    public var lastError: String?
    public var createdAt: Date

    public init(
        id: ImChannelID, vendor: ImVendor, label: String, hint: String, hasSecret: Bool = false,
        events: [ImEvent] = ImEvent.knownCases, isEnabled: Bool = true, lastSentAt: Date? = nil,
        lastError: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.vendor = vendor
        self.label = label
        self.hint = hint
        self.hasSecret = hasSecret
        self.events = events
        self.isEnabled = isEnabled
        self.lastSentAt = lastSentAt
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

/// 绑定 IM 群机器人。描述里不打印 webhook 地址和密钥。
public struct NewImChannel: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var webhookURL: String
    public var secret: String?
    public var label: String
    /// 不给就是全部事件。
    public var events: [ImEvent]?

    public init(webhookURL: String, secret: String? = nil, label: String, events: [ImEvent]? = nil) {
        self.webhookURL = webhookURL
        self.secret = secret
        self.label = label
        self.events = events
    }

    public var description: String { "NewImChannel(label: \(label))" }
    public var debugDescription: String { description }
}
