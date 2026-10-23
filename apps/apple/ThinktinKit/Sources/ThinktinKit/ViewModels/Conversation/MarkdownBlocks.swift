import Foundation

/// agent 回复的块级 Markdown（标题、段落、列表、代码块、引用、表格、分隔线）。行内的格式（加粗、斜体、行内代码、链接）
/// 留给界面层（`AttributedString(markdown:)` 的 inline 模式）。
///
/// 只认 agent 回复里常见的写法（CommonMark 加 GitHub 的表格、任务列表），不认缩进代码块、setext 标题、HTML；
/// 认不出的都按段落显示，原文不丢。
public enum MarkdownBlock: Hashable, Sendable {
    /// `#` 到 `######`。
    case heading(level: Int, text: String)
    /// 段落：几行原样拼起来（保留换行）。
    case paragraph(String)
    /// 列表（有序、无序、任务列表，可以嵌套）。
    case list(MarkdownList)
    /// 围栏代码块。`isClosed` 为 false 表示还没收到结束的围栏（流式输出中）。
    case code(language: String?, code: String, isClosed: Bool)
    /// 引用（`>`）：里面的几行原样拼起来。
    case quote(String)
    /// 表格（GFM）：界面可以画成网格，也可以降级成文字（`MarkdownTable.plainText`）。
    case table(MarkdownTable)
    /// 分隔线（`---`）。
    case rule
}

/// 列表。
public struct MarkdownList: Hashable, Sendable {
    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// 列表的一项。
    public struct Item: Hashable, Sendable {
        /// 这一项的文字（续行用换行拼起来）。
        public var text: String
        /// 嵌套的层级，从 0 开始。
        public var level: Int
        /// 有序列表的序号；无序的为 nil。
        public var number: Int?
        /// 任务列表：勾上了为 true，没勾为 false；不是任务列表为 nil。
        public var checked: Bool?

        public init(text: String, level: Int = 0, number: Int? = nil, checked: Bool? = nil) {
            self.text = text
            self.level = level
            self.number = number
            self.checked = checked
        }
    }
}

/// 表格。
public struct MarkdownTable: Hashable, Sendable {
    public var header: [String]
    public var rows: [[String]]

    public init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    /// 列数（表头和各行里最多的）。
    public var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    /// 降级成文字：每行的格子用“ | ”隔开，一行一行排下来（表头在第一行）。复制、读屏时用。
    public var plainText: String {
        ([header] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
    }
}

/// 带位置的块：`id` 是第几块（流式追加时前面的块 id 不变），`offset` 是这一块第一行在原文里的 UTF-8 偏移。
public struct MarkdownBlockItem: Identifiable, Hashable, Sendable {
    public var id: Int
    public var block: MarkdownBlock
    public var offset: Int

    public init(id: Int, block: MarkdownBlock, offset: Int) {
        self.id = id
        self.block = block
        self.offset = offset
    }
}

/// 块级 Markdown 解析（纯函数）。
public enum MarkdownParser {
    /// 整段解析。
    public static func parse(_ text: String) -> [MarkdownBlockItem] {
        parse(text, from: 0, firstID: 0)
    }

    /// 从 UTF-8 偏移 `offset`（一行的开头）解析到结尾；块的 `offset` 是在整段原文里的位置，`id` 从 `firstID` 往后数。
    static func parse(_ text: String, from offset: Int, firstID: Int) -> [MarkdownBlockItem] {
        let tail =
            offset == 0 ? Substring(text) : Substring(String(decoding: text.utf8.dropFirst(offset), as: UTF8.self))
        // 按 UTF-8 的换行符拆行（Swift 里 "\r\n" 是一个字符，按字符拆拆不开），行尾的 "\r" 去掉。
        var lines: [Line] = []
        var position = offset
        let bytes = tail.utf8
        var lineStart = bytes.startIndex
        while true {
            let end = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.endIndex
            var content = bytes[lineStart..<end]
            if content.last == 0x0D { content = content.dropLast() }
            lines.append(Line(text: Substring(String(decoding: content, as: UTF8.self)), offset: position))
            position += bytes.distance(from: lineStart, to: end) + 1
            if end == bytes.endIndex { break }
            lineStart = bytes.index(after: end)
        }
        // 结尾的换行不算一行。
        if let last = lines.last, last.text.isEmpty, lines.count > 1 { lines.removeLast() }
        var blocks: [MarkdownBlockItem] = []
        var i = 0
        while i < lines.count {
            if lines[i].isBlank {
                i += 1
                continue
            }
            let start = lines[i].offset
            let (block, next) = parseBlock(lines, at: i)
            blocks.append(MarkdownBlockItem(id: firstID + blocks.count, block: block, offset: start))
            i = max(next, i + 1)
        }
        return blocks
    }

