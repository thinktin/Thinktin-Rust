import SwiftUI
import ThinktinKit

/// 消息气泡的外形：圆角 20（规范 2.4，参考 02）。
let messageBubbleShape = RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)

/// 气泡和对面留的空（参考 02 的气泡约占屏宽 80%）。
let messageBubbleGutter = Metrics.Spacing.xxxl

/// 用户消息（运行的任务，取自 `Run.prompt`）：靠右的 `userBubble` 气泡，不渲染 Markdown。开头是引用块的（引用回复，
/// `MessageQuote.split`）在气泡里先画一小块引用。委派的任务是负责人写的、流水线步骤附了上游摘要，带“AI 生成”标识
/// （`AIGeneratedField.prompt(of:)`）。很长的任务先折起来。
///
/// 长按（`MessageMenuLayout.userMessage`）：引用回复、复制（agent 写的任务带标识）、选择文本、复制运行 ID、
/// 再发一次（用户自己发的、已经结束的运行，`onSendAgain` 不为 nil 时）。
struct UserMessageView: View {
    let message: UserMessage
    let isAIGenerated: Bool
    var runID: RunID? = nil
    var onSendAgain: (@MainActor () -> Void)? = nil
    var onQuote: (@MainActor (String) -> Void)? = nil

    @Environment(\.displayLanguage) private var language
    @State private var isExpanded = false

    /// 超过这么多字先折起来。
    static let collapseThreshold = 600

    var body: some View {
        let long = message.text.count > Self.collapseThreshold
        let parts = MessageQuote.split(message.text)
        VStack(alignment: .trailing, spacing: Metrics.Spacing.xxs) {
            HStack(spacing: 0) {
                Spacer(minLength: messageBubbleGutter)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    if let quote = parts.quote {
                        QuotedBlock(quote: quote)
                    }
                    Text(verbatim: parts.body)
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
                .background(Theme.userBubble, in: messageBubbleShape)
                .messageMenu(menu, previewShape: messageBubbleShape)
            }
            if isAIGenerated { AIGeneratedLabel() }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAction(named: Text(ConversationText.sendAgain(language)), ifAvailable: onSendAgain)
    }

    private var menu: MessageMenuContent {
        MessageMenuContent(
            text: message.text, isAIGenerated: isAIGenerated, runID: runID,
            sections: MessageMenuLayout.userMessage(
                canQuote: onQuote != nil, hasRunID: runID != nil, canSendAgain: onSendAgain != nil),
            onQuote: onQuote, onSendAgain: onSendAgain)
    }

    /// 读屏：“你：任务”“负责人委派的任务：……”；引用回复念正文再念“引用：……”，不念“>”。
    private var accessibilityText: String {
        let author = ConversationText.promptAuthor(message.source, language: language)
        return author + (language == .chinese ? "：" : ": ") + MessageQuote.spoken(message.text, language: language)
    }
}

/// 用户消息里那一小块引用（引用回复发出去的 Markdown 引用块）：左边一道竖线、次要色的小字，最多 3 行。
struct QuotedBlock: View {
    let quote: String

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Spacing.xs) {
            Capsule()
                .fill(Theme.inkTertiary)
                .frame(width: 3)
                .accessibilityHidden(true)
            Text(verbatim: quote)
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ConversationText.quoteAccessibility(quote, language: language)))
    }
}

/// agent 的回复（规范 4.3.1、6.2 C，参考 02）：靠左的 `agentBubble` 灰气泡，块级 Markdown；气泡下面是“AI 生成”标识
/// （还在输出时旁边转圈）。长按（`MessageMenuLayout.agentOutput`）：引用回复、复制、选择文本、复制运行 ID、分享
/// （复制、分享都带标识）、举报。
struct AssistantTextView: View {
    let item: ConversationItem
    let text: AssistantText
    let blocks: [MarkdownBlockItem]
    let onReport: (ContentReportTarget) -> Void
    var onQuote: (@MainActor (String) -> Void)? = nil

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(spacing: 0) {
                MarkdownView(blocks: blocks)
                    .padding(.horizontal, Metrics.Spacing.m)
                    .padding(.vertical, Metrics.Spacing.s)
                    .background(Theme.agentBubble, in: messageBubbleShape)
                    .messageMenu(
                        .agentOutput(
                            text.text, runID: item.runID, target: ContentReportTarget(item: item), onReport: onReport,
                            onQuote: onQuote),
                        previewShape: messageBubbleShape)
                Spacer(minLength: messageBubbleGutter)
            }
            HStack(spacing: Metrics.Spacing.xs) {
                if text.isAIGenerated { AIGeneratedLabel() }
                if text.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(ConversationText.streaming(language)))
                }
            }
            .padding(.leading, Metrics.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// agent 的思考过程：默认折起来，标题栏上一直有“AI 生成”标识；展开后是左边一道竖线的小字（长按和回复一样）。
struct ThoughtView: View {
    let item: ConversationItem
    let thought: Thought
    let onReport: (ContentReportTarget) -> Void
    var onQuote: (@MainActor (String) -> Void)? = nil

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
            .padding(.leading, Metrics.Spacing.xs)
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
                .padding(.leading, Metrics.Spacing.xs)
                .padding(.trailing, messageBubbleGutter)
                .transition(.opacity)
                .messageMenu(
                    .agentOutput(
                        thought.text, runID: item.runID, target: ContentReportTarget(item: item), onReport: onReport,
                        onQuote: onQuote))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MessageMenuContent {
    /// agent 写的一段（回复、思考、待办、运行结果）：引用回复（有 `onQuote` 时）、复制、选择文本、复制运行 ID、分享、
    /// 举报（有举报对象时）。复制、分享带“AI 生成”标识。
    @MainActor
    static func agentOutput(
        _ text: String, runID: RunID?, target: ContentReportTarget?,
        onReport: @escaping (ContentReportTarget) -> Void, onQuote: (@MainActor (String) -> Void)? = nil
    ) -> MessageMenuContent {
        var report: (@MainActor () -> Void)?
        if let target { report = { onReport(target) } }
        return MessageMenuContent(
            text: text, isAIGenerated: true, runID: runID ?? target?.runID,
            sections: MessageMenuLayout.agentOutput(
                canQuote: onQuote != nil, hasRunID: (runID ?? target?.runID) != nil, canReport: report != nil),
            onQuote: onQuote, onReport: report)
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
            UserMessageView(
                message: UserMessage(text: "> 上周一共合并了 12 个提交，主要是事件流续传和缓存。\n\n按项目再分一下"),
                isAIGenerated: false)
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
