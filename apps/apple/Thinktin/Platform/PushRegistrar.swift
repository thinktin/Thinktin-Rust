import Foundation
import ThinktinKit
import UIKit
import UserNotifications

/// 通知权限和 APNs 注册（WBS 12.8，docs/push.md 第 1 节）。
///
/// 流程：App 每次启动都向 APNs 注册（`AppDelegate`，不用等用户允许通知：令牌先拿到，允许之后推送就能显示）→ App 代理
/// 收到设备令牌 → `PushRegistration.forThisBuild(deviceToken:)` 转成十六进制、按构建选好通道（`apns` / `apns_sandbox`）→
/// `AppModel.didReceivePushToken`：登录着就 `setPushToken`，没登录时登录带上。请求通知权限（`register()`）在用到时
/// 才做（12.17 的引导、发第一个任务之后）。
protocol PushRegistrar: Sendable {
    /// 请求通知权限（还没问过时弹系统框）并向 APNs 注册。返回用户是否允许通知。
    func register() async -> Bool
}

/// 空实现：不请求权限、不注册（预览、测试）。
struct NoopPushRegistrar: PushRegistrar {
    func register() async -> Bool { false }
}

/// 系统的实现：`UNUserNotificationCenter` 请求权限，`UIApplication` 向 APNs 注册。
struct SystemPushRegistrar: PushRegistrar {
    func register() async -> Bool {
        let granted =
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]))
            ?? false
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }
}

extension PushRegistration {
    /// 这个构建报的推送令牌（docs/push.md 第 1 节）：Debug 构建用开发证书签名（project.yml 里 `aps-environment` 是
    /// development），APNs 给的是沙盒环境的令牌，报 `apns_sandbox`；Release（TestFlight、App Store）报 `apns`。
    /// 报错了环境，令牌会被 APNs 判成 `BadDeviceToken`、服务端清掉。
    static func forThisBuild(deviceToken: Data) -> PushRegistration {
        .apns(deviceToken: deviceToken, sandbox: AppConfiguration.usesAPNsSandbox)
    }
}

/// 系统通知中心（`AppModel(notifications:)`）：退出登录时清掉已送达的通知，App 图标的角标跟着收件箱的未读数。
struct SystemDeliveredNotifications: DeliveredNotifications {
    func removeAllDelivered() async {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// 通知类别（docs/push.md 第 2 节，`PushCategory`）：启动时登记，按钮的文字跟着界面语言（换了语言下次启动生效）。
enum NotificationCategories {
    static func register(language: DisplayLanguage) {
        let categories = PushCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: category.actions.map { action in
                    UNNotificationAction(
                        identifier: action.rawValue, title: action.title(language),
                        options: action.isDestructive ? [.destructive] : [])
                },
                intentIdentifiers: [], options: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }
}
