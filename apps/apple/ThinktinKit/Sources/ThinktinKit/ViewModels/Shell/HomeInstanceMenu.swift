import Foundation

/// 首页一个 Botin 的长按菜单、左滑按钮里的一项（规范 docs/ios-ui-redesign.md 4.2.2，参考 32、33、110、112）。
public enum HomeInstanceMenuItem: Hashable, Sendable {
    /// Botin 资料（`.instance(id)`）。
    case profile
    /// 置顶 / 取消置顶（只存这台设备，`InstancePreferencesStore`）。
    case pin
    case unpin
    /// 新建计划（`.newPlan(instanceID:)`，sheet）。
    case newPlan
    /// 改名（系统弹窗 + 输入框，`InstanceNameRule` 校验）。
    case rename
    /// 隐藏（首页不显示，只存这台设备）。
    case hide
    /// 复制 Botin 的 id（复制后有成功的触感）。
    case copyID
    /// 删除（先列出影响的确认页 `InstanceDeleteSheet`，再二次确认）。
    case delete

    public func title(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .profile: return AppRoute.instance("").title(language)
        case .pin: return zh ? "置顶" : "Pin"
        case .unpin: return zh ? "取消置顶" : "Unpin"
        case .newPlan: return AppRoute.newPlan(instanceID: nil).title(language)
        // 点了还要输入（弹窗），按系统菜单的习惯带省略号。
        case .rename: return zh ? "改名…" : "Rename…"
        case .hide: return zh ? "隐藏" : "Hide"
        case .copyID: return InstanceProfileText.copyID(language)
        case .delete: return InstanceProfileText.delete(language)
        }
    }

    /// SF Symbols 的图标名。
    public var systemImage: String {
        switch self {
        case .profile: "info.circle"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .newPlan: "calendar.badge.plus"
        case .rename: "pencil"
        case .hide: "eye.slash"
        case .copyID: "doc.on.doc"
        case .delete: "trash"
        }
    }

    /// 破坏性的（系统标红）：隐藏、删除。
    public var isDestructive: Bool { self == .hide || self == .delete }

    /// 要联网才能做的（离线时灰掉）：新建计划、改名、删除。置顶、隐藏、复制 id、看资料（有缓存）离线也行。
    public var needsConnection: Bool {
        switch self {
        case .newPlan, .rename, .delete: true
        case .profile, .pin, .unpin, .hide, .copyID: false
        }
    }

    /// 打开页面的项去哪；别的为 nil（界面自己处理）。
    public func route(for instanceID: InstanceID) -> AppRoute? {
        switch self {
        case .profile: .instance(instanceID)
        case .newPlan: .newPlan(instanceID: instanceID)
        case .pin, .unpin, .rename, .hide, .copyID, .delete: nil
        }
    }
}

/// 首页一个 Botin 的长按菜单和左滑按钮（参考 32、33、110、112）。
///
/// 长按是参考那样一列、不分组，最后一项“更多”在原地展开：参考的“标为未读”“新建分组”“替换主 Bot…”“分享为模板”
/// ThinkTin 没有（6.10、6.21），那几个位置换成 Botin 资料、新建计划、改名；置顶和隐藏的位置不变。
public enum HomeInstanceMenu {
    /// 长按菜单的一列（“更多”之前）。
    public static func items(isPinned: Bool) -> [HomeInstanceMenuItem] {
        [.profile, isPinned ? .unpin : .pin, .newPlan, .rename, .hide]
    }

    /// “更多”里的：复制 ID、删除。
    public static let more: [HomeInstanceMenuItem] = [.copyID, .delete]

    /// 左滑露出来的两个圆按钮（参考 110）：置顶 / 取消置顶、隐藏（红色）；从右往左数，隐藏在最右边。
    public static func swipeItems(isPinned: Bool) -> [HomeInstanceMenuItem] {
        [.hide, isPinned ? .unpin : .pin]
    }

    /// “更多”这一项的字。
    public static func moreTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "更多" : "More"
    }
}

