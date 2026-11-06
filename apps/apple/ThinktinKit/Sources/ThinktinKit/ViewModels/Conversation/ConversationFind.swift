import Foundation
import Observation

// 对话内查找（规范 4.3.3，参考 04、05）：纯客户端，只在已经读进来的记录里找——用户的任务、agent 的回复、没有过程记录的
// 运行的结果（思考默认折着、工具调用和卡片不是“消息”，不找）。更早的要先往上翻（`loadOlder`）才找得到；查找栏上不提示
// （参考 04、05 的查找栏只有查找框、上下两个圆和“完成”，用户 2026-11-06 定的“参考里没有的删掉”）。
//
// 一条消息（滚动的单位，`ConversationFindTarget`）分成几段，一段对应界面上的一个 `Text`（用户消息的引用块和正文，回复的每个
// Markdown 块、列表的每一项、表格的每一格），找到的每一处记成“第几条消息的第几段里的第几个”（`ConversationFindMatch`），
// 界面照着在那一段里高亮、把“当前这一处”标得更重。

/// 一段能查找的字。
public struct ConversationFindSegment: Hashable, Sendable {
    public var text: String
    /// 是行内 Markdown（界面画之前先去掉标记，`ConversationFind.plainText`）；否则原样显示（用户消息、代码块）。
    public var isMarkdown: Bool

    public init(text: String, isMarkdown: Bool) {
        self.text = text
        self.isMarkdown = isMarkdown
    }

    public static func markdown(_ text: String) -> Self { Self(text: text, isMarkdown: true) }
    public static func verbatim(_ text: String) -> Self { Self(text: text, isMarkdown: false) }
}

/// 一条能查找的消息：时间线里的一项（用户消息、agent 的回复），或者没有过程记录的运行的结果。
public struct ConversationFindTarget: Hashable, Sendable {
    /// 滚动用的 id：时间线里那一项的 `ConversationItem.id`，结果是 `summaryID(turnID:)`。
    public var id: String
    /// 所在那一组的 id（懒加载的时间线先滚到这一组，再滚到这一条）。
    public var turnID: String
    public var segments: [ConversationFindSegment]

    public init(id: String, turnID: String, segments: [ConversationFindSegment]) {
        self.id = id
        self.turnID = turnID
        self.segments = segments
    }

    /// 没有过程记录的运行的结果那一块的 id（界面上给它 `.id(…)`）。
    public static func summaryID(turnID: String) -> String { "summary-\(turnID)" }

    /// 用户消息：开头有引用块的先是引用、再是正文（`MessageQuote.split`，和气泡里画的一样）。
    public static func userMessage(_ text: String) -> [ConversationFindSegment] {
        let parts = MessageQuote.split(text)
        return (parts.quote.map { [.verbatim($0)] } ?? []) + [.verbatim(parts.body)]
    }

    /// 一段 Markdown 回复：按块排，每块的段见 `MarkdownBlock.findSegments`。
    public static func markdown(_ blocks: [MarkdownBlockItem]) -> [ConversationFindSegment] {
        blocks.flatMap(\.block.findSegments)
    }
}

extension MarkdownBlock {
    /// 这一块在查找里分成的段，顺序和界面上的 `Text` 一样（`MarkdownBlockView`）：标题、段落、引用一段；列表一项一段；
    /// 代码块一段（原样）；表格先表头、再一行一行，每格一段（补齐到列数）；分隔线没有。
    public var findSegments: [ConversationFindSegment] {
        switch self {
        case .heading(_, let text), .paragraph(let text), .quote(let text):
            return [.markdown(text)]
        case .list(let list):
            return list.items.map { .markdown($0.text) }
        case .code(_, let code, _):
            return [.verbatim(code)]
        case .table(let table):
            let width = table.columnCount
            return ([table.header] + table.rows).flatMap { row in
                (row + Array(repeating: "", count: max(0, width - row.count))).map(ConversationFindSegment.markdown)
            }
        case .rule:
            return []
        }
    }
}

/// 找到的一处。
public struct ConversationFindMatch: Hashable, Sendable {
    public var targetID: String
    public var turnID: String
    /// 消息里的第几段。
    public var segment: Int
    /// 这一段里的第几个。
    public var occurrence: Int

    public init(targetID: String, turnID: String, segment: Int, occurrence: Int) {
        self.targetID = targetID
        self.turnID = turnID
        self.segment = segment
        self.occurrence = occurrence
    }
}

/// 一条消息要怎么高亮：查找的词，和“当前这一处”在第几段的第几个（不在这条消息里为 nil）。
public struct ConversationFindHighlight: Hashable, Sendable {
    public var query: String
    public var currentSegment: Int?
    public var currentOccurrence: Int?