    // MARK: 行

    struct Line {
        let text: Substring
        /// 这一行在原文里的 UTF-8 偏移。
        let offset: Int

        var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

        /// 开头的空格数（tab 算 4 个）。
        var indent: Int {
            var n = 0
            for ch in text {
                if ch == " " {
                    n += 1
                } else if ch == "\t" {
                    n += 4
                } else {
                    break
                }
            }
            return n
        }

        /// 去掉开头空白后的文字。
        var trimmedLeading: Substring { text.drop { $0 == " " || $0 == "\t" } }

        /// 去掉首尾空白后的文字。
        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 块

    /// 从第 `i` 行（不是空行）开始的一块，返回块和下一块开始的行号。
    static func parseBlock(_ lines: [Line], at i: Int) -> (MarkdownBlock, Int) {
        let line = lines[i]
        if let fence = fenceOpening(line) { return parseCode(lines, at: i, fence: fence) }
        if let heading = heading(line) { return (heading, i + 1) }
        if isRule(line) { return (.rule, i + 1) }
        if quoteContent(line) != nil { return parseQuote(lines, at: i) }
        if listMarker(line) != nil { return parseList(lines, at: i) }
        if isTableStart(lines, at: i) { return parseTable(lines, at: i) }
        return parseParagraph(lines, at: i)
    }

    /// 这一行开始了别的块（打断段落、引用的续行）。
    static func startsBlock(_ lines: [Line], at i: Int) -> Bool {
        let line = lines[i]
        return fenceOpening(line) != nil || heading(line) != nil || isRule(line) || quoteContent(line) != nil
            || listMarker(line) != nil || isTableStart(lines, at: i)
    }

    // 围栏代码块：``` 或 ~~~（最多缩进 3 格），结束的围栏用同一种字符、不比开头短。
    struct Fence {
        let character: Character
        let length: Int
        let language: String?
        /// 开头的围栏缩进了几格：代码的每一行最多去掉这么多空格（列表项里的代码块）。
        let indent: Int
    }

    static func fenceOpening(_ line: Line) -> Fence? {
        guard line.indent <= 3 else { return nil }
        let s = line.trimmedLeading
        guard let first = s.first, first == "`" || first == "~" else { return nil }
        let length = s.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = s.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // 反引号围栏的说明里不能再有反引号（那是行内代码）。
        if first == "`" && info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(
            character: first, length: length, language: language?.isEmpty == false ? language : nil,
            indent: line.indent)
    }

    static func parseCode(_ lines: [Line], at i: Int, fence: Fence) -> (MarkdownBlock, Int) {
        var body: [Substring] = []
        var j = i + 1
        while j < lines.count {
            let s = lines[j].trimmedLeading
            if lines[j].indent <= 3, s.first == fence.character,
                s.prefix(while: { $0 == fence.character }).count >= fence.length,
                s.drop(while: { $0 == fence.character }).allSatisfy({ $0 == " " || $0 == "\t" })
            {
                return (.code(language: fence.language, code: body.joined(separator: "\n"), isClosed: true), j + 1)
            }
            body.append(dropIndent(lines[j].text, upTo: fence.indent))
            j += 1
        }
        return (.code(language: fence.language, code: body.joined(separator: "\n"), isClosed: false), j)
    }

    /// 去掉开头最多 `n` 个空格。
    static func dropIndent(_ text: Substring, upTo n: Int) -> Substring {
        var out = text
        var removed = 0
        while removed < n, out.first == " " {
            out = out.dropFirst()
            removed += 1
        }
        return out
    }

