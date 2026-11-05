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
            ? "1. 把这段提示词复制到你和另一个 AI 助手的对话里" : "1. Copy this prompt into a chat with your other AI assistant"
    }

    /// 第 2 步的组标题。
    public static func step2(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "2. 把它的回答粘贴到下面，添加到 Botin 的记忆里" : "2. Paste its answer below to add it to a Botin's memory"
    }

    public static func copyPrompt(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "复制提示词" : "Copy prompt"
    }

    public static func placeholder(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "在这里粘贴你的记忆" : "Paste your memories here"
    }

    /// “添加到哪个 Botin”那一行。
    public static func target(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加到" : "Add to"
    }

    /// 还没有 Botin 时那一行的值。
    public static func noBotins(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "还没有 Botin" : "No Botins yet"
    }

    /// 第 2 步的脚注。
    public static func footer(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "每个 Botin 的记忆是分开的。粘贴前看一眼，别带上密码和验证码。"
            : "Each Botin keeps its own memory. Check what you paste and leave out passwords and codes."
    }

    /// 太长了。
    public static func tooLong(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "最多 \(ImportMemoryDraft.maxLength) 个字。" : "Up to \(ImportMemoryDraft.maxLength) characters."
    }

    /// 底部的全宽按钮。
    public static func submit(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加到记忆" : "Add to memory"
    }

    /// 导出提示词：让别的 AI 助手把它记住的关于你的事按类整理出来（ThinkTin 自己的写法）。
    public static func exportPrompt(_ language: DisplayLanguage = .current) -> String {
        if language == .chinese {
            return """
                请把你记住的关于我的所有信息整理出来，包括从我们以前的对话里了解到的背景。能用我自己原话的地方尽量用原话，\
                特别是我明确要求过的做法和偏好。

                按下面的顺序分类输出，每条一行：
                1. 做事的要求：我明确让你遵守的规则（语气、格式、要做和不要做的事）。
                2. 偏好：我喜欢和不喜欢的东西、常用的工具和写法。
                3. 关于我：职业、所在的城市、常用的语言这类背景。
                4. 正在做的事：项目、目标、截止时间。
                5. 其他：上面没归进去、但以后可能用得上的。

                不要编造；拿不准的标上“不确定”。只输出整理好的列表，不要别的解释。
                """
        }
        return """
            List everything you remember about me, including context you picked up from our past conversations. Keep my \
            own words wherever you can, especially for instructions and preferences I gave you.

            Group the output in this order, one item per line:
            1. Instructions: rules I explicitly asked you to follow (tone, format, things to do or avoid).
            2. Preferences: what I like and dislike, tools and styles I use.
            3. About me: background such as my job, city and languages.
            4. Current work: projects, goals and deadlines.
            5. Other: anything else that may be useful later.

            Don't make anything up; mark anything you're unsure about as "unsure". Output only the list, with no \
            other commentary.
            """
    }
}
