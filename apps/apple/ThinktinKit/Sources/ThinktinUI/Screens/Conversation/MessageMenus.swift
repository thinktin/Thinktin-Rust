import SwiftUI
import ThinktinKit

#if os(iOS)
    import UIKit
#endif

/// 长按消息的系统菜单（规范 4.3.4，参考 06）：分组照 `MessageMenuLayout`（引用回复；复制、选择文本、复制运行 ID；分享；
/// 举报 / 再发一次）。参考的表情面板和“标为未读”不做（6.11），用系统的长按菜单，iOS 上带气泡形状的预览。
///
/// - 复制、分享：agent 写的末尾加“本内容由人工智能生成”的标识（`ConversationText.copyText`），用户自己写的原样。
/// - 选择文本：弹一张 sheet，里面是只读、能划选一部分的文字（iOS 上 `Text` 的 `textSelection` 只能整段复制，所以用
///   `UITextView`；macOS 的 `Text` 本来就能划选）。agent 写的下面带“AI 生成”标识。
/// - 复制运行 ID：报问题时用，复制后有成功的触感。
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
}

extension View {
    /// 给消息加长按菜单（和读屏的自定义操作：复制、引用回复、举报）。`previewShape` 是 iOS 长按预览的外形（气泡）。
    func messageMenu(_ content: MessageMenuContent, previewShape: some Shape = Rectangle()) -> some View {
        modifier(MessageMenuModifier(content: content, previewShape: previewShape))
    }
}

private struct MessageMenuModifier<PreviewShape: Shape>: ViewModifier {
    let content: MessageMenuContent
    let previewShape: PreviewShape

    @Environment(\.displayLanguage) private var language
    @State private var selection: SelectableMessage?
    @State private var copies = 0

    func body(content view: Content) -> some View {
        view
            .contextMenuPreviewShape(previewShape)
            .contextMenu {
                ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section, id: \.self) { action in
                            item(action)
                        }
                    }
                }
            }
            .accessibilityAction(named: Text(ConversationText.copy(language))) { copy() }
            .accessibilityAction(named: Text(ConversationText.quoteReply(language)), ifAvailable: quote)
            .accessibilityAction(named: Text(ConversationText.report(language)), ifAvailable: content.onReport)
            .sensoryFeedback(.success, trigger: copies)
            .sheet(item: $selection) { message in
                SelectTextSheet(message: message)
                    .environment(\.displayLanguage, language)
            }
    }

    /// 复制、分享出去的文字（agent 写的带标识）。
    private var labelledText: String {
        content.isAIGenerated ? ConversationText.copyText(content.text, language: language) : content.text
    }

    private var quote: (@MainActor () -> Void)? {
        guard let onQuote = content.onQuote, content.sections.joined().contains(.quote) else { return nil }
        let text = content.text
        return { onQuote(text) }
    }

    private func copy() {
        Pasteboard.copy(labelledText)
    }

    @ViewBuilder
    private func item(_ action: MessageMenuAction) -> some View {
        let label = Label(action.title(language), systemImage: action.systemImage)
        switch action {
        case .quote:
            if let quote {
                Button(action: quote) { label }
            }
        case .copy:
            Button(action: copy) { label }
        case .selectText:
            Button {
                selection = SelectableMessage(text: content.text, isAIGenerated: content.isAIGenerated)
            } label: {
                label
            }
        case .copyRunID:
            if let runID = content.runID {
                Button {
                    Pasteboard.copy(runID.rawValue)
                    copies += 1
                } label: {
                    label
                }
            }
        case .share:
            ShareLink(item: labelledText) { label }
        case .sendAgain:
            if let onSendAgain = content.onSendAgain {
                Button(action: onSendAgain) { label }
            }
        case .report:
            if let onReport = content.onReport {
                Button(role: .destructive, action: onReport) { label }
            }
        }
    }
}

/// “选择文本”要显示的一段。
struct SelectableMessage: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let isAIGenerated: Bool
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

extension View {
    /// 长按菜单预览的形状：只有 iOS 有（macOS 的右键菜单没有预览，`.contextMenuPreview` 在 macOS 上不可用）。
    @ViewBuilder
    func contextMenuPreviewShape(_ shape: some Shape) -> some View {
        #if os(iOS)
            contentShape(.contextMenuPreview, shape)
        #else
            self
        #endif
    }
}

#Preview("选择文本 · 浅色中文") {
    SelectTextSheet(message: SelectableMessage(text: ConversationPreviewData.markdownSample, isAIGenerated: true))
        .previewShell()
}
