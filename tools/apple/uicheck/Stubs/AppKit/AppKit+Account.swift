// WBS 12.2（登录页的验证码输入框）用到的 AppKit 类型的桩：签名照 Apple 文档（macOS 14 SDK）。

public struct NSTextContentType: Hashable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let username = NSTextContentType(rawValue: "username")
    public static let password = NSTextContentType(rawValue: "password")
    public static let oneTimeCode = NSTextContentType(rawValue: "one-time-code")
}
