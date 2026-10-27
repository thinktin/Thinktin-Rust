import Foundation

/// 发送前的密码拦截（11.6，docs/vault.md 第 7 节）：消息里认出了像密码、key 的内容，先不发，弹保险箱表单。
///
/// - 每一处是一条（`Entry`）：能存的预填建议名（`uniqueVaultName` 换掉已经用了的名字）、用途、密码（就是认出来的值），
///   确认后 `saveSecretFromMessage` 把值换成 `[vault:名字]` 放回输入框；私钥这类存不进的只提示从消息里删掉。
/// - 像模型厂商的 key（`looksLikeModelKey`）另外提示“添加为模型 key”（给 agent 用模型要配在模型 key 里，不是保险箱）。
/// - 用户坚持要发时带 `allowSecrets` 发送。服务端返回 `containsSecrets` 而本地没认出来的（规则不一样），只有
///   `serverCount`，没有条目，只能改了再发或坚持发送。
public struct SecretInterception: Hashable, Sendable {
    /// 拦下的那条消息（存好一条后换成带引用的新消息）。
    public private(set) var message: String
    public private(set) var entries: [Entry]
    /// 服务端说有几处（`containsSecrets(count:)`）；本地认出来的不为空时为 nil。
    public private(set) var serverCount: Int?
    /// 这次存进保险箱的条目名（按存的顺序）。
    public private(set) var savedNames: [String] = []

    /// - Parameters:
    ///   - takenNames: 保险箱里已经有的名字（建议名避开它们）。
    ///   - uniqueName: `SecretDetector.uniqueVaultName(base:taken:)`。
    public init(
        message: String, secrets: [DetectedSecret], takenNames: [String], serverCount: Int? = nil,
        uniqueName: (String, [String]) -> String
    ) {
        self.message = message
        self.entries = Self.makeEntries(secrets, takenNames: takenNames, previous: [], uniqueName: uniqueName)
        self.serverCount = secrets.isEmpty ? serverCount : nil
    }

    /// 拦下的一处。
    public struct Entry: Identifiable, Hashable, Sendable {
        /// 在消息里的位置（UTF-16 下标），同一条消息里唯一。
        public var id: Int { secret.id }
        public var secret: DetectedSecret
        /// 条目名（预填建议名，用户可以改）。
        public var name: String
        /// 用途（可以不填）。
        public var purpose: String
        /// 账号（可以不填）。
        public var username: String
        /// 只给这个实例用（默认）；关掉是所有实例都能用。
        public var onlyThisInstance: Bool
        public var isSaving: Bool
        /// 存的时候出的错（重名、名字不对、网络）。
        public var error: ClientError?

        public init(
            secret: DetectedSecret, name: String, purpose: String = "", username: String = "",
            onlyThisInstance: Bool = true
        ) {
            self.secret = secret
            self.name = name
            self.purpose = purpose
            self.username = username
            self.onlyThisInstance = onlyThisInstance
            self.isSaving = false
            self.error = nil
        }

        /// 能存进保险箱（私钥这种多行的不能）。
        public var isStorable: Bool { secret.isStorable }

        /// 像模型厂商的 key：提示“添加为模型 key”。
        public var looksLikeModelKey: Bool {
            secret.kind == .apiKey && SecretInterception.modelVendorServices.contains(secret.service)
        }

        /// 名字的问题；没问题为 nil。
        public var nameProblem: VaultNameProblem? { VaultNameProblem.check(name) }

        /// 现在能点“存进保险箱”。
        public var canSave: Bool { isStorable && !isSaving && nameProblem == nil }

        /// 要存的条目。
        public func newItem(instanceID: InstanceID) -> NewVaultItem {
            NewVaultItem(
                name: name.trimmingCharacters(in: .whitespaces), purpose: purpose.trimmingCharacters(in: .whitespaces),
                username: username.trimmingCharacters(in: .whitespaces), password: secret.value,
                instanceIDs: onlyThisInstance ? [instanceID] : [])
        }
    }

    /// 认得的模型厂商（client-core `secrets.rs` 的 `service`；`api_key` 是认不出厂商的 `sk-` 开头的 key，多半是国内模型厂商的）。
    public static let modelVendorServices: Set<String> = [
        "anthropic", "openai", "openrouter", "xai", "google", "api_key",
    ]

    /// 能存的几处。
    public var storableEntries: [Entry] { entries.filter(\.isStorable) }
    /// 存不进保险箱、只能从消息里删掉的几处（私钥）。
    public var blockedEntries: [Entry] { entries.filter { !$0.isStorable } }
    /// 有像模型 key 的。
    public var hasModelKey: Bool { entries.contains(where: \.looksLikeModelKey) }

    /// 处理完了：消息里认不出密码了（都换成了引用），可以直接发。
    public var isResolved: Bool { entries.isEmpty && serverCount == nil }

    /// 一共几处（本地认出来的，或者服务端说的）。
    public var count: Int { entries.isEmpty ? (serverCount ?? 0) : entries.count }

    public func entry(_ id: Entry.ID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// 改一条（表单的输入）。
    public mutating func edit(_ id: Entry.ID, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }

    /// 存好了一条：消息换成带引用的新消息，按新消息重新认出剩下的几处（位置变了），已经填的名字、用途、账号按值保留。
    public mutating func didSave(
        _ id: Entry.ID, savedName: String, message newMessage: String, secrets: [DetectedSecret],
        takenNames: [String], uniqueName: (String, [String]) -> String
    ) {
        savedNames.append(savedName)
        let previous = entries.filter { $0.id != id }
        message = newMessage
        entries = Self.makeEntries(
            secrets, takenNames: takenNames + savedNames, previous: previous, uniqueName: uniqueName)
        serverCount = nil
    }

    static func makeEntries(
        _ secrets: [DetectedSecret], takenNames: [String], previous: [Entry],
        uniqueName: (String, [String]) -> String
    ) -> [Entry] {
        var taken = takenNames
        var out: [Entry] = []
        for secret in secrets {
            if var old = previous.first(where: { $0.secret.value == secret.value }) {
                old.secret = secret
                old.isSaving = false
                taken.append(old.name)
                out.append(old)
                continue
            }
            let name = secret.isStorable ? uniqueName(secret.suggestedName, taken) : secret.suggestedName
            taken.append(name)
            out.append(Entry(secret: secret, name: name))
        }
        return out
    }
}

/// 保险箱条目名的问题（和服务端的条目名规则一致：小写字母、数字、`-`、`_`，1 到 64 个字符，字母或数字开头）。
public enum VaultNameProblem: Hashable, Sendable {
    case empty
    case tooLong
    /// 有规则外的字符（大写、空格、中文……）。
    case invalidCharacters

    public static let maxLength = 64

    public static func check(_ raw: String) -> VaultNameProblem? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return .empty }
        if name.count > maxLength { return .tooLong }
        let allowed = name.unicodeScalars.allSatisfy { s in
            (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x30 && s.value <= 0x39) || s == "-" || s == "_"
        }
        if !allowed { return .invalidCharacters }
        // 服务端（gateway 的 `valid_vault_name`）要求字母或数字开头。
        if name.hasPrefix("_") || name.hasPrefix("-") { return .invalidCharacters }
        return nil
    }
}