    public init(query: String, currentSegment: Int? = nil, currentOccurrence: Int? = nil) {
        self.query = query
        self.currentSegment = currentSegment
        self.currentOccurrence = currentOccurrence
    }

    /// 第 `index` 段的高亮。
    public func segment(_ index: Int) -> FindSegmentHighlight {
        FindSegmentHighlight(query: query, current: index == currentSegment ? currentOccurrence : nil)
    }
}

/// 一段字的高亮：所有匹配都标，`current` 是“当前这一处”是第几个（不在这一段为 nil）。
public struct FindSegmentHighlight: Hashable, Sendable {
    public var query: String
    public var current: Int?

    public init(query: String, current: Int? = nil) {
        self.query = query
        self.current = current
    }
}

/// 对话内查找的状态：开着没有、查的词、找到的各处、当前是第几处。由 `ConversationModel` 持有（`find`），时间线变了
/// （新事件、往上翻了）时视图模型重新算一遍，当前这一处尽量不跳。
@Observable @MainActor
public final class ConversationFind {
    /// 比较时不分大小写、不分有没有变音符号、不分全角半角（“ＡＢＣ”能找到“abc”）。
    public nonisolated static let options: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]

    /// 查找栏开着（输入框换成查找栏）。
    public private(set) var isActive = false
    /// 查找框里的字（原样，界面绑定它）。
    public private(set) var query = ""
    /// 找到的各处，从上到下。
    public private(set) var matches: [ConversationFindMatch] = []
    /// 当前这一处在 `matches` 里的下标；没找到为 nil。
    public private(set) var currentIndex: Int?
    /// 跳到某一处的次数（界面滚过去、读屏念计数）。
    public private(set) var jumpCount = 0

    /// 行内 Markdown 显示出来的字。默认是 `MarkdownInline.plainText` 的近似；界面换成 `AttributedString(markdown:)` 的真解析，
    /// 找到的位置和画出来的字就对得上。
    @ObservationIgnored public var plainText: @MainActor (String) -> String = MarkdownInline.plainText
    @ObservationIgnored private var matchedTargets: Set<String> = []

    public init() {}

    /// 去掉首尾空白的查找词（空的不找）。
    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 有字、在找。
    public var isSearching: Bool { isActive && !trimmedQuery.isEmpty }

    public var currentMatch: ConversationFindMatch? { currentIndex.map { matches[$0] } }

    /// 上一处、下一处能不能点（没找到时灰）。
    public var canMove: Bool { isSearching && !matches.isEmpty }

    /// 一条消息的高亮；不在找、这条没有匹配时为 nil。
    public func highlight(for targetID: String) -> ConversationFindHighlight? {
        guard isSearching, matchedTargets.contains(targetID) else { return nil }
        let current = currentMatch.flatMap { $0.targetID == targetID ? $0 : nil }
        return ConversationFindHighlight(
            query: trimmedQuery, currentSegment: current?.segment, currentOccurrence: current?.occurrence)
    }

    // MARK: 状态（由 ConversationModel 调）

    func begin() {
        isActive = true
    }

    func end() {
        isActive = false
        query = ""
        if !matches.isEmpty { matches = [] }
        currentIndex = nil
        matchedTargets = []
    }

    func setQuery(_ text: String) {
        query = text
    }

    /// 往上一处（更早）；到头了绕到最后一处。
    func previous() {
        guard let index = currentIndex, !matches.isEmpty else { return }
        currentIndex = (index - 1 + matches.count) % matches.count
        jumpCount += 1
    }

    /// 往下一处（更新）；到底了绕回第一处。
    func next() {
        guard let index = currentIndex, !matches.isEmpty else { return }
        currentIndex = (index + 1) % matches.count
        jumpCount += 1
    }

    /// 在这些消息里重新找。`keepCurrent` 为 false（改了查找词）时跳到最新一处（最下面）；为 true（时间线变了）时
    /// 当前这一处还在就停在它上面，不在了就停在原来的位置附近。
    func update(targets: [ConversationFindTarget], keepCurrent: Bool) {
        let q = trimmedQuery
        guard isActive, !q.isEmpty else {
            if !matches.isEmpty { matches = [] }
            if currentIndex != nil { currentIndex = nil }
            matchedTargets = []
            return
        }
        var found: [ConversationFindMatch] = []
        var targetsWithMatches: Set<String> = []
        for target in targets {
            for (s, segment) in target.segments.enumerated() {
                let text = segment.isMarkdown ? plainText(segment.text) : segment.text
                let count = Self.occurrences(of: q, in: text).count
                guard count > 0 else { continue }
                targetsWithMatches.insert(target.id)
                for k in 0..<count {
                    found.append(
                        ConversationFindMatch(targetID: target.id, turnID: target.turnID, segment: s, occurrence: k))
                }
            }
        }
        let previous = currentMatch
        let previousIndex = currentIndex
        matchedTargets = targetsWithMatches
        if found != matches { matches = found }
        let next: Int?
        if found.isEmpty {
            next = nil
        } else if keepCurrent, let previous, let same = found.firstIndex(of: previous) {
            next = same
        } else if keepCurrent, let previousIndex {
            next = min(previousIndex, found.count - 1)
        } else {
            next = found.count - 1
        }
        if next != currentIndex || !keepCurrent {
            currentIndex = next
            if next != nil { jumpCount += 1 }
        }
    }

    // MARK: 匹配

    /// `query` 在 `text` 里出现的位置（按字符数，互不重叠，从前往后）。比较规则见 `options`。
    public nonisolated static func occurrences(of query: String, in text: String) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var searchStart = text.startIndex
        var offset = 0
        var offsetIndex = text.startIndex
        while searchStart < text.endIndex,
            let range = text.range(of: query, options: options, range: searchStart..<text.endIndex)
        {
            guard !range.isEmpty else { break }
            offset += text.distance(from: offsetIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            result.append(offset..<(offset + length))
            offset += length
            offsetIndex = range.upperBound
            searchStart = range.upperBound
        }
        return result
    }
}

