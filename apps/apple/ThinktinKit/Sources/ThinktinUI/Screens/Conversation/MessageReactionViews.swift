import SwiftUI
import ThinktinKit

/// 长按消息的面板（规范 4.3.4，参考 06）：中号起、带拖动条。上面两排圆形的表情（常用的 11 个 + “更多表情”，点过的是突出的
/// 圆），下面是分组的操作列表（`MessageMenuLayout`）。点“更多表情”原地换成参考 90 的完整选择器、面板拉到全高，左上的返回
/// 回到这里。点表情：加上或去掉回应、关掉面板。点操作：记下来、关掉面板，由外面在面板关掉以后做（`pending`）；分享是
/// `ShareLink`，“标为未读”弹“即将推出”。
struct MessageActionSheet: View {
    let content: MessageMenuContent
    /// 面板关掉以后要做的操作。
    @Binding var pending: MessageMenuAction?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayLanguage) private var language
    @State private var showsPicker = false
    @State private var detent: PresentationDetent = .medium
    @State private var showsComingSoon = false

    var body: some View {
        Group {
            if showsPicker {
                EmojiPickerView(
                    selected: content.reactions ?? [],
                    onBack: {
                        showsPicker = false
                        detent = .medium
                    },
                    onPick: react)
            } else {
                actions
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .alert(ConversationText.comingSoon(language), isPresented: $showsComingSoon) {
            Button(ConversationText.ok(language)) {}
        } message: {
            Text(ConversationText.markUnreadComingSoon(language))
        }
    }

    private var actions: some View {
        List {
            if content.canReact {
                Section {
                    ReactionGrid(
                        selected: content.reactions ?? [], onPick: react,
                        onMore: {
                            showsPicker = true
                            detent = .large
                        })
                }
                .clearListRow()
            }
            ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section, id: \.self) { action in
                        row(action)
                    }
                }
            }
        }
        .insetGroupedList()
        .scrollContentBackground(.hidden)
        .padding(.top, Metrics.Spacing.s)
    }

    @ViewBuilder
    private func row(_ action: MessageMenuAction) -> some View {
        let label = Label(action.title(language), systemImage: action.systemImage)
            .foregroundStyle(action.isDestructive ? Theme.danger : Theme.ink)
        switch action {
        case .share:
            ShareLink(item: content.labelledText(language)) { label }
        case .markUnread:
            Button {
                showsComingSoon = true
            } label: {
                label
            }
        default:
            Button(role: action.isDestructive ? .destructive : nil) {
                pending = action
                dismiss()
            } label: {
                label
            }
        }
    }

    private func react(_ emoji: String) {
        content.onReact?(emoji)
        dismiss()
    }
}

/// 面板上的两排表情（参考 06）：6 列的圆，点过的用突出的样式；最后一个是“更多表情”。
struct ReactionGrid: View {
    let selected: [String]
    let onPick: @MainActor (String) -> Void
    let onMore: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    static let columns = 6
    static let size: CGFloat = 44

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.Spacing.s), count: Self.columns),
            spacing: Metrics.Spacing.s
        ) {
            ForEach(MessageReactions.quick, id: \.self) { emoji in
                let isSelected = selected.contains(emoji)
                Button {
                    onPick(emoji)
                } label: {
                    Text(verbatim: emoji)
                        .font(Typography.title2.font)
                        .frame(width: Self.size - 12, height: Self.size - 12)
                }
                .glassButtonStyle(isSelected ? .prominent : .regular)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text(verbatim: emoji))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Button(action: onMore) {
                Label(ConversationText.moreEmoji(language), systemImage: "face.smiling")
                    .labelStyle(.iconOnly)
                    .font(Typography.title3.font)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Self.size - 12, height: Self.size - 12)
            }
            .glassButtonStyle(.regular)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.xs)
    }
}

/// 完整的表情选择器（参考 90）：顶上一行是返回（在面板里时）和“搜索表情”的胶囊，下面按分类排的 8 列表情，分类名是小灰字；
/// 搜了以后是一格一格的结果，没有结果是系统的“没有结果”。点过的表情底下垫一个浅强调色的圆。
struct EmojiPickerView: View {
    let selected: [String]
    /// 左上的返回（长按面板里）；nil 时不放（Mac 上单独弹的 sheet 有自己的关闭）。
    var onBack: (@MainActor () -> Void)? = nil
    let onPick: @MainActor (String) -> Void

    @Environment(\.displayLanguage) private var language
    @State private var query = ""

