// WBS 12.8（APNs 注册、App 代理）用到的 UIKit 类型的桩：签名照 Apple 文档（iOS 17 SDK）。UIApplication 的主声明在
// UIKit+Settings.swift。SDK 里 UIApplicationDelegate 继承 NSObjectProtocol、整个协议在主线程上；方法都是可选的。

extension UIApplication {
    public static let shared = UIApplication()

    public struct LaunchOptionsKey: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public func registerForRemoteNotifications() {}
}

@MainActor
public protocol UIApplicationDelegate: AnyObject {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error)
}

extension UIApplicationDelegate {
    public func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool { true }
    public func application(
        _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {}
    public func application(
        _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {}
}
