import Foundation

/// 保险箱的规则（WBS 12.13）：和服务端 gateway `routes/vault.rs` 一样，本地先拦下，省一次来回。
public enum VaultRules {
    /// 每个用户最多存几条。
    public static let maxItems = 200
    /// 用途最多几个字（按 Unicode 标量数，和服务端的 `chars().count()` 一样）。
    public static let maxPurpose = 200
    public static let maxUsername = 256
    /// 比这短的密码没法可靠地从对话和日志里抹掉（服务端的 `MIN_PASSWORD_LEN`）。
    public static let minPassword = 4
    public static let maxPasswordBytes = 4096
    /// 一条最多限定给几个实例。
    public static let maxInstances = 50

    public enum PasswordProblem: Hashable, Sendable {
        case tooShort, tooLong, controlCharacters
    }

    public static func passwordProblem(_ password: String) -> PasswordProblem? {
        if password.unicodeScalars.count < minPassword { return .tooShort }
        if password.utf8.count > maxPasswordBytes { return .tooLong }
        if hasControlCharacters(password) { return .controlCharacters }
        return nil
    }

    /// 有控制字符（换行、制表符这些；服务端的 `char::is_control`）。
    public static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

/// 新建、修改条目的表单问题（点保存后标出来）。
public enum VaultFormProblem: Hashable, Sendable {
    case name(VaultNameProblem)
    case purposeTooLong
    case usernameTooLong
    /// 用途、账号里有控制字符（换行等）。
    case controlCharacters
    case password(VaultRules.PasswordProblem)
    /// 限定给实例，但一个都没选。
    case noInstances
    case tooManyInstances
    /// 已经存满 200 条（新建时）。
    case full
}

/// 保险箱的文案（WBS 12.13）。条目、请求共用的几句在 `ConversationText` 里（对话里的填写卡片也用）。
public enum VaultText {
    public static func intro(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "agent 要登录网站时用这里的账号密码：消息里写 [vault:名字]，agent 只拿到名字，看不到明文，用之前要你批准。"
            : "Agents sign in to sites with the accounts saved here. Write [vault:name] in a message: the agent only "
                + "gets the name, never the password, and needs your approval to use it."
    }

    public static func count(_ count: Int, language: DisplayLanguage) -> String {
        language == .chinese
            ? "\(count) / \(VaultRules.maxItems) 条" : "\(count) of \(VaultRules.maxItems) items"
    }

    public static func full(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "保险箱满了（最多 \(VaultRules.maxItems) 条），删掉不用的才能再加。"
            : "Your vault is full (\(VaultRules.maxItems) items). Delete ones you don't use to add more."
    }

    public static func instances(_ item: VaultItem, names: [InstanceID: String], language: DisplayLanguage) -> String {
        let zh = language == .chinese
        if item.isAvailableToAllInstances { return zh ? "所有实例都能用" : "All instances" }
        let known = item.instanceIDs.map { names[$0] ?? (zh ? "已删除的实例" : "Deleted instance") }
        return (zh ? "只给：" : "Only: ") + known.joined(separator: zh ? "、" : ", ")
    }

    public static func formProblem(_ problem: VaultFormProblem, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch problem {
        case .name(let name): return ConversationText.vaultNameProblem(name, language: language)
        case .purposeTooLong:
            return zh ? "用途最多 \(VaultRules.maxPurpose) 个字" : "Use \(VaultRules.maxPurpose) characters or fewer"
        case .usernameTooLong:
            return zh ? "账号最多 \(VaultRules.maxUsername) 个字" : "Use \(VaultRules.maxUsername) characters or fewer"
        case .controlCharacters: return zh ? "不能有换行、制表符" : "No line breaks or tabs"
        case .password(.tooShort):
            return zh ? "密码至少 \(VaultRules.minPassword) 个字符" : "Use at least \(VaultRules.minPassword) characters"
        case .password(.tooLong): return zh ? "密码太长了" : "That password is too long"
        case .password(.controlCharacters): return zh ? "密码里不能有换行、制表符" : "No line breaks or tabs in the password"
        case .noInstances: return zh ? "至少选一个实例，或者改成所有实例都能用" : "Pick at least one instance, or allow all"
        case .tooManyInstances:
            return zh ? "最多选 \(VaultRules.maxInstances) 个实例" : "Pick up to \(VaultRules.maxInstances) instances"
        case .full: return full(language)
        }
    }

    public static func renamed(_ name: String, language: DisplayLanguage) -> String {
        language == .chinese
            ? "已经有叫这个名字的条目了，换成了“\(name)”。可以再改，保存就用新名字。"
            : "That name is taken, so it's now “\(name)”. Change it if you like, then save."
    }

    public static func requestReplaces(_ name: String, language: DisplayLanguage) -> String {
        language == .chinese
            ? "保险箱里已经有“\(name)”了：填好后会换掉它的账号密码。"
            : "Your vault already has “\(name)”. Saving replaces its username and password."
    }

    public static func requestExpires(_ date: Date, now: Date, language: DisplayLanguage) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if language == .chinese {
            return minutes < 60 ? "\(minutes) 分钟后过期" : "\(minutes / 60) 小时后过期"
        }
        return minutes < 60 ? "Expires in \(minutes) min" : "Expires in \(minutes / 60) h"
    }

    public static func passwordKept(_ language: DisplayLanguage) -> String {
        language == .chinese ? "不填就不改密码" : "Leave empty to keep the current password"
    }
}
