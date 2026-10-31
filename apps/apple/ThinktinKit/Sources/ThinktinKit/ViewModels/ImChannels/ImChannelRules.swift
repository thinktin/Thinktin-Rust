import Foundation

/// IM 渠道（WBS 12.14）表单里能在本机先查的问题。
public enum ImChannelProblem: Error, Hashable, Sendable {
    /// 不是飞书、Lark、企业微信、钉钉群机器人的地址（或者改过：大小写、端口、多余的参数都不认）。
    case unknownAddress
    /// 地址后面的 token 缺了或者格式不对。
    case badToken
    /// 换地址时须保留原群机器人的平台。
    case differentVendor
    /// 企业微信的机器人没有签名密钥。
    case secretNotSupported
    /// 签名密钥是 8 到 128 个可见字符（钉钉的以 SEC 开头）。
    case badSecret
    /// 备注最多 64 个字、不能有控制字符。
    case badLabel
    /// 至少选一种事件（不想收就关掉渠道）。
    case noEvents
}

/// 服务端的规则（crates/proto/src/im.rs、gateway 的 `routes/im_channels.rs`），本机先查一遍，错了标在对应的地方：
///
/// - webhook 地址要一字不差地以官方前缀开头（https、官方域名、官方路径），后面只能跟 token（8 到 128 个字母、数字、
///   `-`、`_`）；粘贴时首尾的空白不算。服务端只存 token，发送时按前缀重新拼地址。
/// - 签名密钥（“加签”）：飞书、Lark、钉钉可以有，企业微信没有；8 到 128 个可见 ASCII 字符，钉钉的以 `SEC` 开头。
///   空的就是没有。
/// - 备注 0 到 64 个字（按 Unicode 标量数），不能有控制字符；事件至少一种。
/// - 每个账号最多 20 个渠道；测试消息每小时最多 10 条（多了 429）。
public enum ImChannelRules {
    public static let maxChannels = 20
    public static let maxLabelLength = 64
    public static let testsPerHour = 10
    public static let tokenLength = 8...128
    public static let secretLength = 8...128

    /// 各家 webhook 地址的固定前缀，后面接 token。
    public static func webhookBase(_ vendor: ImVendor) -> String? {
        switch vendor {
        case .feishu: "https://open.feishu.cn/open-apis/bot/v2/hook/"
        case .lark: "https://open.larksuite.com/open-apis/bot/v2/hook/"
        case .wecom: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key="
        case .dingtalk: "https://oapi.dingtalk.com/robot/send?access_token="
        case .unknown: nil
        }
    }

    /// 有没有“加签”：企业微信没有（地址里的 key 就是凭证）。
    public static func supportsSecret(_ vendor: ImVendor) -> Bool {
        vendor != .wecom
    }

    /// 解析粘贴的地址：平台和 token。
    public static func parseWebhook(_ url: String) -> Result<(vendor: ImVendor, token: String), ImChannelProblem> {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        for vendor in ImVendor.knownCases {
            guard let base = webhookBase(vendor), url.hasPrefix(base) else { continue }
            let token = String(url.dropFirst(base.count))
            return isValidToken(token) ? .success((vendor, token)) : .failure(.badToken)
        }
        return .failure(.unknownAddress)
    }

    /// 粘贴时认出是哪家（地址还没粘完整、token 不对也认得出来）。
    public static func vendor(of url: String) -> ImVendor? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImVendor.knownCases.first { vendor in webhookBase(vendor).map { url.hasPrefix($0) } ?? false }
    }

    static func isValidToken(_ token: String) -> Bool {
        tokenLength.contains(token.utf8.count)
            && token.utf8.allSatisfy { b in
                (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                    || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "-")
                    || b == UInt8(ascii: "_")
            }
    }

    /// 签名密钥（去掉首尾空白后为空就是没有，返回 nil）。
    public static func checkSecret(_ secret: String, vendor: ImVendor) -> ImChannelProblem? {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return nil }
        guard supportsSecret(vendor) else { return .secretNotSupported }
        // 可见 ASCII：0x21 到 0x7E。
        let visible = secret.utf8.allSatisfy { (0x21...0x7E).contains($0) }
        guard secretLength.contains(secret.utf8.count), visible else { return .badSecret }
        if vendor == .dingtalk, !secret.hasPrefix("SEC") { return .badSecret }
        return nil
    }

    public static func checkLabel(_ label: String) -> ImChannelProblem? {
        let scalars = label.unicodeScalars
        guard scalars.count <= maxLabelLength else { return .badLabel }
        if scalars.contains(where: { $0.properties.generalCategory == .control }) { return .badLabel }
        return nil
    }

    public static func checkEvents(_ events: [ImEvent]) -> ImChannelProblem? {
        events.isEmpty ? .noEvents : nil
    }

    /// 给用户辨认用的提示（和服务端一样）：token 后 4 位。
    public static func hint(_ token: String) -> String {
        "…" + String(token.suffix(4))
    }
}
