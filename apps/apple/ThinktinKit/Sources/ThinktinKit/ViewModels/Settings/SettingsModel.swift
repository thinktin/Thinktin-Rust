import Foundation
import Observation

/// 设置中心（WBS 12.12，`.settings`，入口是抽屉底部的头像）：一组组入口，版式参考 Claude iOS App 的设置页。
///
/// 分组（ios-packages.md 12.12；和安卓设置页 4.9 的内容一致）：
/// - 账号：昵称、打码的手机号、登录设备、退出登录、注销（页面都是 12.2 的，这里只放入口）；
/// - 模型 key 与用量（12.4）、保险箱（12.13）；
/// - 通知：系统通知权限（点了去系统设置）、IM 渠道（12.14）；
/// - 外观与语言：本功能的两个子页面；
/// - 安全：全部停止、下线其他设备（12.2）；
/// - 关于：关于页、开源许可。
///
/// 设置中心不联网也能用（`OfflinePolicy.local`）：用户先用应用框架已经拿到的（`AppModel.user`），再静默 `me()` 一次。
/// 这些入口和说明都不是 agent 写的，按 AI 生成标识的规则表（ios-packages.md 12.5）都不用标。
@Observable @MainActor
public final class SettingsModel {
    public private(set) var user: User?
    /// 系统通知权限；读到之前为 nil。
    public private(set) var notificationPermission: NotificationPermission?
    public let preferences: SettingsPreferences
    public let appInfo: AppInfo

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let notifications: any NotificationPermissionReading
    @ObservationIgnored private var isLoadingUser = false

    /// - Parameters:
    ///   - user: 已经知道的用户（`AppModel.user`）。
    ///   - notifications: 读系统通知权限的（界面层给 `SystemNotificationPermission`）。
    public init(
        client: any ClientProtocol, user: User?, preferences: SettingsPreferences,
        notifications: any NotificationPermissionReading, appInfo: AppInfo = .current
    ) {
        self.client = client
        self.user = user
        self.preferences = preferences
        self.notifications = notifications
        self.appInfo = appInfo
    }

    /// 页面出现、回到前台（从系统设置回来）时调：读通知权限，静默刷新用户。
    public func refresh() async {
        await refreshNotificationPermission()
        await refreshUser()
    }

    public func refreshNotificationPermission() async {
        notificationPermission = await notifications.currentPermission()
    }

    /// 静默拉最新的用户（昵称在账号页改过）：失败了就用原来的（设置中心不联网也能用）。
    public func refreshUser() async {
        guard !isLoadingUser else { return }
        isLoadingUser = true
        defer { isLoadingUser = false }
        if let me = try? await client.me() { user = me }
    }

    /// 改了昵称之类（`AppModel.user` 变了）时换上。
    public func apply(_ user: User?) {
        guard let user else { return }
        self.user = user
    }

    /// 打码的手机号（`138****8000`）；没有时为空。
    public var maskedPhone: String {
        guard let phone = user?.phone, !phone.isEmpty else { return "" }
        return User.maskedPhone(phone)
    }

