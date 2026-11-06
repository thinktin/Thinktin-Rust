import Foundation
import Observation

/// 设置中心（WBS 12.12，`.settings`，首页左上的头像弹出的 sheet）。照参考 53、70、75 一比一排（规范 4.9.1），
/// 组和行只放参考里有的，换成 ThinkTin 自己的入口：
/// 1. 账号行（头像、昵称、打码的手机号）、用量（今天用了多少）、订阅（演示，参考 56）、保险箱；
/// 2. 连接（参考“连接应用”的位置，规范 4.8：电脑、IM 渠道、模型 key、保险箱和即将推出的应用）；
/// 3. “Botin”组：权限（自然语言规则，演示，参考 62；审批中心从那页进）、登录设备（参考“管理你的设备”）、导入记忆（参考 71）；
/// 4. 通知、外观、语言、触感反馈；
/// 5. 链接组（参考 75 帮助中心、隐私政策、条款那一组）：隐私政策、用户协议，后面是关于 ThinkTin（备案号）、开源许可。
///    这两行参考里没有，是合规和上架要求的，放进参考放链接的这一组，不单独成组；
/// 6. 发送反馈（单独一组，参考 75；用邮件发）；
/// 7. 退出登录（单独一组）。版本区（Logo、名字、版本号）在界面最底下。
/// 注销账号在账号页里（参考 54）。参考里没有的入口不放：模型 key 从“连接”进，下线其他设备（可以顺带全部停止）在
/// 登录设备页，全部停止还有快捷指令，上手引导是新用户自动弹的；实时活动的两个开关暂时没有入口（照默认：自己发的任务
/// 显示在锁屏上，计划运行不显示）。
///
/// 设置中心不联网也能用（`OfflinePolicy.local`）：用户先用应用框架已经拿到的（`AppModel.user`），再静默 `me()` 一次。
/// 这些入口和说明都不是 agent 写的，按 AI 生成标识的规则表（ios-packages.md 12.5）都不用标。
@Observable @MainActor
public final class SettingsModel {
    public private(set) var user: User?
    /// 系统通知权限；读到之前为 nil。
    public private(set) var notificationPermission: NotificationPermission?
    /// 今天（东八区）按 key 分组的用量：“用量”那一行的值。没拉到为 nil。
    public private(set) var todayUsage: UsageSummary?
    public let preferences: SettingsPreferences
    public let appInfo: AppInfo

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let notifications: any NotificationPermissionReading
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isLoadingUser = false

    /// - Parameters:
    ///   - user: 已经知道的用户（`AppModel.user`）。
    ///   - notifications: 读系统通知权限的（界面层给 `SystemNotificationPermission`）。
    public init(
        client: any ClientProtocol, user: User?, preferences: SettingsPreferences,
        notifications: any NotificationPermissionReading, appInfo: AppInfo = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.user = user
        self.preferences = preferences
        self.notifications = notifications
        self.appInfo = appInfo
        self.now = now
    }

