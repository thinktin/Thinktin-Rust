import Foundation
import Observation

// 主 Botin（规范 4.4.5、6.10，参考 10 的“替换主 Bot…”、11 的“选择主 Bot”）：用户指定一个 Botin 当“主”的——新任务、快捷指令、
// 小组件不知道交给谁时默认交给它。服务端没有这个字段（6.10 建议“本机存就行”），所以**只记在这台设备上**
// （`PrimaryBotinStore`，`UserDefaults` 一个键）。入口是 Botin 资料右上“…”菜单的“替换主 Botin…”（`AppRoute.primaryBotin`，
// sheet）。新任务那页（`NewTaskSheet`）、快捷指令默认选它还没接（那几页归别的线，见 docs/progress/r2-conversation.md）。

/// 这台设备上记的主 Botin。
@Observable @MainActor
public final class PrimaryBotinStore {
    static let storageKey = "cn.thinktin.conversation.primaryBotin"

    /// 整个 App 共用的一份（存在 `UserDefaults.standard`）。
    public static let shared = PrimaryBotinStore()

    /// 主 Botin 的 id；没选过为 nil。
    public private(set) var primaryID: InstanceID?

    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults` 为 nil 时只记在内存里（测试、预览）。
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let stored = defaults?.string(forKey: Self.storageKey) ?? ""
        self.primaryID = stored.isEmpty ? nil : InstanceID(stored)
    }

    /// 换成这个 Botin（nil 是不要主 Botin）。
    public func set(_ id: InstanceID?) {
        guard id != primaryID else { return }
        primaryID = id
        if let id {
            defaults?.set(id.rawValue, forKey: Self.storageKey)
        } else {
            defaults?.removeObject(forKey: Self.storageKey)
        }
    }

    /// 主 Botin 删掉了：清掉（`BotinLocalData.forget(_:)`）。
    public func forget(instanceID: InstanceID) {
        if primaryID == instanceID { set(nil) }
    }

    /// 在这些 Botin 里，主 Botin 是哪个（删掉了、不在列表里的不算）。
    public func primary(in instances: [Instance]) -> Instance? {
        guard let primaryID else { return nil }
        return instances.first { $0.id == primaryID && $0.state != .deleted }
    }
}

/// “选择主 Botin”页（参考 11）：列出别的 Botin（现在的主 Botin 不列、删掉的不列），按名字搜，单选，右上“确认”。
public enum PrimaryBotinPicker {
    /// 能选的：去掉现在的主 Botin 和删掉的，按名字搜（不分大小写、全角半角），按名字排。
    public static func candidates(_ instances: [Instance], primaryID: InstanceID?, query: String) -> [Instance] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return
            instances
            .filter { $0.id != primaryID && $0.state != .deleted }
            .filter { q.isEmpty || $0.name.range(of: q, options: ConversationFind.options) != nil }
            .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
    }

    /// 一个都没有（不算搜索）：显示“暂无其他可选的 Botin”。
    public static func hasNoOthers(_ instances: [Instance], primaryID: InstanceID?) -> Bool {
        candidates(instances, primaryID: primaryID, query: "").isEmpty
    }

    /// “确认”能不能点：选了一个，而且不是现在的主 Botin。
    public static func canConfirm(selection: InstanceID?, primaryID: InstanceID?) -> Bool {
        selection != nil && selection != primaryID
    }
}

extension ConversationText {
    /// Botin 资料“…”菜单里的一项（参考 10 的“替换主 Bot…”）：没有主 Botin 时是“设为…”。
    public static func replacePrimaryBotin(hasPrimary: Bool, language: DisplayLanguage) -> String {
        switch (language, hasPrimary) {
        case (.chinese, true): "替换主 Botin…"
        case (.chinese, false): "设置主 Botin…"
        case (.english, true): "Replace Main Botin…"
        case (.english, false): "Set Main Botin…"
        }
    }

    /// 没有别的 Botin 可选（参考 11）。
    public static func noOtherBotins(_ language: DisplayLanguage) -> String {
        language == .chinese ? "暂无其他可选的 Botin" : "No other Botins to choose"
    }

    /// 底部的搜索框。
    public static func searchBotins(_ language: DisplayLanguage) -> String {
        language == .chinese ? "搜索 Botin" : "Search Botins"
    }

    /// 右上的确认。
    public static func confirm(_ language: DisplayLanguage) -> String {
        language == .chinese ? "确认" : "Confirm"
    }

    /// 列表下面的说明。
    public static func primaryBotinNote(current: String?, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        let head =
            current.map { zh ? "现在的主 Botin 是 \($0)。" : "Your main Botin is \($0). " } ?? ""
        return head
            + (zh
                ? "新任务、快捷指令不知道交给谁时默认交给主 Botin。只记在这台设备上。"
                : "New tasks and shortcuts go to the main Botin when no Botin is chosen. Saved on this device only.")
    }
}
