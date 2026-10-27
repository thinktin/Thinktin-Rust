import Foundation
import Observation

/// 外观（WBS 12.12）：跟随系统、浅色、深色。存在 UserDefaults 里，App 的根视图按它设 `preferredColorScheme`
/// （ThinktinUI 的 `.settingsPreferences()`）。
public enum AppearancePreference: String, CaseIterable, Hashable, Sendable {
    case system
    case light
    case dark

    /// 选项的名字。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .system: return zh ? "跟随系统" : "System"
        case .light: return zh ? "浅色" : "Light"
        case .dark: return zh ? "深色" : "Dark"
        }
    }

    /// 选项下面的一句说明。
    public func detail(_ language: DisplayLanguage = .current) -> String? {
        guard self == .system else { return nil }
        return language == .chinese
            ? "和系统的深色模式设置一致，跟着系统自动切换。" : "Matches your device and switches automatically."
    }
}

/// App 里选的界面语言（WBS 12.12，和安卓设置页一致）：跟随系统、中文、English。
///
/// “跟随系统”用系统给这个 App 定的语言（系统设置里 ThinkTin 的“语言”，没单独设就是系统语言）：中文时中文，其余英文
/// （`DisplayLanguage.current`）。选了中文或英文就固定用它，不管系统怎么设。
public enum LanguagePreference: String, CaseIterable, Hashable, Sendable {
    case system
    case chinese
    case english

    /// 固定成某一种语言。
    public init(_ language: DisplayLanguage) {
        switch language {
        case .chinese: self = .chinese
        case .english: self = .english
        }
    }

    /// 实际用的界面语言；`system` 是系统给 App 定的语言。
    public func resolved(system: DisplayLanguage) -> DisplayLanguage {
        switch self {
        case .system: system
        case .chinese: .chinese
        case .english: .english
        }
    }

    /// 选项的名字。“中文”“English”两种语言都用它自己的写法（不跟着界面语言翻译），找得到回去的路。
    public func title(_ language: DisplayLanguage = .current) -> String {
        switch self {
        case .system: language == .chinese ? "跟随系统" : "System"
        case .chinese: "中文"
        case .english: "English"
        }
    }

    /// 设置中心那一行右边的值：“跟随系统（中文）”“English”。
    public func summary(system: DisplayLanguage, language: DisplayLanguage = .current) -> String {
        guard self == .system else { return title(language) }
        let resolved = LanguagePreference(system).title(language)
        return language == .chinese ? "跟随系统（\(resolved)）" : "System (\(resolved))"
    }
}

/// 外观和语言的偏好（WBS 12.12），存在 UserDefaults 里（只是本机的显示偏好，不上传）。
///
/// - App 的根视图读它：`.settingsPreferences()`（ThinktinUI）按 `appearance` 设 `preferredColorScheme`，按
///   `displayLanguage` 设界面语言（`\.displayLanguage`）；`@Observable`，改了马上生效，不用重启。
/// - 推送、收件箱的语言在服务端（`User.locale`），由 `LanguageSettingsModel` 同步。
@Observable @MainActor
public final class SettingsPreferences {
    /// App 用的那一份（`UserDefaults.standard`）。
    public static let shared = SettingsPreferences(defaults: .standard)

    /// UserDefaults 的键。
    public static let appearanceKey = "cn.thinktin.settings.appearance"
    public static let languageKey = "cn.thinktin.settings.language"

    public private(set) var appearance: AppearancePreference
    public private(set) var language: LanguagePreference

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let systemLanguage: @Sendable () -> DisplayLanguage

    /// - Parameters:
    ///   - defaults: 存在哪里；nil 只放内存（预览、测试）。
    ///   - systemLanguage: 系统给 App 定的语言（测试里固定）。
    public init(
        defaults: UserDefaults?, systemLanguage: @escaping @Sendable () -> DisplayLanguage = { DisplayLanguage.current }
    ) {
        self.defaults = defaults
        self.systemLanguage = systemLanguage
        // 认不出的值（以后加了选项又降级回来）当没设。
        appearance =
            defaults?.string(forKey: Self.appearanceKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
        language = defaults?.string(forKey: Self.languageKey).flatMap(LanguagePreference.init(rawValue:)) ?? .system
    }

    /// 系统给 App 定的语言（“跟随系统”时用的）。
    public var systemDisplayLanguage: DisplayLanguage { systemLanguage() }

    /// 界面实际用的语言。
    public var displayLanguage: DisplayLanguage { language.resolved(system: systemLanguage()) }

    public func setAppearance(_ appearance: AppearancePreference) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        save(appearance.rawValue, forKey: Self.appearanceKey, isDefault: appearance == .system)
    }

    public func setLanguage(_ language: LanguagePreference) {
        guard language != self.language else { return }
        self.language = language
        save(language.rawValue, forKey: Self.languageKey, isDefault: language == .system)
    }

    /// 默认值（跟随系统）不存，删掉键。
    private func save(_ value: String, forKey key: String, isDefault: Bool) {
        if isDefault {
            defaults?.removeObject(forKey: key)
        } else {
            defaults?.set(value, forKey: key)
        }
    }
}
