import Foundation

/// 登录着的一台设备（设置里的“登录设备”）。
public struct DeviceInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: DeviceID
    public var platform: DevicePlatform
    /// 设备名（“张三的 iPhone”），登录时由 App 报上来。
    public var name: String
    /// 登记了推送的通道；没登记时为 nil。
    public var pushChannel: PushChannel?
    /// 是正在用的这台。
    public var isCurrent: Bool
    /// 电脑连着设备中继（14.1）；手机总是 false。
    public var isOnline: Bool
    public var createdAt: Date
    public var lastSeenAt: Date

    public init(
        id: DeviceID, platform: DevicePlatform, name: String, pushChannel: PushChannel? = nil,
        isCurrent: Bool = false, isOnline: Bool = false, createdAt: Date, lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.pushChannel = pushChannel
        self.isCurrent = isCurrent
        self.isOnline = isOnline
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt ?? createdAt
    }

    /// 是电脑（macOS）：可以和手机配对，在线时 agent 能借它在本机执行。
    public var isComputer: Bool { platform == .macos }

    /// 能登记实时活动（10.6）：只有 iPhone、iPad。
    public var supportsLiveActivities: Bool { platform == .ios }
}

/// 手机和电脑之间的一条消息（14.1）：配对应答和确认、审批请求和决定、能力令牌、吊销。
/// 内容和签名的格式见 docs/pairing.md；收件方不在线时排队，过期没送到的丢掉。
public struct DeviceMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: DeviceMessageID
    public var fromDeviceID: DeviceID
    public var toDeviceID: DeviceID
    public var kind: DeviceMessageKind
    /// 消息内容（JSON 文本）。
    public var bodyJSON: String
    public var createdAt: Date
    /// 过了这个时间还没送到就丢掉（服务端是发出后 24 小时）。
    public var expiresAt: Date

    public init(
        id: DeviceMessageID, fromDeviceID: DeviceID, toDeviceID: DeviceID, kind: DeviceMessageKind,
        bodyJSON: String = "{}", createdAt: Date, expiresAt: Date? = nil
    ) {
        self.id = id
        self.fromDeviceID = fromDeviceID
        self.toDeviceID = toDeviceID
        self.kind = kind
        self.bodyJSON = bodyJSON
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.timeToLive)
    }

    /// 服务端给消息的有效期（24 小时）。
    public static let timeToLive: TimeInterval = 24 * 3600

    /// 内容最多多少字节（UTF-8，服务端的 `MAX_MESSAGE_BODY_BYTES`）。
    public static let maxBodyBytes = 64 * 1024

    /// 一次最多确认几条（`ackDeviceMessages`）。
    public static let maxAckCount = 200

    /// 解析好的内容（不是合法 JSON 时为 nil）。
    public var body: JSONValue? { JSONValue.parse(bodyJSON) }

    public func isExpired(now: Date = Date()) -> Bool { expiresAt <= now }
}

/// 实时活动（10.6）的推送令牌：ActivityKit 给的 `Data` 按字节转成的十六进制串（`pushTokenUpdates`、
/// `pushToStartTokenUpdates` 都是），32 到 512 个字符。`registerLiveActivity`、`setLiveActivityStartToken` 收的就是它。
public enum LiveActivityToken {
    /// 服务端接受的长度（字符数）。
    public static let allowedLength = 32...512

    /// `Data` 转成十六进制（小写）。
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// 格式对不对（长度、只有十六进制字符）。不对的服务端返回 invalid。
    public static func isValid(_ token: String) -> Bool {
        // 只认 ASCII 的 0-9、a-f、A-F（`Character.isHexDigit` 还包括全角的）。
        allowedLength.contains(token.utf8.count) && token.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

/// 实时活动（10.6）的服务端上限（docs/live-activities.md 第 2 节）。
public enum LiveActivityLimits {
    /// 一台设备同时最多登记几个（再多 `registerLiveActivity` 抛 invalid）。
    public static let maxOpenPerDevice = 10
    /// 运行结束超过这么久（秒）再登记抛 invalid：App 在本地结束这个实时活动，不用再调。
    public static let lateRegistration: TimeInterval = 10 * 60
    /// 实时活动最多显示多久（苹果的上限，从登记令牌时算），过了后台不再推送。
    public static let maxAge: TimeInterval = 8 * 3600

    /// 这个运行结束得太久了，登记会被拒（App 直接在本地结束实时活动）。
    public static func isTooLateToRegister(_ run: Run, now: Date = Date()) -> Bool {
        guard let finished = run.finishedAt else { return false }
        return now.timeIntervalSince(finished) > lateRegistration
    }
}