    /// 页面出现、回到前台（从系统设置回来）时调：读通知权限，静默刷新用户和今天的用量。
    public func refresh() async {
        await refreshNotificationPermission()
        await refreshUser()
        await refreshUsage()
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

    /// 静默拉今天的用量：失败了留着原来的（离线时那一行不显示值）。
    public func refreshUsage() async {
        if let usage = try? await UsageToday.load(client: client, now: now()) { todayUsage = usage }
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

    /// 账号行的名字：昵称，没有时是“账号”。
    public func accountTitle(_ language: DisplayLanguage = .current) -> String {
        let name = user?.nameForDisplay ?? ""
        return name.isEmpty ? AppRoute.account.title(language) : name
    }

    /// 页面上的各组（参考 53、70、75 的顺序）。
    public func sections(_ language: DisplayLanguage = .current) -> [SettingsSection] {
        let zh = language == .chinese
        return [
            SettingsSection(
                id: .account, title: nil, footer: nil,
                rows: [
                    SettingsRow(
                        id: "account", systemImage: "person.crop.circle", title: accountTitle(language),
                        subtitle: maskedPhone.isEmpty ? nil : maskedPhone, action: .open(.account), isProfile: true),
                    // 用量紧跟账号（参考 53 的第二行）。
                    SettingsRow(
                        id: "usage", systemImage: "chart.bar", title: AppRoute.usage.title(language),
                        value: UsageToday.rowValue(todayUsage, language: language), action: .open(.usage)),
                    // 订阅（参考 53 用量下面一行，页面是参考 56）：App 内购买等 12.23，页面是演示的方案。
                    SettingsRow(
                        id: "subscription", systemImage: "creditcard", title: AppRoute.subscription.title(language),
                        action: .open(.subscription)),
                    // 副标题界面上只画一行（参考 53 的副标题不折行），写短。
                    SettingsRow(
                        id: "vault", systemImage: "lock.rectangle.stack", title: AppRoute.vault.title(language),
                        subtitle: zh ? "Botin 登录用的账号，密码不发给模型" : "Botin sign-ins, never sent to models",
                        action: .open(.vault)),
                ]),
            SettingsSection(
                id: .connections, title: nil, footer: nil,
                rows: [
                    SettingsRow(
                        id: "connections", systemImage: "puzzlepiece.extension",
                        title: AppRoute.connections(category: nil).title(language),
                        subtitle: ConnectionsText.settingsSubtitle(language),
                        action: .open(.connections(category: nil)))
                ]),
            SettingsSection(
                id: .botins, title: "Botin", footer: nil,
                rows: [
                    // 权限（参考 53 的第一行）：自然语言规则还没有后端，副标题按演示数据写。审批中心从权限页进。
                    SettingsRow(
                        id: "permissions", systemImage: "hand.raised.square",
                        title: AppRoute.permissions.title(language),
                        subtitle: PermissionsDemoData.overview(language).settingsSubtitle(language),
                        action: .open(.permissions)),
                    // 参考的“管理你的设备”（参考的时区、Bot 电脑 ThinkTin 没有：6.17 时区不做，工作区在 Botin 资料里）。
                    SettingsRow(
                        id: "devices", systemImage: "laptopcomputer.and.iphone",
                        title: AppRoute.devices.title(language), action: .open(.devices)),
                    SettingsRow(
                        id: "importMemory", systemImage: "square.and.arrow.down",
                        title: AppRoute.importMemory.title(language), action: .open(.importMemory)),
                ]),
            SettingsSection(
                id: .preferences, title: nil,
                // 参考 70 这一组没有脚注：通知开着时不写，没开、关掉了、读不到时才说一句。
                footer: notificationPermission?.footer(language),
                rows: [
                    SettingsRow(
                        id: "notifications", systemImage: "bell", title: zh ? "通知" : "Notifications",
                        value: notificationPermission?.title(language), action: .systemNotificationSettings),
                    SettingsRow(
                        id: "appearance", systemImage: "circle.lefthalf.filled", title: zh ? "外观" : "Appearance",
                        value: preferences.appearance.title(language), action: .appearance),
                    SettingsRow(
                        id: "language", systemImage: "globe", title: zh ? "语言" : "Language",
                        value: preferences.language.summary(
                            system: preferences.systemDisplayLanguage, language: language),
                        action: .language),
                    SettingsRow(
                        id: "haptics", systemImage: "hand.tap", title: HapticsText.title(language),
                        value: HapticsText.value(preferences.hapticsEnabled, language: language), action: .haptics),
                ]),
            SettingsSection(
                id: .links, title: nil, footer: nil,
                rows: [
                    // 隐私政策在前（参考 75）。
                    SettingsRow(
                        id: "privacy", systemImage: "hand.raised", title: zh ? "隐私政策" : "Privacy Policy",
                        action: .link(LegalLinks.privacyPolicy)),
                    SettingsRow(
                        id: "terms", systemImage: "doc.plaintext", title: zh ? "用户协议" : "Terms of Service",
                        action: .link(LegalLinks.termsOfService)),
                    // 参考这一组最后是产品自己的条款；ThinkTin 这里放关于（备案号、AI 生成内容说明）和开源许可：
                    // 参考里没有，是合规和上架要求的，压栈（行尾是箭头，不是 `arrow.up.right`）。
                    SettingsRow(
                        id: "about", systemImage: "info.circle", title: zh ? "关于 ThinkTin" : "About ThinkTin",
                        action: .open(.about)),
                    SettingsRow(
                        id: "licenses", systemImage: "doc.text", title: AppRoute.licenses.title(language),
                        action: .open(.licenses)),
                ]),
            SettingsSection(
                id: .feedback, title: nil, footer: nil,
                rows: [
                    SettingsRow(
                        id: "feedback", systemImage: "envelope", title: AppRoute.feedback.title(language),
                        action: .open(.feedback))
                ]),
            SettingsSection(
                id: .signOut, title: nil, footer: nil,
                rows: [
                    SettingsRow(
                        id: "signOut", systemImage: "rectangle.portrait.and.arrow.right",
                        title: zh ? "退出登录" : "Sign out", action: .signOut, isDestructive: true)
                ]),
        ]
    }

    /// 最底下版本区的名字和版本：“ThinkTin”“0.1.0（1）”。
    public func versionFooter(_ language: DisplayLanguage = .current) -> (name: String, version: String) {
        (AppInfo.appName, appInfo.versionText(language))
    }
}

/// 设置中心的一组。
public struct SettingsSection: Identifiable, Hashable, Sendable {
    public enum ID: String, CaseIterable, Hashable, Sendable {
        case account, connections, botins, preferences, links, feedback, signOut
    }

    public var id: ID
    /// 分组标题；参考里大多数组没有标题，为 nil。
    public var title: String?
    public var footer: String?
    public var rows: [SettingsRow]

    public init(id: ID, title: String?, footer: String?, rows: [SettingsRow]) {
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
        /// 本功能的子页面：外观、语言、触感反馈。
        case appearance
        case language
        case haptics
        /// 打开系统设置里 ThinkTin 的通知设置。
        case systemNotificationSettings
        /// 在浏览器里打开（行尾 `arrow.up.right`）。
        case link(URL)
        /// 退出登录（先确认）。
        case signOut
    }

    public var id: String
    public var systemImage: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    /// nil：只显示，不能点（手机号）。
    public var action: Action?
    /// 危险操作：标题用危险色。
    public var isDestructive: Bool
    /// 账号行：大一号的头像、名字、打码的手机号（参考 53 的第一行）。
    public var isProfile: Bool

    public init(
        id: String, systemImage: String, title: String, subtitle: String? = nil, value: String? = nil,
        action: Action?, isDestructive: Bool = false, isProfile: Bool = false
    ) {
        self.id = id
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.action = action
        self.isDestructive = isDestructive
        self.isProfile = isProfile
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
