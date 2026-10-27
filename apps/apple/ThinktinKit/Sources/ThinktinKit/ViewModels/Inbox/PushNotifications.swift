import Foundation

/// 系统通知中心里已经送达的通知和 App 图标的角标（WBS 12.8）。ThinktinKit 只认 Foundation，实现在 App 里
/// （`UNUserNotificationCenter`），经 `AppModel(notifications:)` 交给应用框架。
public protocol DeliveredNotifications: Sendable {
    /// 清掉通知中心里已送达的（退出登录、换账号时：推送里没有用户 id，docs/push.md 第 3 节）。
    func removeAllDelivered() async
    /// 设 App 图标的角标（收件箱的未读数，docs/push.md 第 6 节）。
    func setBadge(_ count: Int) async
}

/// 通知类别（APNs 的 `aps.category`，docs/push.md 第 2 节）：App 启动时向系统登记，每一类有自己的按钮。
public enum PushCategory: String, CaseIterable, Sendable {
    case runFinished = "RUN_FINISHED"
    case runFailed = "RUN_FAILED"
    case approval = "APPROVAL"
    case computerApproval = "COMPUTER_APPROVAL"
    case vaultRequest = "VAULT_REQUEST"
    case planConfirm = "PLAN_CONFIRM"
    case info = "INFO"

    /// 通知上的按钮：云端审批只能直接“拒绝”（批准要打开 App、过本机验证）；电脑审批批准和拒绝都要签名，没有按钮。
    public var actions: [PushNotificationAction] {
        self == .approval ? [.reject] : []
    }

    /// 推送种类对应的类别（不认识的按 `INFO`）。
    public init(kind: PushPayload.Kind) {
        switch kind {
        case .runFinished: self = .runFinished
        case .runFailed: self = .runFailed
        case .approval: self = .approval
        case .computerApproval: self = .computerApproval
        case .vaultRequest: self = .vaultRequest
        case .planConfirm: self = .planConfirm
        case .info, .unknown: self = .info
        }
    }
}

/// 通知上的按钮（`UNNotificationAction` 的 identifier）。
public enum PushNotificationAction: String, CaseIterable, Sendable {
    /// 拒绝审批：不打开 App、不用本机验证（`AppModel.rejectFromNotification`）。
    case reject = "REJECT"

    public func title(_ language: DisplayLanguage) -> String {
        switch self {
        case .reject: language == .chinese ? "拒绝" : "Deny"
        }
    }

    /// 红色的按钮。
    public var isDestructive: Bool { self == .reject }
}
