import SwiftUI
import ThinktinKit

/// 用户消息（运行的任务，取自 `Run.prompt`）：靠右的浅色圆角卡片，不渲染 Markdown。委派的任务是负责人 agent 写的、
/// 流水线步骤附了上游摘要，带“AI 生成”标识（`AIGeneratedField.prompt(of:)`）。很长的任务先折起来。
///
/// 长按：复制（agent 写的任务带标识）、再发一次（用户自己发的、已经结束的运行，`onSendAgain` 不为 nil 时）。
struct UserMessageView: View {
    let message: UserMessage
    let isAIGenerated: Bool
    var onSendAgain: (@MainActor () -> Void)? = nil

    @Environment(\.displayLanguage) private var language
    @State private var isExpanded = false

    /// 超过这么多字先折起来。
    static let collapseThreshold = 600

    var body: some View {
        let long = message.text.count > Self.collapseThreshold
        VStack(alignment: .trailing, spacing: Metrics.Spacing.xxs) {
            HStack(spacing: 0) {
                Spacer(minLength: Metrics.Spacing.xxxl)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    Text(verbatim: message.text)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(long && !isExpanded ? 12 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if long {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Text(
                                isExpanded
                                    ? (language == .chinese ? "收起" : "Show less")
                                    : (language == .chinese ? "展开全文" : "Show more")
                            )
                            .typography(.footnote)
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metrics.Spacing.m)
                .padding(.vertical, Metrics.Spacing.s)
                .background(
                    Theme.userBubble, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                )
                .contextMenuPreviewShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
                .contextMenu {
                    Button {
                        Pasteboard.copy(copiedText)
                    } label: {
                        Label(ConversationText.copy(language), systemImage: "doc.on.doc")
                    }
                    if let onSendAgain {
                        Button(action: onSendAgain) {
                            Label(ConversationText.sendAgain(language), systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            if isAIGenerated { AIGeneratedLabel() }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAction(named: Text(ConversationText.copy(language))) {
            Pasteboard.copy(copiedText)
        }
        .accessibilityAction(named: Text(ConversationText.sendAgain(language)), ifAvailable: onSendAgain)
    }

    /// 复制出去的文字：agent 写的任务（委派、流水线步骤）末尾加标识，用户自己写的原样。
    private var copiedText: String {
        isAIGenerated ? ConversationText.copyText(message.text, language: language) : message.text
    }

    /// 读屏：“你：任务”“负责人 agent 委派的任务：……”。
    private var accessibilityText: String {
        let author = ConversationText.promptAuthor(message.source, language: language)
        return author + (language == .chinese ? "：" : ": ") + message.text
    }
}

/// agent 的回复：不带气泡，块级 Markdown，下面是“AI 生成”标识（还在输出时旁边转圈）。长按：复制、分享（都带标识）、举报。
struct AssistantTextView: View {
    let item: ConversationItem
    let text: AssistantText
    let blocks: [MarkdownBlockItem]
    let onReport: (ContentReportTarget) -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            MarkdownView(blocks: blocks)
            HStack(spacing: Metrics.Spacing.xs) {
                if text.isAIGenerated { AIGeneratedLabel() }
                if text.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(ConversationText.streaming(language)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            MessageMenu(text: text.text, target: ContentReportTarget(item: item), onReport: onReport)
        }
        .messageAccessibilityActions(text: text.text, target: ContentReportTarget(item: item), onReport: onReport)
    }
}

/// agent 的思考过程：默认折起来，标题栏上一直有“AI 生成”标识。
struct ThoughtView: View {
    let item: ConversationItem
    let thought: Thought
    let onReport: (ContentReportTarget) -> Void

    @Environment(\.displayLanguage) private var language
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Metrics.Spacing.xs) {
                    Image(systemName: "lightbulb")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(ConversationText.thinkingTitle(streaming: thought.isStreaming, language: language))
                        .typography(.subheadline)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    if thought.isAIGenerated { AIGeneratedLabel() }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.inkSecondary)
                .frame(minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                Text(isExpanded ? ConversationText.hideDetails(language) : ConversationText.showDetails(language)))
            if isExpanded {
                HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                    Capsule()
                        .fill(Theme.hairline)
                        .frame(width: 2)
                        .accessibilityHidden(true)
                    Text(verbatim: thought.text)
                        .typography(.callout)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
                .contextMenu {
                    MessageMenu(text: thought.text, target: ContentReportTarget(item: item), onReport: onReport)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 长按 agent 输出的菜单：复制、分享（末尾都加“本内容由人工智能生成”的标识）、举报。
struct MessageMenu: View {
    let text: String
    let target: ContentReportTarget?
    let onReport: (ContentReportTarget) -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let labelled = ConversationText.copyText(text, language: language)
        Button {
            Pasteboard.copy(labelled)
        } label: {
            Label(ConversationText.copy(language), systemImage: "doc.on.doc")
        }
        ShareLink(item: labelled) {
            Label(ConversationText.share(language), systemImage: "square.and.arrow.up")
        }
        if let target {
            Button(role: .destructive) {
                onReport(target)
            } label: {
                Label(ConversationText.report(language), systemImage: "flag")
            }
        }
    }
}

extension View {
    /// 读屏的自定义操作：复制（带标识）、举报（长按菜单读屏用户不好找）。
    func messageAccessibilityActions(
        text: String, target: ContentReportTarget?, onReport: @escaping (ContentReportTarget) -> Void
    ) -> some View {
        modifier(MessageAccessibilityActions(text: text, target: target, onReport: onReport))
    }
}

private struct MessageAccessibilityActions: ViewModifier {
    let text: String
    let target: ContentReportTarget?
    let onReport: (ContentReportTarget) -> Void

    @Environment(\.displayLanguage) private var language

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text(ConversationText.copy(language))) {
                Pasteboard.copy(ConversationText.copyText(text, language: language))
            }
            .accessibilityAction(named: Text(ConversationText.report(language)), ifAvailable: report)
    }

    /// 能举报时的操作。
    private var report: (@MainActor () -> Void)? {
        guard let target else { return nil }
        let onReport = self.onReport
        return { onReport(target) }
    }
}

extension View {
    /// 有 `action` 时才加这个读屏的自定义操作（没有时不出现在操作列表里）。
    @ViewBuilder
    func accessibilityAction(named name: Text, ifAvailable action: (@MainActor () -> Void)?) -> some View {
        if let action {
            accessibilityAction(named: name) { action() }
        } else {
            self
        }
    }
}

#Preview("消息 · 浅色中文") {
    ScrollView {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xl) {
            UserMessageView(message: UserMessage(text: "帮我把这周的周报整理成要点，按项目分组。"), isAIGenerated: false)
            AssistantTextView(
                item: ConversationItem(
                    id: "seq-1", runID: DemoData.weeklyRunID, createdAt: Date(),
                    content: .assistantText(AssistantText(text: ConversationPreviewData.markdownSample))),
                text: AssistantText(text: ConversationPreviewData.markdownSample, isStreaming: true),
                blocks: MarkdownParser.parse(ConversationPreviewData.markdownSample), onReport: { _ in })
            ThoughtView(
                item: ConversationItem(
                    id: "seq-2", runID: DemoData.weeklyRunID, createdAt: Date(),
                    content: .thought(Thought(text: "先看看工作区里的周报草稿。"))),
                thought: Thought(text: "先看看工作区里的周报草稿。"), onReport: { _ in })
        }
        .padding()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .chinese)
}

#Preview("消息 · 深色英文") {
    ScrollView {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xl) {
            UserMessageView(
                message: UserMessage(text: "Write the release notes for 0.4.0.", source: .delegate), isAIGenerated: true
            )
            ThoughtView(
                item: ConversationItem(
                    id: "seq-2", runID: DemoData.weeklyRunID, createdAt: Date(),
                    content: .thought(Thought(text: "Check the changelog first."))),
                thought: Thought(text: "Check the changelog first.", isStreaming: true), onReport: { _ in })
        }
        .padding()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}

extension View {
    /// 长按菜单预览的形状：只有 iOS 有（macOS 的右键菜单没有预览，`.contextMenuPreview` 在 macOS 上不可用）。
    @ViewBuilder
    fileprivate func contextMenuPreviewShape(_ shape: some Shape) -> some View {
        #if os(iOS)
            contentShape(.contextMenuPreview, shape)
        #else
            self
        #endif
    }
}
