import Foundation

/// 保险箱条目。没有密码；账号只在 `VaultItemDetail` 里有。
public struct VaultItem: Identifiable, Hashable, Codable, Sendable {
    public var id: VaultItemID
    /// 引用名（`github`），消息里写成 `[vault:github]`。
    public var name: String
    public var purpose: String
    public var hasUsername: Bool
    /// 能用它的实例；空表示全部。
    public var instanceIDs: [InstanceID]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: VaultItemID, name: String, purpose: String, hasUsername: Bool = false, instanceIDs: [InstanceID] = [],
        createdAt: Date, updatedAt: Date? = nil, lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.hasUsername = hasUsername
        self.instanceIDs = instanceIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// 消息里的引用：`[vault:github]`。
    public var reference: String { Self.reference(for: name) }

    public static func reference(for name: String) -> String { "[vault:\(name)]" }

    /// 所有实例都能用。
    public var isAvailableToAllInstances: Bool { instanceIDs.isEmpty }
}

/// 条目详情：多一个账号。
public struct VaultItemDetail: Identifiable, Hashable, Codable, Sendable {
    public var item: VaultItem
    public var username: String

    public var id: VaultItemID { item.id }

    public init(item: VaultItem, username: String) {
        self.item = item
        self.username = username
    }
}

/// 新建保险箱条目。描述里不打印账号密码。
public struct NewVaultItem: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var name: String
    public var purpose: String
    public var username: String
    public var password: String
    /// 空表示所有实例都能用。
    public var instanceIDs: [InstanceID]

    public init(name: String, purpose: String, username: String = "", password: String, instanceIDs: [InstanceID] = [])
    {
        self.name = name
        self.purpose = purpose
        self.username = username
        self.password = password
        self.instanceIDs = instanceIDs
    }

    public var description: String { "NewVaultItem(name: \(name))" }
    public var debugDescription: String { description }
}

/// 修改条目：只改给了的字段。
public struct VaultItemUpdate: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var purpose: String?
    public var username: String?
    public var password: String?
    public var instanceIDs: [InstanceID]?

    public init(
        purpose: String? = nil, username: String? = nil, password: String? = nil, instanceIDs: [InstanceID]? = nil
    ) {
        self.purpose = purpose
        self.username = username
        self.password = password
        self.instanceIDs = instanceIDs
    }

    public var description: String {
        "VaultItemUpdate(purpose: \(purpose ?? "-"), passwordChanged: \(password != nil))"
    }
    public var debugDescription: String { description }
}

/// agent 请用户填的表单（9.11）。
public struct VaultRequest: Identifiable, Hashable, Codable, Sendable {
    public var id: VaultRequestID
    public var instanceID: InstanceID
    public var runID: RunID?
    /// 建议的条目名。
    public var name: String
    /// agent 写的用途：显示时带“AI 生成”标识。
    public var purpose: String
    /// 要填的字段。
    public var fields: [VaultField]
    public var status: VaultRequestStatus
    /// 填好后存成的条目。
    public var itemID: VaultItemID?
    public var createdAt: Date
    public var expiresAt: Date
    public var resolvedAt: Date?

    public init(
        id: VaultRequestID, instanceID: InstanceID, runID: RunID? = nil, name: String, purpose: String,
        fields: [VaultField] = [.username, .password], status: VaultRequestStatus = .pending,
        itemID: VaultItemID? = nil, createdAt: Date, expiresAt: Date, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.instanceID = instanceID
        self.runID = runID
        self.name = name
        self.purpose = purpose
        self.fields = fields
        self.status = status
        self.itemID = itemID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.resolvedAt = resolvedAt
    }

    public var needsUsername: Bool { fields.contains(.username) }
}

/// 消息里一处像密码、key 的内容（11.6）。
public struct DetectedSecret: Identifiable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var kind: SecretKind
    /// 在原文里的位置：UTF-16 下标（和 `NSRange` 一致），左闭右开。
    public var utf16Range: Range<Int>
    /// 原文里的那段，预填进表单的密码栏。
    public var value: String
    /// 建议的条目名（已经符合命名规则）。
    public var suggestedName: String
    /// 认出来的厂商或服务（anthropic、github……）。
    public var service: String
    /// 能存进保险箱。私钥这种多行的不能，只提示别发。
    public var isStorable: Bool

    public var id: Int { utf16Range.lowerBound }

    public init(
        kind: SecretKind, utf16Range: Range<Int>, value: String, suggestedName: String, service: String = "",
        isStorable: Bool = true
    ) {
        self.kind = kind
        self.utf16Range = utf16Range
        self.value = value
        self.suggestedName = suggestedName
        self.service = service
        self.isStorable = isStorable
    }

    /// 在 `text` 里的范围（`text` 必须是检查时的那段原文）。
    public func range(in text: String) -> Range<String.Index>? {
        let utf16 = text.utf16
        guard utf16Range.lowerBound >= 0, utf16Range.upperBound <= utf16.count,
            let start = utf16.index(utf16.startIndex, offsetBy: utf16Range.lowerBound, limitedBy: utf16.endIndex),
            let end = utf16.index(utf16.startIndex, offsetBy: utf16Range.upperBound, limitedBy: utf16.endIndex),
            let lower = start.samePosition(in: text), let upper = end.samePosition(in: text)
        else { return nil }
        return lower..<upper
    }

    public var description: String { "DetectedSecret(kind: \(kind), range: \(utf16Range), name: \(suggestedName))" }
    public var debugDescription: String { description }
}

/// 把消息里的值换成引用时用：`value` 换成 `[vault:name]`。
public struct SecretReference: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var value: String
    public var name: String

    public init(value: String, name: String) {
        self.value = value
        self.name = name
    }

    public var description: String { "SecretReference(name: \(name))" }
    public var debugDescription: String { description }
}

/// 从消息里存进保险箱的结果：条目和换成引用后的消息（直接放回输入框）。
public struct SavedSecret: Hashable, Sendable {
    public var item: VaultItem
    public var message: String

    public init(item: VaultItem, message: String) {
        self.item = item
        self.message = message
    }
}
