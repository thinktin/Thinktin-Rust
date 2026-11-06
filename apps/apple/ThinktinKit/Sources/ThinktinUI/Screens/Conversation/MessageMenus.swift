import SwiftUI
import ThinktinKit

#if os(iOS)
    import UIKit
#endif

/// 长按消息（规范 4.3.4，参考 06、90）：分组照 `MessageMenuLayout`（引用回复、标为未读；复制、选择文本、复制运行 ID；分享；
/// 举报 / 再发一次）。
///
/// - iPhone、iPad：长按弹参考 06 的面板（`MessageActionSheet`，中号起、带拖动条）：上面两排圆形的表情（点了回应，第二排最后
///   “更多表情”换成参考 90 的完整选择器 `EmojiPickerView`、面板拉到全高），下面是分组的操作列表。系统的长按菜单放不下表情，
///   规范 4.3.4 说的“真要做表情时长按改成 sheet”就是这个。面板关掉以后再做要弹别的东西的操作（引用回复聚焦输入框、选择文本、
///   举报、再发一次），复制当场做。
/// - Mac：右键菜单（同样的分组），多一组“回应”子菜单（常用的 11 个 + “更多表情…”弹选择器）。
/// - 表情回应只记在这台设备上（`MessageReactionStore`），画在气泡下面（`ReactionChips`）；`reactions` 为 nil 的（思考、待办）
///   没有表情。
/// - 复制、分享：agent 写的末尾加“本内容由人工智能生成”的标识（`ConversationText.copyText`），用户自己写的原样。
/// - 选择文本：弹一张 sheet，里面是只读、能划选一部分的文字（iOS 上 `Text` 的 `textSelection` 只能整段复制，所以用
///   `UITextView`；macOS 的 `Text` 本来就能划选）。agent 写的下面带“AI 生成”标识。
/// - 复制运行 ID：报问题时用，复制后有成功的触感。“标为未读”要服务端，点了弹“即将推出”。
struct MessageMenuContent {
    /// 菜单里显示和复制的原文（agent 的回复是 Markdown 原文）。
    let text: String
    /// 是不是 agent 写的（复制、分享带标识，选择文本的 sheet 下面带标识）。
    let isAIGenerated: Bool
    let runID: RunID?
    let sections: [[MessageMenuAction]]
    var onQuote: (@MainActor (String) -> Void)?
    var onSendAgain: (@MainActor () -> Void)?
    var onReport: (@MainActor () -> Void)?
    /// 这条消息已有的表情回应（先点的在前）；nil 是这条不能回应（思考、待办、只读的地方）。
    var reactions: [String]? = nil
    /// 点了一个表情（加上或去掉）。
    var onReact: (@MainActor (String) -> Void)? = nil

    /// 面板上有没有表情那两排。
    var canReact: Bool { reactions != nil && onReact != nil }

    /// 复制、分享出去的文字（agent 写的带标识）。
    func labelledText(_ language: DisplayLanguage) -> String {
        isAIGenerated ? ConversationText.copyText(text, language: language) : text
    }

    /// 带上表情回应。
    func reacting(_ reactions: [String], onReact: (@MainActor (String) -> Void)?) -> Self {
        var copy = self
        copy.reactions = onReact == nil ? nil : reactions
        copy.onReact = onReact
        return copy
    }
}

extension View {
    /// 给消息加长按（iOS 是参考 06 的面板，Mac 是右键菜单）和读屏的自定义操作（复制、引用回复、回应、举报）。
    /// 没有预览外形：iOS 弹面板，Mac 的右键菜单没有预览。
    func messageMenu(_ content: MessageMenuContent) -> some View {
        modifier(MessageMenuModifier(content: content))
    }
}

/// 长按以后弹的东西：参考 06 的面板、选择文本、Mac 上单独的表情选择器。
enum MessageSheet: Identifiable, Hashable {
    case actions
    case selectText(SelectableMessage)
    case emoji

    var id: String {
        switch self {
        case .actions: "actions"
        case .selectText(let message): "select-\(message.id)"
        case .emoji: "emoji"
        }
    }
}

private struct MessageMenuModifier: ViewModifier {
    let content: MessageMenuContent

    @Environment(\.displayLanguage) private var language
    @State private var sheet: MessageSheet?
    /// 面板关掉以后要做的操作。
    @State private var pending: MessageMenuAction?
    @State private var copies = 0
    @State private var presses = 0
    @State private var showsComingSoon = false

    func body(content view: Content) -> some View {
        menu(view)
            .accessibilityAction(named: Text(ConversationText.copy(language))) { copy() }
            .accessibilityAction(named: Text(ConversationText.quoteReply(language)), ifAvailable: quote)
            .accessibilityAction(named: Text(ConversationText.react(language)), ifAvailable: react)
            .accessibilityAction(named: Text(ConversationText.report(language)), ifAvailable: content.onReport)
            .appFeedback(.success, trigger: copies)
            .appFeedback(.impact(weight: .medium), trigger: presses)
            .sheet(item: $sheet, onDismiss: performPending) { sheet in
                switch sheet {
                case .actions:
                    MessageActionSheet(content: content, pending: $pending)
                        .environment(\.displayLanguage, language)
                case .selectText(let message):
                    SelectTextSheet(message: message)
                        .environment(\.displayLanguage, language)
                case .emoji:
                    EmojiPickerSheet(selected: content.reactions ?? []) { emoji in
                        content.onReact?(emoji)
                    }
                    .environment(\.displayLanguage, language)
                }
            }
            .alert(ConversationText.comingSoon(language), isPresented: $showsComingSoon) {
                Button(ConversationText.ok(language)) {}
            } message: {
                Text(ConversationText.markUnreadComingSoon(language))
            }
    }