    // 标题：1 到 6 个 #，后面跟空格（或什么都没有），结尾的 # 去掉。
    static func heading(_ line: Line) -> MarkdownBlock? {
        guard line.indent <= 3 else { return nil }
        let s = line.trimmedLeading
        let level = s.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = s.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // 结尾的一串 #（前面是空格时）是装饰。
        if let hashes = text.lastIndex(where: { $0 != "#" }) {
            let tail = text[text.index(after: hashes)...]
            if !tail.isEmpty && (text[hashes] == " " || text[hashes] == "\t") {
                text = String(text[...hashes]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            text = ""
        }
        return .heading(level: level, text: text)
    }

    // 分隔线：三个以上同样的 - * _（中间可以有空格）。
    static func isRule(_ line: Line) -> Bool {
        guard line.indent <= 3 else { return false }
        let chars = line.text.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let first = chars.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return chars.allSatisfy { $0 == first }
    }

    // 引用：`>` 开头（最多缩进 3 格），后面的一个空格不算内容。
    static func quoteContent(_ line: Line) -> Substring? {
        guard line.indent <= 3 else { return nil }
        let s = line.trimmedLeading
        guard s.first == ">" else { return nil }
        let rest = s.dropFirst()
        return rest.first == " " ? rest.dropFirst() : rest
    }

    static func parseQuote(_ lines: [Line], at i: Int) -> (MarkdownBlock, Int) {
        var body: [Substring] = []
        var j = i
        while j < lines.count {
            if let content = quoteContent(lines[j]) {
                body.append(content)
            } else if !lines[j].isBlank, !startsBlock(lines, at: j), !body.isEmpty, !(body.last?.isEmpty ?? true) {
                // 懒续行：紧跟着的普通文字算在引用里。
                body.append(lines[j].trimmedLeading)
            } else {
                break
            }
            j += 1
        }
        return (.quote(body.joined(separator: "\n")), j)
    }

    // 列表项：`-`、`*`、`+` 或 `1.`、`1)`，后面跟空格。
    struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int?
        /// 标记后面的文字。
        let content: Substring
    }

    static func listMarker(_ line: Line) -> ListMarker? {
        let s = line.trimmedLeading
        guard let first = s.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = s.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            // `- - -`、`***` 是分隔线。
            if isRule(line) { return nil }
            return ListMarker(indent: line.indent, ordered: false, number: nil, content: rest.drop { $0 == " " })
        }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = s.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return ListMarker(
            indent: line.indent, ordered: true, number: Int(digits), content: rest.drop { $0 == " " })
    }

    static func parseList(_ lines: [Line], at i: Int) -> (MarkdownBlock, Int) {
        guard let first = listMarker(lines[i]) else { return parseParagraph(lines, at: i) }
        let baseIndent = first.indent
        var items: [MarkdownList.Item] = []
        // 每一层的缩进（从外到里），算层级用。
        var levels: [Int] = [baseIndent]
        var j = i
        while j < lines.count {
            let line = lines[j]
            if line.isBlank {
                // 空行之后还是这个列表的项（松散列表）就接着，否则列表结束。
                var k = j + 1
                while k < lines.count && lines[k].isBlank { k += 1 }
                guard k < lines.count, let next = listMarker(lines[k]), next.indent >= baseIndent,
                    next.indent > baseIndent || next.ordered == first.ordered
                else { break }
                j = k
                continue
            }
            if let marker = listMarker(line) {
                // 最外层换了种类（无序换成有序）就是另一个列表。
                if marker.indent <= baseIndent && marker.ordered != first.ordered && !items.isEmpty { break }
                if marker.indent < baseIndent { break }
                while let last = levels.last, marker.indent < last, levels.count > 1 { levels.removeLast() }
                if let last = levels.last, marker.indent > last + 1 { levels.append(marker.indent) }
                let (text, checked) = taskItem(marker.content)
                items.append(
                    MarkdownList.Item(
                        text: text, level: levels.count - 1, number: marker.ordered ? marker.number : nil,
                        checked: checked))
                j += 1
                continue
            }
            // 续行：缩进的、或者紧跟着的普通文字，拼到上一项后面；别的块开头就结束列表。列表项里的代码块（缩进 3 格以内
            // 的围栏）也结束列表，按代码块显示（之后的项另起一个列表，序号照原文）。
            if fenceOpening(line) != nil || (line.indent <= baseIndent && startsBlock(lines, at: j)) { break }
            if items.isEmpty { break }
            items[items.count - 1].text += "\n" + line.trimmed
            j += 1
        }
        return (.list(MarkdownList(items: items)), j)
    }

