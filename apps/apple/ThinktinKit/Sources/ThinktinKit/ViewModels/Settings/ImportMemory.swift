import Foundation

// 导入记忆（`.importMemory`，参考 71；规范 4.9.10、6.20）：第 1 步把一段导出提示词复制到别的 AI 助手里跑，第 2 步把它的回答
// 粘贴回来、“添加到记忆”。ThinkTin 没有写入 Botin 记忆的接口，各引擎的记忆机制也不一样（6.20 建议先不做），所以
// “添加到记忆”弹“即将推出”，粘贴的内容不离开这台设备。ThinkTin 有好几个 Botin，比参考多一行“添加到哪个 Botin”。

/// 导入记忆的表单。
public struct ImportMemoryDraft: Hashable, Sendable {
    /// 粘贴的内容最多几个字（按 Unicode 标量数）。
    public static let maxLength = 20_000

    public var text: String
    /// 添加到哪个 Botin；没有 Botin 时为 nil。
    public var instanceID: InstanceID?

    public init(text: String = "", instanceID: InstanceID? = nil) {
        self.text = text
        self.instanceID = instanceID
    }

    /// 给一组 Botin 开表单：默认选第一个还能用的（`SettingsExtrasText.pickableInstances` 的顺序）。
    public init(instances: [Instance]) {
        self.init(instanceID: SettingsExtrasText.pickableInstances(instances).first?.id)
    }

    public var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isTooLong: Bool { trimmed.unicodeScalars.count > Self.maxLength }

    /// 底部“添加到记忆”能不能点：粘贴了内容、不超长、选了 Botin。
    public var canSubmit: Bool { !trimmed.isEmpty && !isTooLong && instanceID != nil }
}

/// 导入记忆页的文案。
public enum ImportMemoryText {
    /// 第 1 步的组标题（参考 71）。
    public static func step1(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "1. 复制提示词，发给你常用的另一个 AI 助手" : "1. Copy the prompt and send it to your other AI assistant"
    }

    /// 第 2 步的组标题。
    public static func step2(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "2. 把它的回复贴到下面，存进 Botin 的记忆" : "2. Paste its reply below to save it to a Botin's memory"
    }

    public static func copyPrompt(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "复制提示词" : "Copy prompt"
    }

    public static func placeholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "把对方的回复贴在这里" : "Paste the reply here"
    }

    /// “添加到哪个 Botin”那一行。
    public static func target(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加到" : "Add to"
    }

    /// 还没有 Botin 时那一行的值。
    public static func noBotins(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "还没有 Botin" : "No Botins yet"
    }

    /// 太长了（第 2 步的脚注；平时没有脚注，参考 71 粘贴框下面是空的）。
    public static func tooLong(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "最多 \(ImportMemoryDraft.maxLength) 个字。" : "Up to \(ImportMemoryDraft.maxLength) characters."
    }

    /// 底部的全宽按钮。
    public static func submit(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加到记忆" : "Add to memory"
    }

    /// 导出提示词：请别的 AI 助手写一份“交接笔记”，按 Botin 干活用得上的顺序分五段（ThinkTin 自己的结构和写法，
    /// 2026-11-06 重写：以前的版本逐句跟着参考 71 的提示词走）。机密不要写（提示词里自己说了，页面上不再另写脚注）。
    public static func exportPrompt(_ language: DisplayLanguage = .current) -> String {
        if language == .chinese {
            return """
                我要把你对我的了解交给另一个助手。请写一份交接笔记，只写你从我们的对话里确实知道的事。

                分五段，每段一个小标题，下面用短横线列要点：
                1. 我是谁：工作、所在时区、平时用的语言。
                2. 手上的事：在做的项目、一起合作的人、近期的时间点。
                3. 交付习惯：我要的结果长什么样（篇幅、格式、口吻）。
                4. 别碰的：我说过不要做、或者要先问我的事。
                5. 常用的东西：工具、网站、文件，以及我对它们的叫法。

                推测出来的在后面加“（推测）”；哪一段没有内容就写“无”。不要写密码、验证码、卡号这类机密。写完不用总结。
                """
        }
        return """
            I'm handing what you know about me over to another assistant. Write a handover note with only what you \
            actually learned from our conversations.

            Use five sections, each with a short heading and dash bullets under it:
            1. Who I am: work, time zone, the languages I use.
            2. What I'm working on: projects, people I work with, dates coming up.
            3. How I like results: the length, format and tone I want back.
            4. Hands off: things I said not to do, or to check with me first.
            5. Things I use: tools, sites and files, and what I call them.

            Add "(guess)" after anything you inferred, and write "none" under an empty section. Leave out secrets \
            such as passwords, codes and card numbers. No summary at the end.
            """
    }
}
