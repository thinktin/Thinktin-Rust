import Foundation

// 对话页的几个菜单和首次状态（规范 4.3.1、4.3.2、4.3.4，参考 03、06、118）：菜单里有哪些项、按什么顺序分组放在这里，
// 界面照着画（系统 `Menu` / `.contextMenu` 的 `Section`），顺序在 Linux 上测。

// MARK: - 右上“…”菜单（4.3.2）

/// 对话页右上“…”菜单的一项。
public enum ConversationMenuItem: Hashable, Sendable {
    /// 打开一个页面（Botin 资料）。
    case open(AppRoute)
    /// 在对话中查找（规范 4.3.3，`ConversationModel.beginFind()`）：输入框换成查找栏。
    case find
    /// 删除这个 Botin：先弹列出影响的确认页（`InstanceDeleteSheet`），二次确认后删。参考 03 没有删除，参考里别处也没有；
    /// 2026-11-07 用户定先放这里（单独一组、红字、放最后）。
    case deleteBotin

    /// 菜单上的字：页面的标题、“在对话中查找”。
    public func title(_ language: DisplayLanguage) -> String {
        switch self {
        case .open(let route): route.title(language)
        case .find: ConversationText.findInConversation(language)
        case .deleteBotin: ConversationText.deleteBotin(language)
        }
    }

    /// SF Symbols 的图标名。
    public var systemImage: String {
        switch self {
        case .open(.instance): "person.crop.circle"
        case .open: "chevron.right"
        case .find: "magnifyingglass"
        case .deleteBotin: "trash"
        }
    }

    /// 红字（系统菜单的 destructive）。
    public var isDestructive: Bool { self == .deleteBotin }
}

/// “…”菜单（参考 03 是一组三项：查看资料、在聊天中查找、分享为模板）：一组，Botin 资料、在对话中查找（4.3.3，`canFind`）；
/// 再单独一组“删除这个 Botin”（`canDelete`，参考里没有，用户 2026-11-07 定先放这里）。“分享为模板”不做（6.21）。以前 ThinkTin 自己加的计划、新建计划、产出物、模型路由一组和有任务在跑时的“停止当前任务”
/// 2026-11-06 照参考去掉了（用户要求删掉、参考里没有）：计划、产出物从 Botin 资料进，停止用输入框右边的停止按钮。
public enum ConversationMenu {
    public static func sections(
        instanceID: InstanceID, canFind: Bool = true, canDelete: Bool = true
    ) -> [[ConversationMenuItem]] {
        [[.open(.instance(instanceID))] + (canFind ? [.find] : [])] + (canDelete ? [[.deleteBotin]] : [])
    }
}

extension ConversationModel {
    /// 这一页“…”菜单的分组（Botin 还在、不是只看一次运行时才能查找、删除）。
    public var menuSections: [[ConversationMenuItem]] {
        let isWholeConversation = !isMissing && focusRunID == nil
        return ConversationMenu.sections(
            instanceID: instanceID, canFind: isWholeConversation, canDelete: isWholeConversation)
    }
}

// MARK: - 消息长按菜单（4.3.4）

/// 长按消息的一项（参考 06：回复、标为未读；复制、选择文本、复制请求 ID）。iPhone 上长按弹参考 06 的面板（上面两排表情回应，
/// 见 `MessageReactions`，下面是这些项分组的列表），Mac 上是右键菜单。
public enum MessageMenuAction: Hashable, Sendable, CaseIterable {
    /// 引用回复：记下原文，输入框上出现引用条（4.3.5，纯客户端）。
    case quote
    /// 标为未读（参考 06）：ThinkTin 没有未读（6.10，要服务端），点了弹“即将推出”。
    case markUnread
    /// 复制（agent 写的末尾加“AI 生成”标识）。
    case copy
    /// 选择文本：弹一张只读、可以划选一部分的文字（系统长按菜单只能整段复制）。
    case selectText
    /// 复制运行 ID（参考的“复制请求 ID”，报问题时用）。
    case copyRunID
    /// 系统分享（带标识）。
    case share
    /// 再发一次（用户自己发的、已经结束的运行）。
    case sendAgain
    /// 举报（5.5，破坏性的、放最后）。
    case report

