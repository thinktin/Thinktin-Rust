import Foundation

/// 设置里还没有后端的操作（规范 4.9.4、4.9.7、4.9.8、4.9.9、4.9.10、6.15、6.16、6.20）：点了弹系统的“即将推出”提示，
/// 说明为什么现在做不了。页面照参考排好了，等服务端有接口再把这里的一项换成真操作。
public enum SettingsComingSoon: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// 权限页的“自动审查”开关（参考 62）。
    case autoReview
    /// 新建、保存规则（参考 63、64、100）。
    case saveRule
    /// 删除规则（参考 64）。
    case deleteRule
    /// 订阅一个方案（参考 56）。
    case subscribe
    /// 恢复购买（参考 56）。
    case restorePurchases
    /// 导入记忆的“添加到记忆”（参考 71）。
    case importMemory
    /// 登录设备改名（参考 68）。
    case renameDevice
    /// 保存卡片（参考 60、94–96）。
    case saveCard
    /// 扫描卡片（参考 60 右上的相机）。
    case scanCard
    /// 保存联系信息（参考 61、97、98）。
    case saveContact

    public var id: String { rawValue }

    /// 提示的正文：做不了的原因和现在的状态。
    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .autoReview, .saveRule, .deleteRule:
            return zh
                ? "按规则自动审查 Botin 的操作要等服务端支持。现在列的是示例规则，改动不会保存；Botin 要做有风险的操作时照样先请你审批。"
                : "Reviewing Botin actions against your rules needs server support. These are example rules and changes "
                    + "aren't saved; Botins still ask for your approval before anything risky."
        case .subscribe, .restorePurchases:
            return zh
                ? "App 内订阅还没有开放，方案和价格以上线时为准。" : "In-app subscriptions aren't available yet. Plans and prices will be announced at launch."
        case .importMemory:
            return zh
                ? "把记忆写进 Botin 要等服务端支持。粘贴的内容不会离开这台设备。"
                : "Adding memories to a Botin needs server support. What you pasted stays on this device."
        case .renameDevice:
            return zh ? "给登录设备改名要等服务端支持。" : "Renaming devices needs server support."
        case .saveCard:
            return zh
                ? "保险箱暂时只能存登录信息。存卡片要先做好“Botin 看不到完整卡号”的代填，卡片不会保存。"
                : "The vault only holds sign-ins for now. Cards need secure autofill that keeps the full number from "
                    + "Botins first, so this card won't be saved."
        case .scanCard:
            return zh ? "扫描卡片跟着卡片一起推出。" : "Card scanning arrives together with cards."
        case .saveContact:
            return zh
                ? "保险箱暂时只能存登录信息，联系信息不会保存。" : "The vault only holds sign-ins for now, so this contact won't be saved."
        }
    }
}

/// “即将推出”提示和几页共用的按钮文案。
public enum SettingsExtrasText {
    /// 提示的标题。
    public static func comingSoonTitle(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "即将推出" : "Coming soon"
    }

    /// 提示里唯一的按钮。
    public static func ok(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "好" : "OK"
    }

    /// 底部全宽按钮下面的“取消”（参考 63、64）。
    public static func cancel(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "取消" : "Cancel"
    }

    /// 表单里“可选”的占位。
    public static func optional(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "可选" : "Optional"
    }

    /// 选择器里的“无”（参考 77 的第一项）。
    public static func none(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "无" : "None"
    }

    /// 复制以后按钮上换成的字。
    public static func copied(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "已复制" : "Copied"
    }

    /// 还能用的 Botin（选择器的选项）：去掉已删除的，按名字排。
    public static func pickableInstances(_ instances: [Instance]) -> [Instance] {
        instances
            .filter { $0.state != .deleted }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id.rawValue < rhs.id.rawValue : order == .orderedAscending
            }
    }
}
