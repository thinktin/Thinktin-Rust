import Foundation

/// 工具调用卡片上显示的东西（纯函数）：种类名、一句话摘要（命令、文件路径、网址、搜索词）、展开后的参数和结果。
///
/// agent 的工具调用 `raw` 是合并过更新的 ACP tool_call（`rawInput`、`content`、`rawOutput`、`locations`），平台工具的
/// `raw` 是参数（`arguments`）。标题是 agent 写的，显示时带 AI 生成标识（`AIGeneratedField.toolCallTitle`）。
public struct ToolCallPresentation: Hashable, Sendable {
    /// 种类名（“执行命令”“平台工具 · 计划”）。
    public var kindName: String
    /// 标题（agent 写的；空的时候用种类名）。
    public var title: String
    /// 一句话摘要：命令、路径、网址、搜索词；没有为 nil。
    public var summary: String?
    /// 展开后的参数（排好版的 JSON 或命令）；没有为 nil。
    public var input: String?
    /// 展开后的结果（工具返回的文字、`rawOutput`）；没有为 nil。
    public var output: String?
    /// 状态名；平台工具没有状态。
    public var statusName: String?

    public init(_ card: ToolCallCard, language: DisplayLanguage) {
        if let category = card.platformCategory {
            kindName = ConversationText.platformToolName(category, language: language)
            statusName = nil
            input = card.raw.flatMap(Self.pretty)
            output = nil
            summary = card.raw.flatMap(Self.platformSummary)
        } else {
            kindName = ConversationText.toolKindName(card.kind, language: language)
            statusName = ConversationText.toolStatusName(card.status, language: language)
            let rawInput = card.raw?["rawInput"] ?? card.raw?["raw_input"]
            input = rawInput.flatMap(Self.inputText)
            output = card.raw.flatMap(Self.outputText)
            summary = rawInput.flatMap(Self.inputSummary) ?? card.raw.flatMap(Self.locationSummary)
        }
        let trimmed = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? kindName : trimmed
        if summary == title { summary = nil }
    }

    /// 标题要不要带 AI 生成标识：agent 自己的工具标题、平台工具的参数都是 agent 写的。
    public static func isAIGenerated(_ card: ToolCallCard) -> Bool {
        (card.isPlatformTool ? AIGeneratedField.platformToolCall : .toolCallTitle).isAIGenerated
    }

    // MARK: 摘要

    /// 命令（字符串或者参数数组）、路径、网址、搜索词。
    static func inputSummary(_ input: JSONValue) -> String? {
        if let command = input["command"] ?? input["cmd"] {
            if let s = command.stringValue { return oneLine(s) }
            if case .array(let parts) = command {
                let words = parts.compactMap(\.stringValue)
                if !words.isEmpty { return oneLine(words.joined(separator: " ")) }
            }
        }
        for key in ["path", "file_path", "filePath", "abs_path", "url", "query", "pattern"] {
            if let s = input[key]?.stringValue, !s.isEmpty { return oneLine(s) }
        }
        return nil
    }

    /// ACP 的 `locations`（改了哪些文件）。
    static func locationSummary(_ raw: JSONValue) -> String? {
        guard case .array(let list)? = raw["locations"] else { return nil }
        let paths = list.compactMap { $0["path"]?.stringValue }
        guard let first = paths.first else { return nil }
        return paths.count > 1 ? "\(first) +\(paths.count - 1)" : first
    }

    /// 平台工具的参数里最能说明它的那个（计划标题、委派对象、产出物名、保险箱条目名）。
    static func platformSummary(_ arguments: JSONValue) -> String? {
        for key in ["title", "name", "to", "task", "prompt", "plan_id"] {
            if let s = arguments[key]?.stringValue, !s.isEmpty { return oneLine(s) }
        }
        return nil
    }

    // MARK: 详情

    /// 参数：命令就显示命令，其余是排好版的 JSON。
    static func inputText(_ input: JSONValue) -> String? {
        if let command = input["command"]?.stringValue, input.objectValue?.count == 1 { return command }
        return pretty(input)
    }

    /// 结果：ACP 的 `content` 里的文字（`{type: content, content: {type: text, text}}` 或者 `{type: text, text}`），
    /// 没有文字时是 `rawOutput`。
    static func outputText(_ raw: JSONValue) -> String? {
        if case .array(let blocks)? = raw["content"] {
            let texts = blocks.compactMap { block -> String? in
                if let text = block["text"]?.stringValue { return text }
                if let text = block["content"]?["text"]?.stringValue { return text }
                if let diffPath = block["path"]?.stringValue, block["type"]?.stringValue == "diff" {
                    return "diff: \(diffPath)"
                }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        if let output = raw["rawOutput"] ?? raw["raw_output"] {
            return output.stringValue ?? pretty(output)
        }
        return nil
    }

    /// 排好版的 JSON；空对象、null 为 nil。
    static func pretty(_ value: JSONValue) -> String? {
        switch value {
        case .null: return nil
        case .object(let o) where o.isEmpty: return nil
        case .string(let s): return s.isEmpty ? nil : s
        default: return value.prettyPrinted()
        }
    }

    /// 只要第一行，最长 120 个字符。
    static func oneLine(_ text: String) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
}
