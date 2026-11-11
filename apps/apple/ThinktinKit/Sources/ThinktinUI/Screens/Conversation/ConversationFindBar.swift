import SwiftUI
import ThinktinKit

#if canImport(Accessibility)
    import Accessibility
#endif

/// 对话内查找的查找栏（规范 4.3.3，参考 04、05）：“…”菜单的“在对话中查找”打开，代替底部的输入框。一行从左到右：
/// 玻璃胶囊的查找框（放大镜、“在对话中查找”，有字时尾部是“第 i 个，共 n 个”，没找到时红字“第 0 个，共 0 个”）、
/// 上一个 / 下一个两个玻璃圆（没找到时灰）、“完成”玻璃胶囊（关掉查找栏，输入框回来）。四个都是 44pt 高、间距 8，查找框拿剩下的宽度。
///
/// - 查找框一出来就聚焦；改字以后跳到最新一处（最下面），回车和上箭头一样往前（更早）找；计数变了读屏念一遍。
/// - 只找已经读进来的记录（更早的要先在时间线顶上加载）。查找栏上不提示：以前上面还能翻时多一个小胶囊“已加载的记录里没有，
///   加载更早的再找”，参考没有，2026-11-06 按用户定的“参考里没有的删掉”去掉了。
/// - 系统 `.searchable` 放不下计数和箭头，`.findNavigator` 只认文本视图，所以自己排一行系统控件（`TextField` + 玻璃按钮）。
struct ConversationFindBar: View {
    let model: ConversationModel
    var isFocused: FocusState<Bool>.Binding

    @Environment(\.displayLanguage) private var language

    /// 控件的高度：最小点按区域（参考 04 量出来约 45pt）。
    static let height: CGFloat = Metrics.minTapTarget

    var body: some View {
        let find = model.find
        HStack(spacing: Metrics.Spacing.xs) {
            field(find)
            // 融合距离和间距一样（同 `FilterChipBar`）：两个圆挨着取样背景，但不连成一块。
            GlassGroup(spacing: Metrics.Spacing.xs) {
                HStack(spacing: Metrics.Spacing.xs) {
                    arrow(
                        ConversationText.findPrevious(language), systemImage: "chevron.up",
                        action: model.findPrevious)
                    arrow(ConversationText.findNext(language), systemImage: "chevron.down", action: model.findNext)
                }
            }
            doneButton
        }
        // 和输入框（`ConversationComposer`）一样：离屏幕两边约 31pt，离底边 16pt。参考 04 的查找栏就在输入框原来的位置，
        // 两个的底边一样高；输入框 2026-11-06 抬到 16pt 时这里还留着 4pt，打开查找会往下掉 12pt。
        .padding(.horizontal, Metrics.Spacing.xxl)
        .padding(.top, Metrics.Spacing.xs)
        .padding(.bottom, Metrics.Spacing.m)
        .frame(maxWidth: Metrics.readableWidth)
        .frame(maxWidth: .infinity)
        .onChange(of: find.jumpCount) { announce() }
    }

