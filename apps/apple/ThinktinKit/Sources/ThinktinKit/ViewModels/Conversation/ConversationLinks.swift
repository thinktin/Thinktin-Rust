import Foundation

/// agent 回复里的链接点了怎么办（Markdown 里的 `[文字](网址)`、自动识别的网址）。agent 写的内容不可信，只放行常见的几种：
///
/// - `thinktin://` 的深链在 App 里打开（`Router.handle(url:)`，认不出的不理）；
/// - `http`、`https`、`mailto` 交给系统打开（浏览器、邮件）；
/// - 别的（`tel:`、`sms:`、别的 App 的 scheme、`file:`、`javascript:`……）不打开。
public enum ConversationLinks {
    public enum Handling: Hashable, Sendable {
        /// App 自己的深链。
        case inApp
        /// 交给系统（浏览器、邮件）。
        case external
        /// 不打开。
        case blocked
    }

    /// 交给系统打开的 scheme。
    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    public static func handling(of url: URL) -> Handling {
        guard let scheme = url.scheme?.lowercased() else { return .blocked }
        if scheme == DeepLink.scheme { return .inApp }
        guard externalSchemes.contains(scheme) else { return .blocked }
        // 网址要有主机（`https:foo` 这种不算），邮件要有收件人。
        if scheme == "mailto" { return url.absoluteString.count > "mailto:".count ? .external : .blocked }
        return (url.host?.isEmpty == false) ? .external : .blocked
    }
}
