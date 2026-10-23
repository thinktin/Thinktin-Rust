import SwiftUI
import ThinktinKit

#if canImport(UIKit)
    import UIKit
#endif
#if canImport(UserNotifications)
    import UserNotifications
#endif

// 设置功能（WBS 12.12）放进环境的东西和系统能力：外观与语言的偏好（App 根视图用 `.settingsPreferences()` 生效）、
// 读系统通知权限、系统设置的地址、许可证清单的位置。

// MARK: - 外观与语言

private struct SettingsPreferencesKey: EnvironmentKey {
    static let defaultValue: SettingsPreferences? = nil
}

extension EnvironmentValues {
    /// 外观与语言的偏好。没注入时设置页用 `SettingsPreferences.shared`；预览、测试注入一份只在内存里的。
    public var settingsPreferences: SettingsPreferences? {
        get { self[SettingsPreferencesKey.self] }
        set { self[SettingsPreferencesKey.self] = newValue }
    }
}

extension View {
    /// App 的根视图用（WBS 12.12）：按设置里选的外观设 `preferredColorScheme`（跟随系统时不设），按选的语言设界面语言
    /// （`\.displayLanguage`；跟随系统时是系统给 App 定的语言），并把偏好放进环境给设置页。偏好是 `@Observable` 的，
    /// 在设置里改了整个 App 马上跟着变，不用重启。
    ///
    /// ```swift
    /// RootView(model: environment.appModel)
    ///     .settingsPreferences()
    /// ```
    public func settingsPreferences(_ preferences: SettingsPreferences = .shared) -> some View {
        SettingsPreferencesScope(preferences: preferences, content: self)
    }

    /// 预览、测试用：只把偏好放进环境（界面语言、深浅色由 `previewShell` 定）。
    func settingsPreferencesStore(_ preferences: SettingsPreferences) -> some View {
        environment(\.settingsPreferences, preferences)
    }
}

/// `.settingsPreferences()` 的容器：读偏好（`@Observable`，改了就重画）。
private struct SettingsPreferencesScope<Content: View>: View {
    let preferences: SettingsPreferences
    let content: Content

    var body: some View {
        content
            .environment(\.displayLanguage, preferences.displayLanguage)
            .environment(\.settingsPreferences, preferences)
            .preferredColorScheme(preferences.appearance.colorScheme)
    }
}

extension AppearancePreference {
    /// 交给 `preferredColorScheme` 的值：跟随系统是 nil。
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - 系统通知权限

/// 读系统设置里 ThinkTin 的通知权限（UserNotifications）。不在 App 包里运行时（命令行跑的测试）读不到，返回 `.unknown`：
/// 那种进程里调 `UNUserNotificationCenter.current()` 会直接崩。
public struct SystemNotificationPermission: NotificationPermissionReading {
    public init() {}

    public func currentPermission() async -> NotificationPermission {
        #if canImport(UserNotifications)
            guard Self.isAppBundle(Bundle.main.bundleURL, identifier: Bundle.main.bundleIdentifier) else {
                return .unknown
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized: return .authorized
            case .provisional: return .provisional
            // `ephemeral`（只有 App Clip 有）和以后新加的。
            default: return .unknown
            }
        #else
            return .unknown
        #endif
    }

    /// 是 App 包（`.app`，有包 id）：只有这时才能用通知中心。
    static func isAppBundle(_ url: URL, identifier: String?) -> Bool {
        url.pathExtension == "app" && !(identifier ?? "").isEmpty
    }
}

private struct NotificationPermissionReaderKey: EnvironmentKey {
    static let defaultValue: any NotificationPermissionReading = SystemNotificationPermission()
}

extension EnvironmentValues {
    /// 设置中心读通知权限用的。默认读系统的；预览、测试注入 `FixedNotificationPermission`。
    public var notificationPermissionReader: any NotificationPermissionReading {
        get { self[NotificationPermissionReaderKey.self] }
        set { self[NotificationPermissionReaderKey.self] = newValue }
    }
}

/// 系统设置的地址。
enum SystemSettingsLink {
    /// 系统设置里 ThinkTin 的通知设置（iOS 16 起直接到通知那一页；macOS 是系统设置的“通知”）。
    @MainActor
    static var notifications: URL? {
        #if canImport(UIKit)
            URL(string: UIApplication.openNotificationSettingsURLString)
        #else
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #endif
    }
}

// MARK: - 许可证清单

private struct LicensesDirectoryKey: EnvironmentKey {
    /// 进程里找一次：ThinktinCore 资源包里的 `Licenses/`（`CoreLicenses.locate()`）。
    static let defaultValue: URL? = CoreLicenses.locate()
}

extension EnvironmentValues {
    /// 许可证清单的目录（`inventory.json`、`NOTICES.md`、`texts/`）。默认按资源包的名字找；App 拿得到
    /// `ThinktinCoreResources.bundle` 时可以直接注入它的 `Licenses`。
    public var licensesDirectory: URL? {
        get { self[LicensesDirectoryKey.self] }
        set { self[LicensesDirectoryKey.self] = newValue }
    }
}