    /// 页面上的各组。
    public func sections(_ language: DisplayLanguage = .current) -> [SettingsSection] {
        let zh = language == .chinese
        let name = user?.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return [
            SettingsSection(
                id: .account, title: zh ? "账号" : "Account",
                footer: zh ? "退出登录只影响这台设备，agent 照常运行。" : "Signing out only affects this device; agents keep running.",
                rows: [
                    SettingsRow(
                        id: "name", systemImage: "person", title: zh ? "昵称" : "Name",
                        value: name ?? (zh ? "未设置" : "Not set"), action: .open(.account)),
                    SettingsRow(
                        id: "phone", systemImage: "phone", title: zh ? "手机号" : "Phone number",
                        value: maskedPhone.isEmpty ? nil : maskedPhone, action: nil),
                    SettingsRow(
                        id: "devices", systemImage: "laptopcomputer.and.iphone",
                        title: AppRoute.devices.title(language),
                        action: .open(.devices)),
                    SettingsRow(
                        id: "signOut", systemImage: "rectangle.portrait.and.arrow.right",
                        title: zh ? "退出登录" : "Sign out", action: .signOut),
                    SettingsRow(
                        id: "deleteAccount", systemImage: "person.crop.circle.badge.xmark",
                        title: zh ? "注销账号" : "Delete account", action: .deleteAccount, isDestructive: true,
                        needsNetwork: true),
                ]),
            SettingsSection(
                id: .models, title: zh ? "模型 key 与用量" : "Model keys & usage",
                footer: zh
                    ? "agent 用你自己的模型 key 调模型，费用由厂商直接收。"
                    : "Agents call models with your own keys; providers bill you directly.",
                rows: [
                    SettingsRow(
                        id: "credentials", systemImage: "key", title: AppRoute.credentials.title(language),
                        action: .open(.credentials)),
                    SettingsRow(
                        id: "usage", systemImage: "chart.bar", title: AppRoute.usage.title(language),
                        action: .open(.usage)),
                ]),
            SettingsSection(
                id: .vault, title: zh ? "保险箱" : "Vault",
                footer: zh
                    ? "agent 要登录网站时用这里的账号密码，密码不会发给模型。"
                    : "Agents use these accounts to sign in to websites; passwords are never sent to the model.",
                rows: [
                    SettingsRow(
                        id: "vault", systemImage: "lock.rectangle.stack", title: AppRoute.vault.title(language),
                        action: .open(.vault))
                ]),
            SettingsSection(
                id: .notifications, title: zh ? "通知" : "Notifications",
                footer: notificationPermission.map { $0.detail(language) },
                rows: [
                    SettingsRow(
                        id: "systemNotifications", systemImage: "bell", title: zh ? "系统通知" : "Notifications",
                        value: notificationPermission?.title(language), action: .systemNotificationSettings),
                    SettingsRow(
                        id: "imChannels", systemImage: "bubble.left.and.bubble.right",
                        title: AppRoute.imChannels.title(language),
                        subtitle: zh
                            ? "把任务结果发到飞书、企业微信、钉钉的群" : "Post task results to Feishu/Lark, WeCom or DingTalk groups",
                        action: .open(.imChannels)),
                ]),
            SettingsSection(
                id: .display, title: zh ? "外观与语言" : "Appearance & language", footer: nil,
                rows: [
                    SettingsRow(
                        id: "appearance", systemImage: "circle.lefthalf.filled", title: zh ? "外观" : "Appearance",
                        value: preferences.appearance.title(language), action: .appearance),
                    SettingsRow(
                        id: "language", systemImage: "globe", title: zh ? "语言" : "Language",
                        value: preferences.language.summary(
                            system: preferences.systemDisplayLanguage, language: language),
                        action: .language),
                ]),
            SettingsSection(
                id: .security, title: zh ? "安全" : "Security",
                footer: zh
                    ? "怀疑账号被盗时，先全部停止，再下线其他设备。"
                    : "If you think someone else has access, stop everything first, then sign out your other devices.",
                rows: [
                    SettingsRow(
                        id: "stopAll", systemImage: "stop.circle", title: zh ? "全部停止" : "Stop everything",
                        action: .stopAll, isDestructive: true, needsNetwork: true),
                    SettingsRow(
                        id: "signOutOthers", systemImage: "iphone.slash",
                        title: zh ? "下线其他设备" : "Sign out other devices",
                        subtitle: zh ? "在登录设备页操作，可以同时全部停止" : "On the Devices page; can also stop everything",
                        action: .open(.devices)),
                ]),
            SettingsSection(
                id: .about, title: zh ? "关于" : "About", footer: nil,
                rows: [
                    SettingsRow(
                        id: "about", systemImage: "info.circle", title: zh ? "关于 ThinkTin" : "About ThinkTin",
                        value: appInfo.version, action: .open(.about)),
                    SettingsRow(
                        id: "licenses", systemImage: "doc.text", title: AppRoute.licenses.title(language),
                        action: .open(.licenses)),
                    // 上手引导（12.17）：随时能再看一遍。
                    SettingsRow(
                        id: "onboarding", systemImage: "sparkles", title: OnboardingText.settingsRow(language),
                        action: .open(.onboarding)),
                ]),
        ]
    }
}

/// 设置中心的一组。
public struct SettingsSection: Identifiable, Hashable, Sendable {
    public enum ID: String, CaseIterable, Hashable, Sendable {
        case account, models, vault, notifications, display, security, about
    }

    public var id: ID
    public var title: String
    public var footer: String?
    public var rows: [SettingsRow]

    public init(id: ID, title: String, footer: String?, rows: [SettingsRow]) {
        self.id = id
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

/// 设置中心的一行。
public struct SettingsRow: Identifiable, Hashable, Sendable {
    /// 点了做什么。
    public enum Action: Hashable, Sendable {
        /// 打开别的功能的页面（压栈）。
        case open(AppRoute)
        /// 本功能的子页面：外观、语言。
        case appearance
        case language
        /// 打开系统设置里 ThinkTin 的通知设置。
        case systemNotificationSettings
        /// 退出登录（先确认）。
        case signOut
        /// 注销账号（12.2 的注销页）。
        case deleteAccount
        /// 全部停止（先确认，12.2 的 `StopAllRow`）。
        case stopAll
    }

    public var id: String
    public var systemImage: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    /// nil：只显示，不能点（手机号）。
    public var action: Action?
    /// 危险操作：图标和标题用危险色。
    public var isDestructive: Bool
    /// 要联网：离线时禁用。
    public var needsNetwork: Bool

    public init(
        id: String, systemImage: String, title: String, subtitle: String? = nil, value: String? = nil,
        action: Action?, isDestructive: Bool = false, needsNetwork: Bool = false
    ) {
        self.id = id
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.action = action
        self.isDestructive = isDestructive
        self.needsNetwork = needsNetwork
    }

    /// 跳到的页面（`open` 的）。
    public var route: AppRoute? {
        if case .open(let route) = action { return route }
        return nil
    }
}

/// 设置功能里共用的小工具。
enum SettingsSupport {
    /// 任意错误转成 `ClientError`（不是的按内部错误）。
    nonisolated static func clientError(_ error: any Error) -> ClientError {
        (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}
