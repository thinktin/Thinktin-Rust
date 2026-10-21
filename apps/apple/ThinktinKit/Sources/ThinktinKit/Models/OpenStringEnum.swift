import Foundation

/// 服务端的字符串枚举在 Swift 里的形式：认识的取值是普通 case，不认识的保留原字符串（`unknown`），
/// 不会因为服务端加了新取值就解码失败或崩溃。
///
/// 实现的类型只要列出 `knownCases`、给出每个 case 的 `rawValue`，并有一个 `case unknown(String)`。
public protocol OpenStringEnum: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible
where RawValue == String {
    /// 认识的取值（不含 `unknown`）。
    static var knownCases: [Self] { get }
    /// 不认识的取值。由枚举的 `case unknown(String)` 满足。
    static func unknown(_ rawValue: String) -> Self
}

extension OpenStringEnum {
    /// 不会失败：不认识的取值变成 `unknown`。
    public init(rawValue: String) {
        self = Self.resolve(rawValue)
    }

    static func resolve(_ rawValue: String) -> Self {
        Self.knownCases.first { $0.rawValue == rawValue } ?? Self.unknown(rawValue)
    }

    public var description: String { rawValue }

    /// 是认识的取值（不是 `unknown`）。
    public var isKnown: Bool {
        Self.knownCases.contains(self)
    }

    // 编解码都是单个字符串；标准库对 RawRepresentable 的默认实现遇到不认识的值会报错，这里不会。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = Self.resolve(try c.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
