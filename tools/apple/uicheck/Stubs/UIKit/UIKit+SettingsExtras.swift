// 保险箱的卡片、联系信息、网站表单（改版第 2 轮 r2/settings，参考 60、61、99）用到的自动填充类型：签名照 Apple 文档（iOS 17 SDK）。

extension UITextContentType {
    /// iOS 10。
    public static let creditCardNumber = UITextContentType(rawValue: "cc-number")
    /// iOS 17。
    public static let creditCardExpiration = UITextContentType(rawValue: "cc-exp")
    /// iOS 17。
    public static let creditCardSecurityCode = UITextContentType(rawValue: "cc-csc")
    /// iOS 17。
    public static let creditCardName = UITextContentType(rawValue: "cc-name")
    /// iOS 10。
    public static let emailAddress = UITextContentType(rawValue: "email")
    /// iOS 10。
    public static let URL = UITextContentType(rawValue: "url")
    /// iOS 10。
    public static let countryName = UITextContentType(rawValue: "country-name")
    /// iOS 10。
    public static let streetAddressLine1 = UITextContentType(rawValue: "address-line1")
    /// iOS 10。
    public static let streetAddressLine2 = UITextContentType(rawValue: "address-line2")
    /// iOS 10。
    public static let addressCity = UITextContentType(rawValue: "address-level2")
    /// iOS 10。
    public static let addressState = UITextContentType(rawValue: "address-level1")
    /// iOS 10。
    public static let postalCode = UITextContentType(rawValue: "postal-code")
}