/// 首页置顶、隐藏、改名的字（参考 113–116 的版式，字是 ThinkTin 自己的）。
extension HomeText {
    /// 全部隐藏时的空状态（参考 113）。
    public static func allHiddenTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "所有 Botin 都已隐藏" : "All Botins are hidden"
    }

    public static func showHidden(_ language: DisplayLanguage) -> String {
        language == .chinese ? "显示已隐藏的 Botin" : "Show Hidden Botins"
    }

    /// 首页列表最底下的入口（部分隐藏时；参考没有这一行，全部隐藏前找不到入口）。
    public static func hiddenCount(_ count: Int, language: DisplayLanguage) -> String {
        language == .chinese ? "已隐藏 \(count) 个 Botin" : (count == 1 ? "1 hidden Botin" : "\(count) hidden Botins")
    }

    /// 已隐藏的 Botin 页（参考 114、116）。
    public static func hiddenTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "已隐藏的 Botin" : "Hidden Botins"
    }

    public static func unhide(_ language: DisplayLanguage) -> String {
        language == .chinese ? "取消隐藏" : "Unhide"
    }

    public static func hiddenEmpty(_ language: DisplayLanguage) -> String {
        language == .chinese ? "没有隐藏的 Botin" : "No hidden Botins"
    }

    /// 已隐藏页右上“?”的读屏标签，也是说明 sheet 的标题（参考 115）。
    public static func aboutHiding(_ language: DisplayLanguage) -> String {
        language == .chinese ? "关于隐藏" : "About Hiding"
    }

    /// 说明 sheet 的三行：写 ThinkTin 真实的行为（隐藏只在这台设备上、计划照常跑、审批和通知照常来）。
    public static func hidingFacts(_ language: DisplayLanguage) -> [HidingFact] {
        let zh = language == .chinese
        return [
            HidingFact(
                systemImage: "checkmark.circle",
                title: zh ? "照常干活" : "Keeps working",
                detail: zh
                    ? "隐藏的 Botin 照常接任务、跑计划，审批和通知也照常发给你。"
                    : "A hidden Botin still takes tasks and runs its plans, and you still get its approvals and notifications."
            ),
            HidingFact(
                systemImage: "eye.slash",
                title: zh ? "只是首页不显示" : "Just off the home list",
                detail: zh
                    ? "不会删掉任何东西：对话、计划和产出物都在，搜索也找得到它。只在这台设备上隐藏。"
                    : "Nothing is deleted: chats, plans and artifacts all stay, and search still finds it. "
                        + "It's hidden on this device only."),
            HidingFact(
                systemImage: "arrow.uturn.backward",
                title: zh ? "随时放回来" : "Bring it back anytime",
                detail: zh
                    ? "在这一页点它旁边的“取消隐藏”，它就回到首页。"
                    : "Tap Unhide next to it on this page and it goes back to the home list."),
        ]
    }

    /// 你发的任务在行里的前缀（参考的行只有消息，ThinkTin 分得清是谁说的）。
    public static func youPrefix(_ language: DisplayLanguage) -> String {
        language == .chinese ? "你：" : "You: "
    }

    /// 改名弹窗（参考 68 的版式：标题、输入框、取消 / 保存）。
    public static func renameTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "给 Botin 改名" : "Rename Botin"
    }

    public static func renameSave(_ language: DisplayLanguage) -> String {
        language == .chinese ? "保存" : "Save"
    }

    public static func renameFailed(_ language: DisplayLanguage) -> String {
        language == .chinese ? "没改成" : "Couldn't Rename"
    }

    /// 复制 id 之后读屏念的一句。
    public static func copiedID(_ language: DisplayLanguage) -> String {
        language == .chinese ? "已复制 Botin ID" : "Botin ID copied"
    }
}

/// 隐藏说明里的一行：图标、标题、多行说明。
public struct HidingFact: Hashable, Sendable, Identifiable {
    public var systemImage: String
    public var title: String
    public var detail: String

    public var id: String { systemImage }

    public init(systemImage: String, title: String, detail: String) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
    }
}
