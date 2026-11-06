import Foundation

// 发送反馈（`.feedback`，参考 76、77；规范 4.9.14、6.20 B）：多行输入框、“和哪个 Botin 有关”的选择器、底部全宽的
// “发送反馈”。ThinkTin 没有通用的反馈接口（只有针对回复、产出物的举报），先用邮件：拼一个 `mailto:` 链接交给系统
// 的邮件 App，正文末尾带上 App 版本、系统版本和选的 Botin，发之前用户能看到、能改。

/// 反馈的表单。
public struct FeedbackDraft: Hashable, Sendable {
    /// 反馈邮箱（占位，上线前和运营确认；规范 6.20 B）。
    public static let address = "feedback@thinktin.cn"
    /// 最多几个字（按 Unicode 标量数）：太长的 `mailto:` 链接有的邮件 App 打不开。
    public static let maxLength = 4_000

    public var text: String
    /// 和哪个 Botin 有关；nil 是“无”。
    public var instanceID: InstanceID?

    public init(text: String = "", instanceID: InstanceID? = nil) {
        self.text = text
        self.instanceID = instanceID
    }

    public var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isTooLong: Bool { trimmed.unicodeScalars.count > Self.maxLength }

    /// 底部“发送反馈”能不能点：写了字、不超长（参考 76：空的时候灰）。
    public var canSend: Bool { !trimmed.isEmpty && !isTooLong }

    /// 邮件的主题。
    public static func subject(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "ThinkTin 反馈" : "ThinkTin feedback"
    }

    /// 邮件正文：反馈，空一行，再是“App / 系统 / Botin”三行（Botin 是“无”时不写）。
    /// - Parameters:
    ///   - instance: 选的 Botin（名字和 id 都写上，方便查）。
    ///   - system: 系统和版本（`FeedbackDraft.systemDescription()`）。
    public func body(
        instance: Instance?, appInfo: AppInfo, system: String, language: DisplayLanguage = .current
    ) -> String {
        let zh = language == .chinese
        var lines = [
            "——",
            (zh ? "App：" : "App: ") + appInfo.footer(language),
            (zh ? "系统：" : "System: ") + system,
        ]
        if let instance {
            lines.append((zh ? "Botin：" : "Botin: ") + "\(instance.name)（\(instance.id.rawValue)）")
        }
        return trimmed + "\n\n" + lines.joined(separator: "\n")
    }

    /// 交给系统邮件 App 的 `mailto:` 链接；没写内容时为 nil。
    public func mailtoURL(
        instance: Instance?, appInfo: AppInfo, system: String, language: DisplayLanguage = .current
    ) -> URL? {
        guard canSend else { return nil }
        let subject = Self.percentEncoded(Self.subject(language))
        let body = Self.percentEncoded(
            self.body(instance: instance, appInfo: appInfo, system: system, language: language))
        return URL(string: "mailto:\(Self.address)?subject=\(subject)&body=\(body)")
    }

    /// 这台设备的系统和版本，写进反馈邮件（“iOS 18.1.0”）。
    public static func systemDescription(_ info: ProcessInfo = .processInfo) -> String {
        let version = info.operatingSystemVersion
        #if os(iOS)
            let name = "iOS"
        #elseif os(macOS)
            let name = "macOS"
        #else
            let name = "Linux"
        #endif
        return "\(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `mailto:` 的参数值按 RFC 6068 编码：只留字母数字和 `-._~`，空格、换行、`&`、`=`、`+`、中文都编码。
    static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// RFC 3986 的 unreserved：ASCII 字母数字和 `-._~`（`CharacterSet.alphanumerics` 含中文，不能用）。
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

/// 发送反馈页的文案。
public enum FeedbackText {
    /// 输入框的占位（参考 76 滚上去了，看不到；ThinkTin 自己写）。
    public static func placeholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "遇到了什么问题，或者希望 ThinkTin 怎么改进？" : "What went wrong, or how could ThinkTin be better?"
    }

    /// 输入框下面的脚注。
    public static func footer(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "写下发生了什么、你本来想做什么。会用邮件发给 ThinkTin 团队，附上 App 和系统的版本。"
            : "Tell us what happened and what you were trying to do. It goes to the ThinkTin team by email, with "
                + "your app and system versions."
    }

    /// 选择器那一组的标题（参考 76）。
    public static func botinHeader(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "出问题的 Botin（可选）" : "The Botin involved (optional)"
    }

    /// 选择器那一行。
    public static func botinLabel(_ language: DisplayLanguage = .current) -> String { "Botin" }

    /// 底部的全宽按钮。
    public static func send(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "发送反馈" : "Send feedback"
    }

    /// 太长了。
    public static func tooLong(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "最多 \(FeedbackDraft.maxLength) 个字。" : "Up to \(FeedbackDraft.maxLength) characters."
    }

    /// 打不开邮件 App 时的提示。
    public static func noMailTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "没能打开邮件" : "Couldn't open Mail"
    }

    public static func noMailMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "可以把反馈发到 \(FeedbackDraft.address)。" : "You can email your feedback to \(FeedbackDraft.address)."
    }

    /// 提示里复制邮箱的按钮。
    public static func copyAddress(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "复制邮箱" : "Copy address"
    }
}
