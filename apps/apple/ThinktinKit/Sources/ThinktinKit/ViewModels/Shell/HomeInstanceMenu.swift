import Foundation

/// 首页一个 Botin 的长按菜单、左滑按钮里的一项（规范 docs/ios-ui-redesign.md 4.2.2，参考 32、33、110、112）。
public enum HomeInstanceMenuItem: Hashable, Sendable {
    /// 置顶 / 取消置顶（只存这台设备，`InstancePreferencesStore`）。
    case pin
    case unpin
    /// 替换主 Botin…（参考 32 的“替换主 Bot…”）：打开选择主 Botin 的 sheet（`.primaryBotin`，参考 11）。
    case replacePrimary
    /// 隐藏（首页不显示，只存这台设备）。
    case hide
    /// 复制 Botin 的 id（复制后有成功的触感）。
    case copyID

    public func title(_ language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch self {
        case .pin: return zh ? "置顶" : "Pin"
        case .unpin: return zh ? "取消置顶" : "Unpin"
        // 和资料页“…”里的那一项一个字（参考 10、32 都是“替换主 Bot…”）。
        case .replacePrimary: return ConversationText.replacePrimaryBotin(hasPrimary: true, language: language)
        case .hide: return zh ? "隐藏" : "Hide"
        case .copyID: return InstanceProfileText.copyID(language)
        }
    }

    /// SF Symbols 的图标名。
    public var systemImage: String {
        switch self {
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .replacePrimary: "arrow.left.arrow.right"
        case .hide: "eye.slash"
        case .copyID: "doc.on.doc"
        }
    }

    /// 破坏性的（系统标红）：隐藏（参考 32 里隐藏是红的）。
    public var isDestructive: Bool { self == .hide }

    /// 打开页面的项去哪；别的为 nil（界面自己处理）。
    public var route: AppRoute? {
        switch self {
        case .replacePrimary: .primaryBotin
        case .pin, .unpin, .hide, .copyID: nil
        }
    }
}

/// 首页一个 Botin 的长按菜单和左滑按钮（参考 32、33、110、112）。
///
/// 长按是参考那样一列、不分组，最后一项“更多”在原地展开（参考 33：只有复制 ID）。参考的“标为未读”“新建分组”
/// “分享为模板”ThinkTin 没有（6.10、6.21），那几个位置空着，别的照参考的顺序。以前 ThinkTin 自己加的 Botin 资料、
/// 新建计划、改名…和“更多”里的删除 2026-11-06 照参考去掉了（用户要求删掉、参考里没有）：资料从对话页标题进，
/// 改名在资料页的编辑里，删除 Botin 现在没有入口（规范 1.5）。都是本机的操作，离线也能用。
public enum HomeInstanceMenu {
    /// 长按菜单的一列（“更多”之前）：置顶 / 取消置顶、替换主 Botin…、隐藏。
    public static func items(isPinned: Bool) -> [HomeInstanceMenuItem] {
        [isPinned ? .unpin : .pin, .replacePrimary, .hide]
    }

    /// “更多”里的：复制 ID（参考 33）。
    public static let more: [HomeInstanceMenuItem] = [.copyID]

    /// 左滑露出来的两个圆按钮（参考 110）：置顶 / 取消置顶、隐藏（红色）；从右往左数，隐藏在最右边。
    public static func swipeItems(isPinned: Bool) -> [HomeInstanceMenuItem] {
        [.hide, isPinned ? .unpin : .pin]
    }

    /// “更多”这一项的字。
    public static func moreTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "更多" : "More"
    }
}

/// 首页置顶、隐藏的字（参考 113–116 的版式，字是 ThinkTin 自己的）。
extension HomeText {
    /// 全部隐藏时的空状态（参考 113）。
    /// 都隐藏了的首页（参考 113 的版式，文案是 ThinkTin 自己的，和“关于隐藏”的“随时放回来”一个口气）。
    public static func allHiddenTitle(_ language: DisplayLanguage) -> String {
        language == .chinese ? "Botin 都藏起来了" : "Your Botins are all tucked away"
    }

    public static func showHidden(_ language: DisplayLanguage) -> String {
        language == .chinese ? "查看藏起来的 Botin" : "See Hidden Botins"
    }

    /// 已隐藏的 Botin 页（参考 114、116）。
    public static func hiddenTitle(_ language: DisplayLanguage) -> String {
        AppRoute.hiddenBotins.title(language)
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