    /// 任务列表：`[ ] ` / `[x] ` 开头。
    static func taskItem(_ content: Substring) -> (String, Bool?) {
        let text = String(content).trimmingCharacters(in: .whitespaces)
        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            if rest.isEmpty || rest.first == " " {
                return (rest.trimmingCharacters(in: .whitespaces), checked)
            }
        }
        return (text, nil)
    }

    // 表格（GFM）：表头一行，下面是 `---|:---:` 这样的分隔行，再往下每行一个格子一列。
    static func isTableStart(_ lines: [Line], at i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].text.contains("|") else { return false }
        return isDelimiterRow(lines[i + 1])
    }

    static func isDelimiterRow(_ line: Line) -> Bool {
        let cells = splitRow(line.trimmed)
        guard !cells.isEmpty, line.text.contains("-") else { return false }
        return cells.allSatisfy { cell in
            var c = Substring(cell)
            if c.hasPrefix(":") { c = c.dropFirst() }
            if c.hasSuffix(":") { c = c.dropLast() }
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
    }

    /// 一行拆成格子：去掉两头的 `|`，`\|` 是格子里的竖线。
    static func splitRow(_ row: String) -> [String] {
        var s = Substring(row.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s = s.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped {
                current.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func parseTable(_ lines: [Line], at i: Int) -> (MarkdownBlock, Int) {
        let header = splitRow(lines[i].trimmed)
        var rows: [[String]] = []
        var j = i + 2
        while j < lines.count, !lines[j].isBlank, lines[j].text.contains("|"), !startsBlockOtherThanTable(lines, at: j)
        {
            rows.append(splitRow(lines[j].trimmed))
            j += 1
        }
        return (.table(MarkdownTable(header: header, rows: rows)), j)
    }

    static func startsBlockOtherThanTable(_ lines: [Line], at i: Int) -> Bool {
        let line = lines[i]
        return fenceOpening(line) != nil || heading(line) != nil || quoteContent(line) != nil
    }

    static func parseParagraph(_ lines: [Line], at i: Int) -> (MarkdownBlock, Int) {
        var body: [String] = [lines[i].trimmed]
        var j = i + 1
        while j < lines.count, !lines[j].isBlank, !startsBlock(lines, at: j) {
            body.append(lines[j].trimmed)
            j += 1
        }
        return (.paragraph(body.joined(separator: "\n")), j)
    }
}

/// 流式输出时的增量解析：文字只在后面追加时，前面的块不变（`id` 也不变），只重新解析最后两块开始的那部分；界面的块视图
/// 按内容比较（`Equatable`），没变的块不重排，通常只有最后一块重排。文字被整个换掉（不是追加）时从头解析。
///
/// 为什么是两块：最后一行可能还没收全，它的解读会变，连带改变上一块在哪儿结束。比如“段落\n#”里的“#”先被认成标题、
/// 段落在它前面结束；后面接上“include”变成“#include”就不是标题了，应该和上面的段落是同一段。再往前的块是在完整的行上
/// 结束的，不受影响。
public struct MarkdownStream: Hashable, Sendable {
    public private(set) var text = ""
    public private(set) var blocks: [MarkdownBlockItem] = []
    /// 一共整段解析了几次（测试用：追加时不该增加）。
    public private(set) var fullParses = 0

    public init() {}

    public init(text: String) {
        update(text)
    }

    /// 换成新的文字，返回解析好的块。
    @discardableResult
    public mutating func update(_ newText: String) -> [MarkdownBlockItem] {
        if newText == text, !(text.isEmpty && blocks.isEmpty && fullParses == 0) { return blocks }
        if !text.isEmpty, newText.hasPrefix(text), !blocks.isEmpty {
            let keep = max(0, blocks.count - 2)
            let start = blocks[keep]
            blocks = Array(blocks.prefix(keep)) + MarkdownParser.parse(newText, from: start.offset, firstID: start.id)
        } else {
            blocks = MarkdownParser.parse(newText)
            fullParses += 1
        }
        text = newText
        return blocks
    }
}
