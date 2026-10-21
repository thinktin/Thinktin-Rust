import Foundation

/// 当前用户。
public struct User: Identifiable, Hashable, Codable, Sendable {
    public var id: UserID
    /// E.164（`+8613800138000`）。
    public var phone: String
    public var displayName: String?
    public var status: UserStatus
    /// 推送、收件箱用的语言（1.6）。
    public var locale: UserLocale
    public var createdAt: Date

    public init(
        id: UserID, phone: String, displayName: String? = nil, status: UserStatus = .active,
        locale: UserLocale = .zhCN, createdAt: Date
    ) {
        self.id = id
        self.phone = phone
        self.displayName = displayName
        self.status = status
        self.locale = locale
        self.createdAt = createdAt
    }

    /// 界面上显示的名字：没有昵称时用打码的手机号。
    public var nameForDisplay: String {
        if let name = displayName, !name.isEmpty { return name }
        return Self.maskedPhone(phone)
    }

    /// `+8613800138000` → `138****8000`。
    public static func maskedPhone(_ phone: String) -> String {
        var digits = phone
        if digits.hasPrefix("+86") { digits.removeFirst(3) }
        guard digits.count >= 7 else { return phone }
        return String(digits.prefix(3)) + "****" + String(digits.suffix(4))
    }
}

/// 登录结果。
public struct LoginResult: Hashable, Codable, Sendable {
    public var user: User
    /// 第一次登录（刚注册）：可以进引导页。
    public var isNewUser: Bool

    public init(user: User, isNewUser: Bool) {
        self.user = user
        self.isNewUser = isNewUser
    }
}

/// 登录后的会话。刷新令牌等同于密码，只能放进 Keychain；描述里不打印令牌。
public struct Session: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var userID: UserID
    public var deviceID: DeviceID
    public var accessToken: String
    public var refreshToken: String

    public init(userID: UserID, deviceID: DeviceID, accessToken: String, refreshToken: String) {
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public var description: String { "Session(user: \(userID), device: \(deviceID))" }
    public var debugDescription: String { description }
}

/// 推送注册：通道和令牌总是一起给。
public struct PushRegistration: Hashable, Codable, Sendable {
    public var channel: PushChannel
    public var token: String

    public init(channel: PushChannel, token: String) {
        self.channel = channel
        self.token = token
    }

    /// APNs 的设备令牌（`Data` 转十六进制）。
    public static func apns(deviceToken: Data) -> PushRegistration {
        PushRegistration(channel: .apns, token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }
}

/// 全部停止的结果（4.6）。
public struct StopAllResult: Hashable, Codable, Sendable {
    public var runsCancelled: Int
    public var grantsRevoked: Int
    public var plansPaused: Int

    public init(runsCancelled: Int, grantsRevoked: Int, plansPaused: Int) {
        self.runsCancelled = runsCancelled
        self.grantsRevoked = grantsRevoked
        self.plansPaused = plansPaused
    }
}

/// 下线其他设备的结果（4.6）。
public struct SignOutOthersResult: Hashable, Codable, Sendable {
    public var devicesSignedOut: Int
    /// 顺带全部停止时有。
    public var stopped: StopAllResult?

    public init(devicesSignedOut: Int, stopped: StopAllResult? = nil) {
        self.devicesSignedOut = devicesSignedOut
        self.stopped = stopped
    }
}