    static let columns = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Spacing.s) {
                if let onBack {
                    Button(action: onBack) {
                        Label(ConversationText.emojiBack(language), systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                            .font(Typography.body.font.weight(.semibold))
                            .frame(width: Metrics.minTapTarget - 16, height: Metrics.minTapTarget - 16)
                    }
                    .glassButtonStyle(.regular)
                    .buttonBorderShape(.circle)
                }
                searchField
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.top, Metrics.Spacing.l)
            .padding(.bottom, Metrics.Spacing.s)
            ScrollView {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Metrics.Spacing.xs) {
                        ForEach(EmojiCategory.allCases, id: \.self) { category in
                            Section {
                                ForEach(category.emoji, id: \.self) { emoji in
                                    cell(emoji)
                                }
                            } header: {
                                Text(category.title(language))
                                    .typography(.footnote)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, Metrics.Spacing.s)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.Spacing.m)
                } else {
                    let results = EmojiCatalog.search(query, language: language)
                    if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, Metrics.Spacing.xxl)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: Metrics.Spacing.xs) {
                            ForEach(results, id: \.self) { emoji in
                                cell(emoji)
                            }
                        }
                        .padding(.horizontal, Metrics.Spacing.m)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Metrics.Spacing.xxs), count: Self.columns)
    }

    private var searchField: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            TextField(
                ConversationText.searchEmoji(language), text: $query,
                prompt: Text(ConversationText.searchEmoji(language)).foregroundStyle(Theme.inkTertiary)
            )
            .textFieldStyle(.plain)
            .typography(.body)
            .autocorrectionDisabled()
            .submitLabel(.search)
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .frame(height: Metrics.minTapTarget)
        .frame(maxWidth: .infinity)
        .background(Theme.inkTertiary.opacity(0.14), in: Capsule())
    }

    private func cell(_ emoji: String) -> some View {
        let isSelected = selected.contains(emoji)
        return Button {
            onPick(emoji)
        } label: {
            Text(verbatim: emoji)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                .background {
                    if isSelected {
                        Circle().fill(Theme.accent.opacity(0.25))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: emoji))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 单独弹的表情选择器（Mac 右键菜单的“更多表情…”）：左上关闭，选了一个就关。
struct EmojiPickerSheet: View {
    let selected: [String]
    let onPick: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmojiPickerView(selected: selected) { emoji in
                onPick(emoji)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .presentationDetents([.large])
    }
}

/// 气泡下面的表情回应（只在这台设备上）：一个表情一个小玻璃胶囊，点了去掉；`alignment` 跟着气泡（用户的靠右）。
struct ReactionChips: View {
    let reactions: [String]
    let alignment: HorizontalAlignment
    let onToggle: (@MainActor (String) -> Void)?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        if !reactions.isEmpty {
            HStack(spacing: Metrics.Spacing.xxs) {
                if alignment == .trailing { Spacer(minLength: messageBubbleGutter) }
                ForEach(reactions, id: \.self) { emoji in
                    Button {
                        onToggle?(emoji)
                    } label: {
                        Text(verbatim: emoji)
                            .font(Typography.body.font)
                    }
                    .smallCapsuleButton()
                    .disabled(onToggle == nil)
                    .accessibilityLabel(Text(ConversationText.removeReaction(emoji, language: language)))
                }
                if alignment == .leading { Spacer(minLength: messageBubbleGutter) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityHint(Text(ConversationText.reactionsNote(language)))
        }
    }
}

/// 预览和测试用：一条回复的长按面板。
struct MessageActionSheetDemo: View {
    var reactions: [String]? = ["👍"]
    @State private var pending: MessageMenuAction?

    var body: some View {
        Color.clear.sheet(isPresented: .constant(true)) {
            MessageActionSheet(
                content: MessageMenuContent(
                    text: "这周的周报要点整理好了。", isAIGenerated: true, runID: DemoData.weeklyRunID,
                    sections: MessageMenuLayout.agentOutput(canQuote: true, hasRunID: true, canReport: true),
                    onQuote: { _ in }, onReport: {}, reactions: reactions, onReact: { _ in }),
                pending: $pending)
        }
    }
}

#Preview("长按面板 · 浅色中文") {
    MessageActionSheetDemo().previewShell()
}

#Preview("表情选择器 · 深色英文") {
    EmojiPickerView(selected: ["😂"], onBack: {}, onPick: { _ in })
        .background(Theme.paper)
        .previewShell(.english, scheme: .dark)
}

#Preview("气泡下的回应") {
    VStack(spacing: Metrics.Spacing.m) {
        ReactionChips(reactions: ["👍", "🎉"], alignment: .leading, onToggle: { _ in })
        ReactionChips(reactions: ["❤️"], alignment: .trailing, onToggle: { _ in })
    }
    .padding()
    .background(Theme.paper)
}
