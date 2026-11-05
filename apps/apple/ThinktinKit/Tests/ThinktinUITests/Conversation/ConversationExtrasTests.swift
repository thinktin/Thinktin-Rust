import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 第 2 轮·对话页的附加功能（规范 4.3.3–4.3.6、4.4.5）：对话内查找的查找栏和高亮。视图模型的逻辑在 ThinktinKitTests 的
/// `ConversationFindTests` 里测。
@MainActor
@Suite("对话页的附加功能")
struct ConversationExtrasTests {
    @Test("查找栏能布局：有匹配、没匹配（红字 0）、浅色中文和深色英文")
    func findBar() {
        hostAndLayout(ConversationFindBarDemo().previewShell())
        hostAndLayout(ConversationFindBarDemo(query: "没有这几个字").previewShell(.english, scheme: .dark))
        hostAndLayout(ConversationFindBarDemo().previewShell().dynamicTypeSize(.accessibility3))
    }

    @Test("高亮：每一处都有底色，当前这一处是实心底、白字；没有高亮时原样")
    func highlighter() {
        let plain = AttributedString("周报和周报，周报")
        let result = FindHighlighter.apply(plain, FindSegmentHighlight(query: "周报", current: 1))
        let marked = result.runs.filter { $0.backgroundColor != nil }
        #expect(marked.count == 3)
        #expect(marked.filter { $0.foregroundColor == Theme.onAccent }.count == 1)
        #expect(String(result.characters) == "周报和周报，周报")
        #expect(FindHighlighter.apply(plain, nil) == plain)
        #expect(FindHighlighter.apply(plain, FindSegmentHighlight(query: "")) == plain)
    }

    @Test("Markdown 每块的第一段序号：标题一段、列表一项一段、分隔线没有")
    func blockBases() {
        let blocks = MarkdownParser.parse("# 标题\n\n- 一\n- 二\n\n---\n\n段落")
        let highlight = ConversationFindHighlight(query: "一", currentSegment: 1, currentOccurrence: 0)
        let bases = BlockFindHighlight.blocks(blocks, highlight)
        #expect(blocks.map { bases[$0.id]?.base } == [0, 1, 3, 3])
        #expect(bases[blocks[1].id]?.segment(0).current == 0)
        #expect(bases[blocks[1].id]?.segment(1).current == nil)
        #expect(BlockFindHighlight.blocks(blocks, nil).isEmpty)
        // 高亮变了，块要重画（`MarkdownBlockView` 的相等比较带上高亮）。
        let block = blocks[1]
        #expect(MarkdownBlockView(item: block) != MarkdownBlockView(item: block, highlight: bases[block.id]))
        #expect(MarkdownBlockView(item: block) == MarkdownBlockView(item: block))
    }

