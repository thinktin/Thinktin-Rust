import Foundation

/// 引用回复的文字处理（规范 4.3.5、6.11 A：纯客户端，后端不知道“回复的是哪条”）。
///
/// 发出去的是普通 Markdown：引用的每一行前面加 `> `，空行只留 `>`，再空一行接正文：
///
/// ```
/// > 我现在有一个只有你能看到的保险库……
///
/// 好，帮我加一张卡
/// ```
///
/// 用户消息的气泡显示时再拆回“引用 + 正文”（`split`），引用画成气泡里的一小块。
public enum MessageQuote {
    /// 引用最多留这么多个字符（太长的截断，末尾加“…”）：引用只是提醒 Botin 回的是哪一段，它自己有上下文。
    public static let maxLength = 1000

    /// 记下来的引用：去掉首尾空白、换行统一成 `\n`，太长的截断；空的为 nil。
    public static func normalized(_ text: String) -> String? {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let trimmed = unified.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// 发出去的文字：有引用、正文不空时是“引用块 + 空行 + 正文（去掉首尾空白）”；否则原样返回正文（引用不单独发）。
    public static func compose(quote: String?, body: String) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = quote.flatMap(normalized), !trimmedBody.isEmpty else { return body }
        let block = quote.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        return block + "\n\n" + trimmedBody
    }

    /// 把消息拆成开头的引用和正文：开头连续以 `>` 开头的行、接一个空行、后面还有正文，才算引用（和 `compose` 对得上，
    /// 用户自己用 Markdown 写的引用也一样拆）。不是这个样子的整段当正文。
    public static func split(_ message: String) -> (quote: String?, body: String) {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        var quoted: [Substring] = []
        var index = 0
        while index < lines.count, lines[index].hasPrefix(">") {
            var line = lines[index].dropFirst()
            if line.hasPrefix(" ") { line = line.dropFirst() }
            quoted.append(line)
            index += 1
        }
        guard !quoted.isEmpty, index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty else {
            return (nil, message)
        }
        let body = lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = quoted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !quote.isEmpty else { return (nil, message) }
        return (quote, body)
    }

    /// 引用条上的一行：换行换成空格、连续的空白并成一个（显示时再按宽度截断）。
    public static func preview(_ quote: String) -> String {
        quote.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
