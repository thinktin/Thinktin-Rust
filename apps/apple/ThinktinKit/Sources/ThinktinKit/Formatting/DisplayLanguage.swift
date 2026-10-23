import Foundation

/// 界面文案用哪种语言。App 只做简体中文和英文；系统语言是中文时用中文，其余用英文。
public enum DisplayLanguage: String, Hashable, Sendable, CaseIterable {
    case chinese
    case english

    /// 按系统的首选语言。
    public static var current: DisplayLanguage {
        guard let tag = Locale.preferredLanguages.first else { return .chinese }
        return DisplayLanguage(languageTag: tag)
    }

    /// `zh-Hans-CN`、`zh_TW` → 中文；其余 → 英文。
    public init(languageTag tag: String) {
        self = tag.lowercased().hasPrefix("zh") ? .chinese : .english
    }

    /// 发给服务端的用户语言（推送、收件箱的文案）。
    public var userLocale: UserLocale {
        switch self {
        case .chinese: .zhCN
        case .english: .en
        }
    }

    /// 日期格式化用的 `Locale`。
    public var locale: Locale {
        switch self {
        case .chinese: Locale(identifier: "zh_CN")
        case .english: Locale(identifier: "en_US")
        }
    }

    /// AI 生成内容的显式标识（16.3），和服务端 `proto::labels::explicit_label` 一致。
    public var aiGeneratedLabel: String {
        switch self {
        case .chinese: "AI 生成"
        case .english: "AI-generated"
        }
    }
}