    @Test("输入框左边的“+”：传了几项才有，不能输入时没有；胶囊和带引用的卡片都能出图（参考 08）")
    func attachments() {
        let sources = ComposerAttachmentSource.allCases
        let plain = ComposerBar(text: .constant(""), placeholder: "", action: .send {})
        #expect(!plain.showsAttachments)
        let withMenu = ComposerBar(
            text: .constant(""), placeholder: "", action: .send {}, attachments: sources, onAttach: { _ in })
        #expect(withMenu.showsAttachments)
        let disabled = ComposerBar(
            text: .constant(""), placeholder: "", action: .send {}, isDisabled: true, attachments: sources,
            onAttach: { _ in })
        #expect(!disabled.showsAttachments)
        #expect(
            !ComposerBar(text: .constant(""), placeholder: "", action: .send {}, attachments: [], onAttach: { _ in })
                .showsAttachments)
        renderInBothAppearances(withMenu)
        renderInBothAppearances(
            ComposerBar(
                text: .constant("接着做"), placeholder: "", action: .send {}, quote: "引用的一段",
                onRemoveQuote: {}, attachments: sources, onAttach: { _ in }))
        #if os(iOS)
            #expect(ConversationComposer.attachmentSources.contains(.camera))
        #else
            #expect(!ConversationComposer.attachmentSources.contains(.camera))
        #endif
    }

    @Test("长按面板（参考 06）、完整表情选择器（参考 90）、气泡下的回应能布局；没有回应的消息面板里没有表情")
    func reactions() {
        hostAndLayout(MessageActionSheetDemo().previewShell())
        hostAndLayout(MessageActionSheetDemo(reactions: nil).previewShell(.english, scheme: .dark))
        hostAndLayout(EmojiPickerView(selected: ["😂"], onBack: {}, onPick: { _ in }).previewShell())
        hostAndLayout(EmojiPickerSheet(selected: [], onPick: { _ in }).previewShell(.english, scheme: .dark))
        renderInBothAppearances(ReactionChips(reactions: ["👍", "🎉"], alignment: .leading, onToggle: { _ in }))
        renderInBothAppearances(ReactionChips(reactions: ["❤️"], alignment: .trailing, onToggle: nil))
        renderInBothAppearances(ReactionGrid(selected: ["👍"], onPick: { _ in }, onMore: {}))
        let base = MessageMenuContent(
            text: "回复", isAIGenerated: true, runID: nil,
            sections: MessageMenuLayout.agentOutput(canQuote: false, hasRunID: false, canReport: false))
        #expect(!base.canReact)
        #expect(base.reacting(["👍"], onReact: { _ in }).canReact)
        #expect(base.reacting(["👍"], onReact: { _ in }).reactions == ["👍"])
        #expect(!base.reacting(["👍"], onReact: nil).canReact)
        #expect(base.labelledText(.chinese).hasPrefix("回复") && base.labelledText(.chinese) != "回复")
        let sheets: [MessageSheet] = [
            .actions, .emoji, .selectText(SelectableMessage(text: "a", isAIGenerated: false)),
        ]
        #expect(Set(sheets.map(\.id)).count == 3)
        // 回复、用户消息、运行结果都能带回应出图。
        renderInBothAppearances(
            UserMessageView(
                message: UserMessage(text: "帮我整理周报"), isAIGenerated: false, reactions: ["👍"], onReact: { _ in }))
        let reply = ConversationItem(
            id: "seq-1", runID: DemoData.weeklyRunID, createdAt: Date(),
            content: .assistantText(AssistantText(text: "好的")))
        renderInBothAppearances(
            AssistantTextView(
                item: reply, text: AssistantText(text: "好的"), blocks: MarkdownParser.parse("好的"), onReport: { _ in },
                reactions: ["🎉", "❤️"], onReact: { _ in }))
    }

    @Test("选择主 Botin（参考 11）：有别的 Botin 时是单选列表，一个都没有时是空状态；路由交给对话的接入点")
    func primaryBotin() {
        hostAndLayout(
            NavigationStack { PrimaryBotinPickerScreen(store: PrimaryBotinStore(defaults: nil)) }.previewShell())
        hostAndLayout(
            NavigationStack { PrimaryBotinPickerScreen(store: PrimaryBotinStore(defaults: nil)) }
                .previewShell(.english, scheme: .dark, client: MockClient(state: DemoData.newAccountState())))
        hostAndLayout(ConversationDestination(route: .primaryBotin).previewShell())
        #expect(AppRoute.primaryBotin.feature == .conversation && AppRoute.primaryBotin.presentation == .sheet)
    }

    @Test("高亮的消息能出图：用户消息（引用和正文）、回复、结果")
    func highlightedMessages() {
        let quoted = MessageQuote.compose(quote: "上周的周报", body: "周报再分一下")
        renderInBothAppearances(
            UserMessageView(
                message: UserMessage(text: quoted), isAIGenerated: false,
                highlight: ConversationFindHighlight(query: "周报", currentSegment: 1, currentOccurrence: 0)))
        let blocks = MarkdownParser.parse(ConversationPreviewData.markdownSample)
        renderInBothAppearances(
            MarkdownView(blocks: blocks, highlight: ConversationFindHighlight(query: "e", currentSegment: 0)))
        renderInBothAppearances(
            HistoryRecordView(
                note: .expired, summary: "周报整理好了", runID: DemoData.weeklyRunID, onReport: { _ in },
                highlight: ConversationFindHighlight(query: "周报", currentSegment: 0, currentOccurrence: 0)))
    }
}