    private func field(_ find: ConversationFind) -> some View {
        HStack(spacing: Metrics.Spacing.xs) {
            // 放大镜和占位字一个灰（参考 04）。
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
            TextField(
                ConversationText.findPlaceholder(language),
                text: Binding(get: { find.query }, set: { model.setFindQuery($0) }),
                prompt: Text(ConversationText.findPlaceholder(language)).foregroundStyle(Theme.inkTertiary)
            )
            .textFieldStyle(.plain)
            .typography(.body)
            .foregroundStyle(Theme.ink)
            .tint(Theme.accent)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused(isFocused)
            .onSubmit { model.findPrevious() }
            if find.isSearching {
                Text(
                    ConversationText.findCount(
                        current: find.currentIndex, total: find.matches.count, language: language)
                )
                .typography(.subheadline)
                .monospacedDigit()
                .foregroundStyle(find.matches.isEmpty ? Theme.danger : Theme.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
            }
        }
        // 两边各 12pt：查找框约 160pt 宽，两边留 16pt 时字只剩 98pt，六个字的“在对话中查找”（102pt）被截成“在对话中…”；
        // 现在有 106pt。参考 04 的字离胶囊左边约 41pt，这里是 12 + 放大镜 22 + 8 = 42pt。
        .padding(.horizontal, Metrics.Spacing.s)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .glassBackground(in: Capsule(), interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityValue(
            Text(
                find.isSearching
                    ? ConversationText.findAnnouncement(
                        current: find.currentIndex, total: find.matches.count, language: language) : ""))
    }

    /// 上一个 / 下一个：44pt 的玻璃圆，和查找框、“完成”一样高（参考 04 量出来四个都约 45pt、间距约 10pt）。不用系统的
    /// `.glass` 圆按钮：`.controlSize(.large)` 的圆有约 53pt，比查找框高一截，还把查找框挤到只剩“在对…”。能跳时箭头是强调色
    /// （和别的玻璃按钮一样跟着全局的强调色），没输入、没找到时是三级灰。
    private func arrow(_ title: String, systemImage: String, action: @escaping @MainActor () -> Void) -> some View {
        let canMove = model.find.canMove
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(Typography.body.font.weight(.semibold))
                .foregroundStyle(canMove ? Theme.accent : Theme.inkTertiary)
                .frame(width: Self.height, height: Self.height)
                .glassBackground(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canMove)
        .accessibilityLabel(Text(title))
    }

    /// “完成”：和箭头一样自己画的 44pt 玻璃胶囊（参考 04 约 64pt 宽，字两边约 15pt）。
    private var doneButton: some View {
        Button {
            isFocused.wrappedValue = false
            model.endFind()
        } label: {
            Text(ConversationText.findDone(language))
                .typography(.headline)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Metrics.Spacing.m)
                .frame(height: Self.height)
                .glassBackground(in: Capsule(), interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 计数变了（改了字、上下跳了）读屏念一遍“第 i 个，共 n 个”/“没有找到”。
    private func announce() {
        let find = model.find
        guard find.isSearching else { return }
        AccessibilityNotification.Announcement(
            ConversationText.findAnnouncement(current: find.currentIndex, total: find.matches.count, language: language)
        ).post()
    }
}

/// 查找的高亮（规范 4.3.3）：在一段要画的字里把查找词都标上浅一点的强调色底，“当前这一处”是实心的强调色底、白字。
/// 位置按显示出来的字算（`ConversationFind.occurrences`），和视图模型数的一样。
enum FindHighlighter {
    static func apply(_ attributed: AttributedString, _ highlight: FindSegmentHighlight?) -> AttributedString {
        guard let highlight, !highlight.query.isEmpty else { return attributed }
        var result = attributed
        let plain = String(result.characters)
        for (k, range) in ConversationFind.occurrences(of: highlight.query, in: plain).enumerated() {
            let lower = result.characters.index(result.startIndex, offsetBy: range.lowerBound)
            let upper = result.characters.index(lower, offsetBy: range.count)
            if k == highlight.current {
                result[lower..<upper].backgroundColor = Theme.accent
                result[lower..<upper].foregroundColor = Theme.onAccent
            } else {
                result[lower..<upper].backgroundColor = Theme.accent.opacity(0.28)
            }
        }
        return result
    }

    /// 原样显示的一段（用户消息、代码）：没有高亮时就是 `Text(verbatim:)`。
    static func text(_ string: String, _ highlight: FindSegmentHighlight?) -> Text {
        guard let highlight else { return Text(verbatim: string) }
        return Text(apply(AttributedString(string), highlight))
    }
}

/// Markdown 一块里的高亮：消息的高亮 + 这一块的第一段是消息里的第几段（`MarkdownBlock.findSegments`）。
struct BlockFindHighlight: Hashable {
    let message: ConversationFindHighlight
    let base: Int

    func segment(_ index: Int) -> FindSegmentHighlight {
        message.segment(base + index)
    }

    /// 每块的高亮（没有高亮时全是 nil，不用算段数）。
    static func blocks(_ blocks: [MarkdownBlockItem], _ highlight: ConversationFindHighlight?) -> [Int:
        BlockFindHighlight]
    {
        guard let highlight else { return [:] }
        var result: [Int: BlockFindHighlight] = [:]
        var base = 0
        for item in blocks {
            result[item.id] = BlockFindHighlight(message: highlight, base: base)
            base += item.block.findSegments.count
        }
        return result
    }
}

/// 预览和测试用：打开查找栏、查“周报”。
struct ConversationFindBarDemo: View {
    var query = "周报"
    @State private var model = ConversationModel(client: MockClient(stepDelay: 0), instanceID: DemoData.writerID)
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            Spacer()
            ConversationFindBar(model: model, isFocused: $focused)
        }
        .background(Theme.paper)
        .task {
            await model.start()
            model.beginFind()
            model.setFindQuery(query)
        }
    }
}

#Preview("查找栏 · 浅色中文") {
    ConversationFindBarDemo().previewShell()
}

#Preview("查找栏 · 深色英文") {
    ConversationFindBarDemo().previewShell(.english, scheme: .dark)
}
