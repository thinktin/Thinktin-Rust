import SwiftUI
import ThinktinKit

/// agent 回复的 Markdown（块级由 `MarkdownParser` 解析，行内的加粗、斜体、行内代码、链接交给
/// `AttributedString(markdown:)` 的 inline 模式）。一块一个视图、按块的 id 排：流式追加时前面的块不变（`Equatable`），
/// 通常只有最后一块重新排版。
///
/// 不用系统的文字选择（`.textSelection`）：系统复制带不上“AI 生成”标识，复制走消息的菜单（`ConversationText.copyText`）。
/// 链接点了怎么办由外面的 `conversationLinkHandling(_:)` 管（agent 写的链接只放行网址、邮件和 App 自己的深链）。
///
/// 对话内查找（规范 4.3.3）时 `highlight` 不为 nil：每块按自己的段（`MarkdownBlock.findSegments`）把找到的字标上底色。
struct MarkdownView: View {
    let blocks: [MarkdownBlockItem]
    var highlight: ConversationFindHighlight? = nil

    var body: some View {
        let highlights = BlockFindHighlight.blocks(blocks, highlight)
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            ForEach(blocks) { item in
                MarkdownBlockView(item: item, highlight: highlights[item.id]).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一块。
struct MarkdownBlockView: View, Equatable {
    let item: MarkdownBlockItem
    var highlight: BlockFindHighlight? = nil

    nonisolated static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.item == rhs.item && lhs.highlight == rhs.highlight
    }

    var body: some View {
        switch item.block {
        case .heading(let level, let text):
            InlineText(text: text, highlight: highlight?.segment(0))
                .font(Self.headingFont(level))
                .foregroundStyle(Theme.ink)
                .padding(.top, level <= 2 ? Metrics.Spacing.xs : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            InlineText(text: text, highlight: highlight?.segment(0))
                .typography(.body)
                .foregroundStyle(Theme.ink)
        case .list(let list):
            MarkdownListView(list: list, highlight: highlight)
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code, highlight: highlight?.segment(0))
        case .quote(let text):
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                Capsule()
                    .fill(Theme.hairline)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                InlineText(text: text, highlight: highlight?.segment(0))
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            MarkdownTableView(table: table, highlight: highlight)
        case .rule:
            HairlineRule()
                .padding(.vertical, Metrics.Spacing.xxs)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: Typography.title2.font
        case 2: Typography.title3.font
        default: Typography.headline.font
        }
    }
}

extension View {
    /// agent 内容里的链接（`ConversationLinks`）：`thinktin://` 的深链在 App 里打开（`Router.openLink(_:)`：压在眼前这一层上，
    /// 返回还是对话或运行详情；不用 `handle(url:)`，那个是从外面进来的、会重建返回栈），网址、邮件交给系统，
    /// 别的（打电话、别的 App 的 scheme、`javascript:`）不打开。
    @MainActor
    func conversationLinkHandling(_ router: Router) -> some View {
        environment(
            \.openURL,
            OpenURLAction { url in
                switch ConversationLinks.handling(of: url) {
                case .inApp: router.openLink(url) ? .handled : .discarded
                case .external: .systemAction
                case .blocked: .discarded
                }
            })
    }
}

/// 一像素的分隔线（`hairline` 色）。
struct HairlineRule: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Metrics.hairline(scale: displayScale))
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// 一段带行内格式的文字（`**加粗**`、`*斜体*`、`` `代码` ``、`[链接](…)`，保留换行）。解析失败按原文显示。
/// 对话内查找时把找到的字标上底色（`FindHighlighter`）。
struct InlineText: View {
    let text: String
    var highlight: FindSegmentHighlight? = nil