    public func title(_ language: DisplayLanguage) -> String {
        switch self {
        case .quote: ConversationText.quoteReply(language)
        case .markUnread: ConversationText.markUnread(language)
        case .copy: ConversationText.copy(language)
        case .selectText: ConversationText.selectText(language)
        case .copyRunID: ConversationText.copyRunID(language)
        case .share: ConversationText.share(language)
        case .sendAgain: ConversationText.sendAgain(language)
        case .report: ConversationText.report(language)
        }
    }

    public var systemImage: String {
        switch self {
        case .quote: "arrowshape.turn.up.left"
        case .markUnread: "message.badge"
        case .copy: "doc.on.doc"
        case .selectText: "character.cursor.ibeam"
        case .copyRunID: "number"
        case .share: "square.and.arrow.up"
        case .sendAgain: "arrow.clockwise"
        case .report: "flag"
        }
    }

    public var isDestructive: Bool { self == .report }

    /// 现在点了只弹“即将推出”（要服务端的）。
    public var isComingSoon: Bool { self == .markUnread }
}

/// 长按菜单的分组：第一组 引用回复、标为未读（agent 写的，有输入框时；参考 06）；第二组 复制、选择文本、复制运行 ID
/// （有运行时）；然后 agent 写的是 分享、再一组 举报，用户的是 再发一次。空组不出现。
public enum MessageMenuLayout {
    /// agent 写的（回复、思考、待办、没有过程记录的运行结果）。
    public static func agentOutput(canQuote: Bool, hasRunID: Bool, canReport: Bool) -> [[MessageMenuAction]] {
        compact([
            canQuote ? [.quote, .markUnread] : [],
            [.copy, .selectText] + (hasRunID ? [.copyRunID] : []),
            [.share],
            canReport ? [.report] : [],
        ])
    }

    /// 用户消息（运行的任务）。
    public static func userMessage(canQuote: Bool, hasRunID: Bool, canSendAgain: Bool) -> [[MessageMenuAction]] {
        compact([
            canQuote ? [.quote] : [],
            [.copy, .selectText] + (hasRunID ? [.copyRunID] : []),
            canSendAgain ? [.sendAgain] : [],
        ])
    }

    private static func compact(_ sections: [[MessageMenuAction]]) -> [[MessageMenuAction]] {
        sections.filter { !$0.isEmpty }
    }
}

// MARK: - 第一次进来（参考 118，6.18 A）

/// 还没有任务的对话顶上那张卡片（参考 118 的欢迎 + 选择卡；ThinkTin 没有欢迎消息，客户端自己画，6.18 A）。
public enum ConversationStarter: Hashable, Sendable {
    /// 还没配默认模型（`main` 路由）：卡片引导去配，没配之前任务会停在“等待 key”。
    case needsSetup
    /// 配好了：几个示例任务，点一个放进输入框（用户改一改再发）。
    case suggestions
}

extension ConversationModel {
    /// 顶上那张卡片：对话加载过、还没有任务、Botin 还在、不是“只看本次过程”时才有；默认模型还没拉到时先不出
    /// （免得先出示例、再换成“去配置”）。
    public var starter: ConversationStarter? {
        guard focusRunID == nil, hasLoaded, isEmpty, !isMissing else { return nil }
        switch mainRoute {
        case .missing: return .needsSetup
        case .configured: return .suggestions
        case .unknown: return nil
        }
    }

    /// 点了示例任务：放进输入框（换掉原来的字），用户再点发送。
    public func useSuggestion(_ text: String) {
        draft = text
    }
}
