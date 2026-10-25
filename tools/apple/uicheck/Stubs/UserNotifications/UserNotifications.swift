// UserNotifications 的桩（WBS 12.8 推送：通知类别、前台送达、点开 / 按钮、角标；12.12 读通知权限）：签名照 Apple 文档
// （iOS 17 SDK），只放用到的。真实 SDK 里这些类都是 NSObject 的子类；代理协议不在主线程上（方法要 nonisolated）。
@_exported import Foundation

public struct UNAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let badge = UNAuthorizationOptions(rawValue: 1 << 0)
    public static let sound = UNAuthorizationOptions(rawValue: 1 << 1)
    public static let alert = UNAuthorizationOptions(rawValue: 1 << 2)
    public static let provisional = UNAuthorizationOptions(rawValue: 1 << 6)
}

public enum UNAuthorizationStatus: Int, Sendable {
    case notDetermined = 0, denied, authorized, provisional, ephemeral
}

open class UNNotificationSettings: NSObject, @unchecked Sendable {
    open var authorizationStatus: UNAuthorizationStatus { .notDetermined }
}

public struct UNNotificationPresentationOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let badge = UNNotificationPresentationOptions(rawValue: 1 << 0)
    public static let sound = UNNotificationPresentationOptions(rawValue: 1 << 1)
    public static let list = UNNotificationPresentationOptions(rawValue: 1 << 3)
    public static let banner = UNNotificationPresentationOptions(rawValue: 1 << 4)
}

public struct UNNotificationActionOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let authenticationRequired = UNNotificationActionOptions(rawValue: 1 << 0)
    public static let destructive = UNNotificationActionOptions(rawValue: 1 << 1)
    public static let foreground = UNNotificationActionOptions(rawValue: 1 << 2)
}

public struct UNNotificationCategoryOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let customDismissAction = UNNotificationCategoryOptions(rawValue: 1 << 0)
}

open class UNNotificationAction: NSObject, @unchecked Sendable {
    open var identifier: String
    open var title: String
    open var options: UNNotificationActionOptions
    public init(identifier: String, title: String, options: UNNotificationActionOptions = []) {
        self.identifier = identifier
        self.title = title
        self.options = options
    }
}

open class UNNotificationCategory: NSObject, @unchecked Sendable {
    open var identifier: String
    open var actions: [UNNotificationAction]
    public init(
        identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String],
        options: UNNotificationCategoryOptions = []
    ) {
        self.identifier = identifier
        self.actions = actions
    }
}

open class UNNotificationContent: NSObject, @unchecked Sendable {
    open var userInfo: [AnyHashable: Any] { [:] }
    open var categoryIdentifier: String { "" }
}

open class UNNotificationRequest: NSObject, @unchecked Sendable {
    open var identifier: String { "" }
    open var content: UNNotificationContent { UNNotificationContent() }
}

open class UNNotification: NSObject, @unchecked Sendable {
    open var date: Date { Date() }
    open var request: UNNotificationRequest { UNNotificationRequest() }
}

open class UNNotificationResponse: NSObject, @unchecked Sendable {
    open var notification: UNNotification { UNNotification() }
    open var actionIdentifier: String { UNNotificationDefaultActionIdentifier }
}

public let UNNotificationDefaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
public let UNNotificationDismissActionIdentifier = "com.apple.UNNotificationDismissActionIdentifier"

public protocol UNUserNotificationCenterDelegate: AnyObject {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async
}

extension UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [] }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse)
        async
    {}
}

open class UNUserNotificationCenter: NSObject, @unchecked Sendable {
    open class func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    weak open var delegate: (any UNUserNotificationCenterDelegate)?
    open func requestAuthorization(options: UNAuthorizationOptions = []) async throws -> Bool { false }
    open func notificationSettings() async -> UNNotificationSettings { UNNotificationSettings() }
    open func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
    open func removeAllDeliveredNotifications() {}
    open func setBadgeCount(_ newBadgeCount: Int) async throws {}
}
