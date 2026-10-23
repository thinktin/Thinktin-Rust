// WBS 12.2（登录页的手机号、验证码输入框）用到的 UIKit 类型的桩：签名照 Apple 文档（iOS 17 SDK）。

public struct UITextContentType: Hashable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let name = UITextContentType(rawValue: "name")
    public static let nickname = UITextContentType(rawValue: "nickname")
    public static let telephoneNumber = UITextContentType(rawValue: "tel")
    public static let username = UITextContentType(rawValue: "username")
    public static let password = UITextContentType(rawValue: "password")
    public static let oneTimeCode = UITextContentType(rawValue: "one-time-code")
}

public enum UIKeyboardType: Int, Sendable {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad, emailAddress,
        decimalPad, twitter, webSearch, asciiCapableNumberPad
}
