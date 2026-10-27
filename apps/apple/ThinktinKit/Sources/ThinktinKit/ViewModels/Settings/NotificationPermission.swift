import Foundation

/// 系统通知权限（WBS 12.12 设置中心的“通知”一栏）：对应 UserNotifications 的 `UNAuthorizationStatus`。
///
/// ThinktinKit 只认 Foundation，读系统设置的实现在界面层（ThinktinUI 的 `SystemNotificationPermission`），
/// 经 `NotificationPermissionReading` 交给视图模型；预览、测试用 `FixedNotificationPermission`。
public enum NotificationPermission: Hashable, Sendable {
    /// 还没问过用户（第一次登录后 12.8 会请求）。
    case notDetermined
    /// 用户关掉了（只能去系统设置里打开）。
    case denied
    /// 开着。
    case authorized
    /// 临时授权：通知静默进通知中心，不响铃、不弹横幅。
    case provisional
    /// 读不到（不在 App 里运行，或者系统新加了状态）。
    case unknown

    /// 通知能不能送到（开着或临时授权）。
    public var canDeliver: Bool {
        switch self {
        case .authorized, .provisional: true
        case .notDetermined, .denied, .unknown: false
        }
    }

    /// 设置中心那一行右边的值。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .notDetermined: return zh ? "未开启" : "Not set up"
        case .denied: return zh ? "已关闭" : "Off"
        case .authorized: return zh ? "已开启" : "On"
        case .provisional: return zh ? "静默送达" : "Delivered quietly"
        case .unknown: return zh ? "去系统设置查看" : "Check in Settings"
        }
    }

    /// 那一行下面的一句说明：关着时说清楚会错过什么、怎么打开。
    public func detail(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .authorized:
            return zh ? "任务完成、失败、等你审批时会通知你。" : "You'll be notified when tasks finish, fail or need your approval."
        case .provisional:
            return zh
                ? "通知只进通知中心，不响铃也不弹出。要及时看到审批，去系统设置里改成允许。"
                : "Notifications go straight to Notification Center without sound or banners. Allow them in "
                    + "Settings so you don't miss approvals."
        case .denied:
            return zh
                ? "通知关着，任务完成和等你审批时不会提醒。去系统设置里打开。"
                : "Notifications are off, so you won't hear about finished tasks or approvals. Turn them on in Settings."
        case .notDetermined:
            return zh
                ? "还没允许 ThinkTin 发通知。去系统设置里打开，任务完成、等你审批时提醒你。"
                : "ThinkTin can't send notifications yet. Turn them on in Settings to hear about finished tasks and "
                    + "approvals."
        case .unknown:
            return zh ? "在系统设置里查看和修改 ThinkTin 的通知。" : "View and change ThinkTin's notifications in Settings."
        }
    }
}

/// 读系统的通知权限（实现在界面层：`SystemNotificationPermission`）。
public protocol NotificationPermissionReading: Sendable {
    func currentPermission() async -> NotificationPermission
}

/// 固定返回一个值（预览、测试）。
public struct FixedNotificationPermission: NotificationPermissionReading {
    public var permission: NotificationPermission

    public init(_ permission: NotificationPermission) {
        self.permission = permission
    }

    public func currentPermission() async -> NotificationPermission { permission }
}
