import Foundation

/// Mock 用的简化密码检查（真实规则在 client-core 的 `secrets.rs`，经 `CoreSecretDetector` 调用）。
/// 认：Anthropic / OpenAI 风格的 key、GitHub 令牌、私钥头、“password=…”/“密码：…”。
public struct MockSecretDetector: SecretDetector {
    public init() {}

    private struct Rule {
        let pattern: String
        let kind: SecretKind
        let name: String
        let service: String
        /// 取哪个捕获组作为值（0 是整段）。
        let group: Int
        let storable: Bool
    }

    private static let rules: [Rule] = [
        Rule(
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, kind: .privateKey, name: "private_key", service: "",
            group: 0, storable: false),
        Rule(
            pattern: #"sk-ant-[A-Za-z0-9_\-]{20,}"#, kind: .apiKey, name: "anthropic", service: "anthropic", group: 0,
            storable: true),
        Rule(
            pattern: #"sk-(?!ant-)[A-Za-z0-9_\-]{20,}"#, kind: .apiKey, name: "openai", service: "openai", group: 0,
            storable: true),
        Rule(
            pattern: #"gh[pousr]_[A-Za-z0-9]{20,}"#, kind: .token, name: "github", service: "github", group: 0,
            storable: true),
        Rule(
            pattern: #"(?i)(?:password|passwd|pwd|密码)\s*[:=：]\s*(\S{4,})"#, kind: .labeled, name: "password",
            service: "", group: 1, storable: true),
    ]

    public func detectSecrets(in text: String) -> [DetectedSecret] {
        let ns = text as NSString
        var found: [DetectedSecret] = []
        for rule in Self.rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = match.range(at: rule.group)
                guard r.location != NSNotFound else { continue }
                let range = r.location..<(r.location + r.length)
                // 已经被前面的规则认出来的不重复报。
                if found.contains(where: { $0.utf16Range.overlaps(range) }) { continue }
                found.append(
                    DetectedSecret(
                        kind: rule.kind, utf16Range: range, value: ns.substring(with: r),
                        suggestedName: Self.sanitizeName(rule.name), service: rule.service,
                        isStorable: rule.storable))
            }
        }
        return found.sorted { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }
    }

    public func redactMessage(_ text: String, references: [SecretReference]) -> String {
        references.reduce(text) { out, ref in
            ref.value.isEmpty ? out : out.replacingOccurrences(of: ref.value, with: VaultItem.reference(for: ref.name))
        }
    }

    public func uniqueVaultName(base: String, taken: [String]) -> String {
        let name = Self.sanitizeName(base)
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name)_\(n)") { n += 1 }
        return "\(name)_\(n)"
    }

    /// 和 client-core 的 `sanitize_name` 一致：小写字母、数字、`-`，其余换成 `_`，最长 64。
    static func sanitizeName(_ raw: String, fallback: String = "secret") -> String {
        var s = String(
            raw.lowercased().map { c -> Character in
                (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" ? c : "_"
            })
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        s = String(s.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return s.isEmpty ? fallback : s
    }
}
