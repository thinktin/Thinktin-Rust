import OSLog
import ThinktinKit
import UIKit
import UserNotifications

/// App 代理（WBS 12.8）：推送的系统回调都在这里，转给 `AppModel`。
///
/// - 启动时（冷启动点开通知也是先走这里）设好通知中心的代理、登记通知类别、向 APNs 注册；设备令牌交给
///   `AppModel.didReceivePushToken`。
/// - App 在前台时送达的推送：照样显示横幅，`AppModel.receive(push:)` 处理账号冻结 / 解冻，刷新角标。
/// - 点开通知（冷启动、后台）：`AppModel.open(push:)` 跳过去、标已读；点通知上的“拒绝”：`rejectFromNotification`，
///   不打开 App。
///
/// `AppEnvironment` 由它建（SwiftUI 的 `App` 从 `delegate.environment` 拿），这样冷启动时通知回调来得比界面早也有地方交。
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var environment = AppEnvironment.live()

    private static let log = Logger(subsystem: "cn.thinktin.app", category: "push")

    @MainActor
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 不在 App 包里（命令行跑的测试）时用不了通知中心（`UNUserNotificationCenter.current()` 会直接崩）。
        guard Bundle.main.bundleURL.pathExtension == "app" else { return true }
        UNUserNotificationCenter.current().delegate = self
        NotificationCategories.register(language: SettingsPreferences.shared.displayLanguage)
        application.registerForRemoteNotifications()
        return true
    }

    @MainActor
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let registration = PushRegistration.forThisBuild(deviceToken: deviceToken)
        let model = environment.appModel
        Task { await model.didReceivePushToken(registration) }
    }

    @MainActor
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // 模拟器、描述文件没有推送权限时会走到这里；收件箱照样能用。
        Self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// App 在前台时送达：处理账号状态、刷新角标，照样显示横幅（推送可能是别的实例的）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let push = PushPayload(userInfo: notification.request.content.userInfo) {
            await received(push)
        }
        return [.banner, .list, .sound]
    }

    /// 点开通知、点了通知上的按钮。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    )
        async
    {
        guard let push = PushPayload(userInfo: response.notification.request.content.userInfo) else { return }
        await responded(push, action: response.actionIdentifier)
    }

    @MainActor
    private func received(_ push: PushPayload) async {
        let model = environment.appModel
        await model.receive(push: push)
        await model.refreshBadges()
    }

    @MainActor
    private func responded(_ push: PushPayload, action: String) async {
        let model = environment.appModel
        switch action {
        case PushNotificationAction.reject.rawValue:
            await model.rejectFromNotification(push)
        case UNNotificationDismissActionIdentifier:
            break
        default:
            await model.open(push: push)
        }
    }
}
