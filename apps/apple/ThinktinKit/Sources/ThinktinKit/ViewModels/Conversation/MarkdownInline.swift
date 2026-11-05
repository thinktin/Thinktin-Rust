import Foundation

/// 行内 Markdown 显示出来的字（对话内查找用，规范 4.3.3）：去掉强调（`*` `_` `**` `__` `~~`）、行内代码的反引号、链接和图片的
/// 方括号与地址、自动链接的尖括号、反斜杠转义，剩下的就是界面上看得到的字。
///
/// 只是近似：界面上一段文字用 `AttributedString(markdown:)` 的 inline 模式画（`InlineText`），对话页会把查找用的转换换成
/// 那个真的解析（`ConversationFind.plainText`），找到的位置和画出来的字一一对上。这里的写法给 Linux 上的测试和没有界面的地方用。
public enum MarkdownInline {
    public static func plainText(_ text: String) -> String {
        let chars = Array(text)
        guard chars.contains(where: { "\\`*_~[]<!".contains($0) }) else { return text }
        let tokens = tokenize(chars)
        return render(tokens)
    }

    // MARK: 拆成小段

    private enum Token {
        case text(String)
        /// 一串强调符号（`*`、`_`、`~`），`canOpen` / `canClose` 按两边是不是空白、是不是在词中间算。
        case delimiter(Character, count: Int, canOpen: Bool, canClose: Bool)
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { tokens.append(.text(buffer)) }
            buffer = ""
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                    buffer.append(chars[i + 1])
                    i += 2
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "`":
                let n = run(of: "`", in: chars, from: i)
                if let close = closingRun(of: "`", length: n, in: chars, from: i + n) {
                    buffer += codeSpan(chars[(i + n)..<close])
                    i = close + n
                } else {
                    buffer += String(repeating: "`", count: n)
                    i += n
                }
            case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                if let (label, end) = link(in: chars, at: i + 1) {
                    buffer += plainText(label)
                    i = end
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "[":
                if let (label, end) = link(in: chars, at: i) {
                    buffer += plainText(label)
                    i = end
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "<":
                if let close = chars[(i + 1)...].firstIndex(of: ">"), isAutolink(String(chars[(i + 1)..<close])) {
                    buffer += String(chars[(i + 1)..<close])
                    i = close + 1
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "*", "_", "~":
                let n = run(of: c, in: chars, from: i)
                let before: Character? = i > 0 ? chars[i - 1] : nil
                let after: Character? = i + n < chars.count ? chars[i + n] : nil
                let leftFlanking = after.map { !$0.isWhitespace } ?? false
                let rightFlanking = before.map { !$0.isWhitespace } ?? false
                // `_` 在词中间（两边都是字母数字）不算强调；`~` 只认成对的 `~~`。
                let intraword =
                    (before?.isLetter == true || before?.isNumber == true)
                    && (after?.isLetter == true || after?.isNumber == true)
                if (c == "_" && intraword) || (c == "~" && n != 2) || (!leftFlanking && !rightFlanking) {
                    buffer += String(repeating: c, count: n)
                } else {
                    flush()
                    tokens.append(.delimiter(c, count: n, canOpen: leftFlanking, canClose: rightFlanking))
                }
                i += n
            default:
                buffer.append(c)
                i += 1
            }
        }
        flush()
        return tokens
    }

    /// 配对强调符号：同一种符号、能开的和后面能关的配上，配上的去掉，没配上的原样留下。
    private static func render(_ tokens: [Token]) -> String {
        var removed = Set<Int>()
        var openers: [Int] = []
        for (index, token) in tokens.enumerated() {
            guard case .delimiter(let c, let n, let canOpen, let canClose) = token else { continue }
            if canClose,
                let match = openers.lastIndex(where: {
                    if case .delimiter(let oc, let on, _, _) = tokens[$0] { return oc == c && on == n }
                    return false
                })
            {
                removed.insert(openers[match])
                removed.insert(index)
                openers.removeSubrange(match...)
            } else if canOpen {
                openers.append(index)
            }
        }
        var out = ""
        for (index, token) in tokens.enumerated() {
            switch token {
            case .text(let text): out += text
            case .delimiter(let c, let n, _, _):
                if !removed.contains(index) { out += String(repeating: c, count: n) }
            }
        }
        return out
    }

    // MARK: 小工具

    private static func run(of c: Character, in chars: [Character], from start: Int) -> Int {
        var n = 0
        while start + n < chars.count, chars[start + n] == c { n += 1 }
        return n
    }

    /// 从 `start` 往后找一串正好 `length` 个 `c` 的位置。
    private static func closingRun(of c: Character, length: Int, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == c {
                let n = run(of: c, in: chars, from: i)
                if n == length { return i }
                i += n
            } else {
                i += 1
            }
        }
        return nil
    }

    /// 行内代码的内容：两头都有空格（又不全是空格）时各去掉一个（CommonMark）。
    private static func codeSpan(_ content: ArraySlice<Character>) -> String {
        let text = String(content)
        if text.count >= 2, text.first == " ", text.last == " ", text.contains(where: { $0 != " " }) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// `[文字](地址)`：返回方括号里的文字和链接后面的位置。方括号可以嵌套一层，地址里的括号要成对。
    private static func link(in chars: [Character], at open: Int) -> (String, Int)? {
        var depth = 0
        var i = open
        var labelEnd: Int?
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "[" { depth += 1 }
            if chars[i] == "]" {
                depth -= 1
                if depth == 0 {
                    labelEnd = i
                    break
                }
            }
            i += 1
        }
        guard let labelEnd, labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else { return nil }
        var parens = 0
        var j = labelEnd + 1
        while j < chars.count {
            if chars[j] == "(" { parens += 1 }
            if chars[j] == ")" {
                parens -= 1
                if parens == 0 { return (String(chars[(open + 1)..<labelEnd]), j + 1) }
            }
            if chars[j].isNewline { return nil }
            j += 1
        }
        return nil
    }

    /// `<https://…>`、`<mailto:…>`、`<a@b.c>` 这种自动链接。
    private static func isAutolink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "<" }) else { return false }
        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon]
            return scheme.count >= 2
                && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
        }
        return text.contains("@") && text.contains(".")
    }
}
