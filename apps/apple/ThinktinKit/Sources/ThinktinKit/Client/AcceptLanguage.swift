import Foundation

/// `Accept-Language` 请求头（11.8）：client-core 的每个请求（包括刷新令牌、事件流握手）都带上它。服务端在新用户
/// 注册时按它定推送和收件箱的语言（之后用户可以在 App 里改，见 `setLocale`），agent 目录的介绍和许可说明也按它给。
///
/// 真核心建 `CoreClient` 时默认用系统的语言偏好（client-core 的 `accept_language_header`）；App 里切换界面语言后调
/// `ClientProtocol.setAcceptLanguage(_:)`，值用 `header(for:)` 拼。这里的规则和 client-core 一致（适配层的测试逐条
/// 对照过），Mock 也按这里校验。
public enum AcceptLanguage {
    /// 请求头最长多少字节（client-core 拒绝更长的）。
    public static let maxLength = 256
    /// 最多取几个语言标签。
    public static let maxTags = 10
    /// 一个语言标签最长几个字符（更长的跳过）。
    public static let maxTagLength = 35

    /// 把语言列表（按偏好排好，比如 `["zh-Hans-CN", "en-US", "en"]`）拼成请求头：`zh-Hans-CN, en-US;q=0.9, en;q=0.8`。
    /// 去掉首尾空白；跳过空的、超过 35 个字符的、有字母数字和 `-`、`_` 以外字符的；`_` 换成 `-`；最多 10 个。
    /// 一个都不剩时是空串。
    public static func header(tags: [String]) -> String {
        let usable = tags.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(isTag).prefix(maxTags)
        return usable.enumerated().map { i, tag in
            let tag = tag.replacingOccurrences(of: "_", with: "-")
            return i == 0 ? tag : "\(tag);q=0.\(maxTags - i)"
        }.joined(separator: ", ")
    }

    /// 系统的语言偏好（`Locale.preferredLanguages`）拼成的请求头；一个能用的都没有时为 nil（不带这个头）。
    public static var system: String? {
        let value = header(tags: Locale.preferredLanguages)
        return value.isEmpty ? nil : value
    }

    /// App 里选了界面语言：它排第一（`zh-CN` 或 `en`），后面跟系统的语言偏好（服务端只认中文和英文，
    /// 排第一的就是推送、收件箱用的语言）。
    public static func header(for language: DisplayLanguage, systemTags: [String] = Locale.preferredLanguages)
        -> String
    {
        header(tags: [language.userLocale.rawValue] + systemTags)
    }

    /// 检查要设的值（和 client-core 的规则一致）：去掉首尾空白，空的当作不带（返回 nil）；超过 256 字节，或者有
    /// 换行、控制字符这类请求头放不下的字符时抛 `invalidArgument`（client-core 不发请求就拒）。
    public static func validated(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= maxLength else {
            throw ClientError.invalidArgument(message: "accept_language is longer than \(maxLength) bytes")
        }
        // 和 Rust 的 http::HeaderValue 一样：制表符、32 以上（127 除外）的字节都行。
        guard value.utf8.allSatisfy({ $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }) else {
            throw ClientError.invalidArgument(message: "accept_language has characters a header cannot carry")
        }
        return value
    }

    /// 像语言标签：非空、不超过 35 个字符、只有 ASCII 字母数字和 `-`、`_`。
    private static func isTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.utf8.count <= maxTagLength
            && tag.utf8.allSatisfy { b in
                (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D
                    || b == 0x5F
            }
    }
}