    /// iOS 长按弹面板；Mac 右键菜单。
    @ViewBuilder
    private func menu(_ view: Content) -> some View {
        #if os(iOS)
            view
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.4) {
                    presses += 1
                    sheet = .actions
                }
        #else
            view.contextMenu {
                ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section, id: \.self) { action in
                            item(action)
                        }
                    }
                }
                if let onReact = content.onReact, content.reactions != nil {
                    Section {
                        Menu(ConversationText.react(language)) {
                            ForEach(MessageReactions.quick, id: \.self) { emoji in
                                Button(emoji) { onReact(emoji) }
                            }
                            Button(ConversationText.moreEmoji(language) + "…") { sheet = .emoji }
                        }
                    }
                }
            }
        #endif
    }

    private var quote: (@MainActor () -> Void)? {
        guard let onQuote = content.onQuote, content.sections.joined().contains(.quote) else { return nil }
        let text = content.text
        return { onQuote(text) }
    }

    /// 读屏的“回应”：iOS 打开面板，Mac 打开表情选择器。
    private var react: (@MainActor () -> Void)? {
        guard content.canReact else { return nil }
        return {
            #if os(iOS)
                sheet = .actions
            #else
                sheet = .emoji
            #endif
        }
    }

    private func copy() {
        Pasteboard.copy(content.labelledText(language))
    }

    /// 面板关掉以后：做用户点的那一项（要弹别的东西的必须等面板关掉）。
    private func performPending() {
        guard let action = pending else { return }
        pending = nil
        perform(action)
    }

    private func perform(_ action: MessageMenuAction) {
        switch action {
        case .quote: quote?()
        case .markUnread: showsComingSoon = true
        case .copy: copy()
        case .selectText:
            sheet = .selectText(SelectableMessage(text: content.text, isAIGenerated: content.isAIGenerated))
        case .copyRunID:
            if let runID = content.runID {
                Pasteboard.copy(runID.rawValue)
                copies += 1
            }
        case .share: break  // 分享是面板里的 `ShareLink`，不经过这里。
        case .sendAgain: content.onSendAgain?()
        case .report: content.onReport?()
        }
    }

    /// Mac 右键菜单里的一项。
    @ViewBuilder
    private func item(_ action: MessageMenuAction) -> some View {
        let label = Label(action.title(language), systemImage: action.systemImage)
        switch action {
        case .share:
            ShareLink(item: content.labelledText(language)) { label }
        case .quote where quote == nil, .sendAgain where content.onSendAgain == nil,
            .report where content.onReport == nil, .copyRunID where content.runID == nil:
            EmptyView()
        default:
            Button(role: action.isDestructive ? .destructive : nil) {
                perform(action)
            } label: {
                label
            }
        }
    }
}

/// “选择文本”要显示的一段。
struct SelectableMessage: Identifiable, Hashable {
    let id: UUID
    let text: String
    let isAIGenerated: Bool

    init(text: String, isAIGenerated: Bool) {
        self.id = UUID()
        self.text = text
        self.isAIGenerated = isAIGenerated
    }
}

/// “选择文本”的 sheet：只读、能划选一部分、能用系统菜单复制；中号起、能拉到全屏，左上关闭。
struct SelectTextSheet: View {
    let message: SelectableMessage

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                SelectableText(text: message.text)
                if message.isAIGenerated {
                    AIGeneratedLabel()
                        .padding(.horizontal, Metrics.Spacing.m)
                        .padding(.bottom, Metrics.Spacing.s)
                }
            }
            .background(Theme.paper)
            .inlineNavigationTitle(ConversationText.selectText(language))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#if os(iOS)
    /// 只读、可以划选的系统文本视图（跟着动态字体）。
    private struct SelectableText: UIViewRepresentable {
        let text: String

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.isEditable = false
            view.isSelectable = true
            view.isScrollEnabled = true
            view.alwaysBounceVertical = true
            view.backgroundColor = .clear
            view.textColor = .label
            view.font = UIFont.preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.textContainerInset = UIEdgeInsets(
                top: Metrics.Spacing.m, left: Metrics.Spacing.s, bottom: Metrics.Spacing.m, right: Metrics.Spacing.s)
            view.text = text
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            if view.text != text { view.text = text }
        }
    }
#else
    /// macOS 的 `Text` 本来就能划选一部分。
    private struct SelectableText: View {
        let text: String

        var body: some View {
            ScrollView {
                Text(verbatim: text)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.Spacing.m)
            }
        }
    }
#endif

#Preview("选择文本 · 浅色中文") {
    SelectTextSheet(message: SelectableMessage(text: ConversationPreviewData.markdownSample, isAIGenerated: true))
        .previewShell()
}