    var body: some View {
        Text(FindHighlighter.apply(Self.attributed(text), highlight))
            .fixedSize(horizontal: false, vertical: true)
            .tint(Theme.accent)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// 画出来的字（去掉了行内标记）：对话内查找按它算位置（`ConversationFind.plainText`）。
    static func plainText(_ text: String) -> String {
        String(attributed(text).characters)
    }
}

/// 列表：每项前面是圆点、序号或勾选框，嵌套的往里缩。
struct MarkdownListView: View {
    let list: MarkdownList
    /// 一项一段。
    var highlight: BlockFindHighlight? = nil

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                    marker(item)
                        .frame(minWidth: Metrics.Spacing.m, alignment: .trailing)
                    InlineText(text: item.text, highlight: highlight?.segment(index))
                        .typography(.body)
                        .foregroundStyle(item.checked == true ? Theme.inkSecondary : Theme.ink)
                }
                .padding(.leading, CGFloat(item.level) * Metrics.Spacing.l)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownList.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square" : "square")
                .typography(.body)
                .foregroundStyle(checked ? Theme.success : Theme.inkSecondary)
                .accessibilityLabel(
                    Text(
                        checked
                            ? (language == .chinese ? "已完成" : "Done") : (language == .chinese ? "未完成" : "Not done")))
        } else if let number = item.number {
            Text(verbatim: "\(number).")
                .typography(.body)
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        } else {
            Text(verbatim: item.level == 0 ? "•" : "◦")
                .typography(.body)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
        }
    }
}

/// 代码块：等宽字体、横向可以滚，右上角“复制代码”（带 AI 生成标识的文字）。
struct CodeBlockView: View {
    let language: String?
    let code: String
    var highlight: FindSegmentHighlight? = nil

    @Environment(\.displayLanguage) private var displayLanguage
    @Environment(\.displayScale) private var displayScale
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.Spacing.xs) {
                Text(verbatim: language ?? "code")
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
                Button {
                    Pasteboard.copy(ConversationText.copyText(code, language: displayLanguage))
                    copied = true
                } label: {
                    Label(
                        copied ? ConversationText.copied(displayLanguage) : ConversationText.copyCode(displayLanguage),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Metrics.Spacing.s)
            ScrollView(.horizontal, showsIndicators: false) {
                // 气泡给正文加的行距（`messageBubbleLineSpacing`）代码不跟：照等宽字体自己的行高排。
                FindHighlighter.text(code, highlight)
                    .font(Typography.footnote.monospacedFont)
                    .lineSpacing(0)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, Metrics.Spacing.s)
                    .padding(.bottom, Metrics.Spacing.s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.userBubble.opacity(0.6), in: shape)
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
        .onChange(of: code) { copied = false }
    }
}

/// 表格：网格，横向可以滚；读屏按“表头 | 表头”一行一行读（`MarkdownTable.plainText`）。
struct MarkdownTableView: View {
    let table: MarkdownTable
    /// 先表头、再一行一行，每格一段（补齐到列数）。
    var highlight: BlockFindHighlight? = nil

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: Metrics.Spacing.m, verticalSpacing: Metrics.Spacing.xs) {
                GridRow {
                    ForEach(Array(cells(table.header).enumerated()), id: \.offset) { column, cell in
                        InlineText(text: cell, highlight: highlight?.segment(column))
                            .font(Typography.subheadline.font.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }
                HairlineRule()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(cells(row).enumerated()), id: \.offset) { column, cell in
                            InlineText(
                                text: cell,
                                highlight: highlight?.segment((rowIndex + 1) * table.columnCount + column)
                            )
                            .typography(.subheadline)
                            .foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            .padding(Metrics.Spacing.s)
        }
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: table.plainText))
    }

    /// 补齐到列数（有的行格子少）。
    private func cells(_ row: [String]) -> [String] {
        row + Array(repeating: "", count: max(0, table.columnCount - row.count))
    }
}

#Preview("Markdown · 浅色中文") {
    ScrollView {
        MarkdownView(blocks: MarkdownParser.parse(ConversationPreviewData.markdownSample))
            .padding()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .chinese)
}

#Preview("Markdown · 深色英文") {
    ScrollView {
        MarkdownView(blocks: MarkdownParser.parse(ConversationPreviewData.markdownSample))
            .padding()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