// MARK: - 视图模型

extension ConversationModel {
    /// 能查找的消息，从上到下（和时间线画的顺序一样：一组里先是各项，再是没有过程记录的运行的结果）。
    public var findTargets: [ConversationFindTarget] {
        var targets: [ConversationFindTarget] = []
        for turn in turns {
            for item in turn.items {
                switch item.content {
                case .userMessage(let message):
                    targets.append(
                        ConversationFindTarget(
                            id: item.id, turnID: turn.id, segments: ConversationFindTarget.userMessage(message.text)))
                case .assistantText:
                    targets.append(
                        ConversationFindTarget(
                            id: item.id, turnID: turn.id,
                            segments: ConversationFindTarget.markdown(markdownBlocks(for: item))))
                default:
                    continue
                }
            }
            if let summary = historySummary(for: turn) {
                targets.append(
                    ConversationFindTarget(
                        id: ConversationFindTarget.summaryID(turnID: turn.id), turnID: turn.id,
                        segments: ConversationFindTarget.markdown(MarkdownParser.parse(summary))))
            }
        }
        return targets
    }

    /// 打开查找栏（“…”菜单的“在对话中查找”）。“只看本次过程”、找不到 Botin 时不开。
    public func beginFind() {
        guard focusRunID == nil, !isMissing else { return }
        find.begin()
    }

    /// 点“完成”：关掉查找栏，清掉查找词和高亮，输入框回来。
    public func endFind() {
        find.end()
    }

    /// 改查找词：重新找，跳到最新一处。
    public func setFindQuery(_ text: String) {
        guard find.isActive, text != find.query else { return }
        find.setQuery(text)
        find.update(targets: findTargets, keepCurrent: false)
    }

    /// 上一处（更早）。回车也是它：从最新一处开始找，往前翻才有下一个。
    public func findPrevious() {
        find.previous()
    }

    /// 下一处（更新）。
    public func findNext() {
        find.next()
    }

    /// 时间线变了（`render()`）：在找的话重新找一遍，当前这一处不跳。
    func refreshFind() {
        guard find.isSearching else { return }
        find.update(targets: findTargets, keepCurrent: true)
    }
}

// MARK: - 文案

extension ConversationText {
    /// “…”菜单里的一项（参考 03 的“在聊天中查找”）。
    public static func findInConversation(_ language: DisplayLanguage) -> String {
        language == .chinese ? "在对话中查找" : "Find in Conversation"
    }

    /// 查找框的占位。
    public static func findPlaceholder(_ language: DisplayLanguage) -> String {
        language == .chinese ? "在对话中查找" : "Find in conversation"
    }

    /// 查找框尾部的计数：“第 3 个，共 5 个”（从上往下数）；没找到“第 0 个，共 0 个”（界面标红，参考 05）。
    public static func findCount(current: Int?, total: Int, language: DisplayLanguage) -> String {
        let index = current.map { $0 + 1 } ?? 0
        return language == .chinese ? "第 \(index) 个，共 \(total) 个" : "\(index) of \(total)"
    }

    /// 读屏念的计数。
    public static func findAnnouncement(current: Int?, total: Int, language: DisplayLanguage) -> String {
        if total == 0 { return language == .chinese ? "没有找到" : "No matches" }
        return findCount(current: current, total: total, language: language)
    }

    public static func findPrevious(_ language: DisplayLanguage) -> String {
        language == .chinese ? "上一个" : "Previous"
    }

    public static func findNext(_ language: DisplayLanguage) -> String {
        language == .chinese ? "下一个" : "Next"
    }

    public static func findDone(_ language: DisplayLanguage) -> String {
        language == .chinese ? "完成" : "Done"
    }
}
