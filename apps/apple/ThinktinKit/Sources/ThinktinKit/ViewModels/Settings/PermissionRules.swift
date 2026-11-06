import Foundation

// 权限与规则（`.permissions`，参考 62、63、64、100；规范 4.9.8、6.15）：“自动审查”总开关，加“始终询问”“无需询问即允许”
// 两组一句话写的规则，由模型判断一次操作有没有命中。ThinkTin 还没有这个后端（6.15 建议先不做、做之前过安全评审），
// 这里只有版式要的数据：本地的演示规则（`PermissionsDemoData`）和规则表单的校验；开关、保存、删除都弹“即将推出”
// （`SettingsComingSoon`）。真要做的时候，电脑上的高危操作不能被“自动允许”覆盖（docs/pairing.md 第 3 节）。

/// 规则的两组。
public enum PermissionRuleKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// 操作符合时先停下来问你（只会更严）。
    case alwaysAsk
    /// 操作符合时直接继续。
    case autoAllow

    public var id: String { rawValue }

    /// 组标题（参考 62）。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .alwaysAsk: return zh ? "始终询问" : "Always ask"
        case .autoAllow: return zh ? "无需询问即允许" : "Allow without asking"
        }
    }

    /// 组标题下面的一句说明（ThinkTin 自己的话，2026-11-06 改：以前和参考 62 几乎一字不差）。
    public func subtitle(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .alwaysAsk: return zh ? "遇到这些操作，Botin 等你同意再做" : "For these, the Botin waits for your OK"
        case .autoAllow: return zh ? "遇到这些操作，Botin 不用问你就做" : "For these, the Botin goes ahead on its own"
        }
    }

    /// 新建这一组的规则时输入框的占位（参考 63 是“始终询问”的，100 是“自动允许”的；例子是 ThinkTin 自己的，跟工作区有关）。
    public func placeholder(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .alwaysAsk: return zh ? "删除工作区以外的文件" : "Deleting files outside the workspace"
        case .autoAllow: return zh ? "读取工作区里的文件" : "Reading files in the workspace"
        }
    }
}

/// 一条规则：一句自然语言。
public struct PermissionRule: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: PermissionRuleKind
    public var text: String

    public init(id: String, kind: PermissionRuleKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// 权限页的内容：自动审查开没开、有哪些规则。
public struct PermissionsOverview: Hashable, Sendable {
    public var autoReview: Bool
    public var rules: [PermissionRule]

    public init(autoReview: Bool, rules: [PermissionRule]) {
        self.autoReview = autoReview
        self.rules = rules
    }

    /// 一组的规则，按原来的顺序。
    public func rules(of kind: PermissionRuleKind) -> [PermissionRule] {
        rules.filter { $0.kind == kind }
    }

    public func rule(id: String) -> PermissionRule? {
        rules.first { $0.id == id }
    }

    /// 设置根页“权限”一行的副标题（参考 53：“自动审查已开启 · 3 条规则”）。
    public func settingsSubtitle(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let review =
            autoReview ? (zh ? "自动审查已开启" : "Auto-review on") : (zh ? "自动审查已关闭" : "Auto-review off")
        let count =
            zh ? "\(rules.count) 条规则" : (rules.count == 1 ? "1 rule" : "\(rules.count) rules")
        return "\(review) · \(count)"
    }
}

/// 权限页的演示数据（规范 6.15 定下来之前给版式用）：自动审查开着，“始终询问”没有规则（参考 62 的“暂无规则”），
/// “无需询问即允许”三条 ThinkTin 用得上的例子。
public enum PermissionsDemoData {
    public static func overview(_ language: DisplayLanguage = .current) -> PermissionsOverview {
        let zh = language == .chinese
        return PermissionsOverview(
            autoReview: true,
            rules: [
                PermissionRule(
                    id: "demo-allow-tests", kind: .autoAllow,
                    text: zh
                        ? "在项目仓库里运行单元测试和代码检查命令。" : "Run unit tests and linters in the project repository."),
                PermissionRule(
                    id: "demo-allow-dependencies", kind: .autoAllow,
                    text: zh
                        ? "在工作区里安装 npm 和 pip 依赖。" : "Install npm and pip dependencies in the workspace."),
                PermissionRule(
                    id: "demo-allow-output", kind: .autoAllow,
                    text: zh
                        ? "把产出物写进工作区的 output 目录。" : "Write artifacts to the workspace's output folder."),
            ])
    }
}

/// 新建 / 修改一条规则的表单（参考 63、64、100）：“适用于”一个多行输入框。
public struct PermissionRuleDraft: Hashable, Sendable {
    /// 一条规则最多几个字（按 Unicode 标量数）。
    public static let maxLength = 500

    public let kind: PermissionRuleKind
    /// 修改的那条；新建时为 nil。
    public let original: PermissionRule?
    public var text: String

    /// 新建一条 `kind` 组的规则。
    public init(kind: PermissionRuleKind) {
        self.kind = kind
        self.original = nil
        self.text = ""
    }

    /// 修改一条规则。
    public init(editing rule: PermissionRule) {
        self.kind = rule.kind
        self.original = rule
        self.text = rule.text
    }

    public var isNew: Bool { original == nil }

    public var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isTooLong: Bool { trimmed.unicodeScalars.count > Self.maxLength }

    /// 底部的“添加规则 / 保存规则”能不能点：写了字、不超长、修改时真的改了。
    public var canSave: Bool {
        guard !trimmed.isEmpty, !isTooLong else { return false }
        if let original { return trimmed != original.text }
        return true
    }

    /// 页面标题。
    public func title(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        return isNew ? (zh ? "新建规则" : "New rule") : (zh ? "编辑规则" : "Edit rule")
    }

    /// 底部全宽按钮上的字。
    public func saveTitle(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        return isNew ? (zh ? "添加规则" : "Add rule") : (zh ? "保存规则" : "Save rule")
    }
}

/// 权限页的文案（不是 Botin 写的，不带 AI 生成标识）。
public enum PermissionsText {
    /// “自动审查”开关。
    public static func autoReview(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "自动审查" : "Auto-review"
    }

    /// 开关下面的说明（ThinkTin 自己的话；以前和参考 62 那句只差产品名）。
    public static func autoReviewDetail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "Botin 动手之前先拿下面的规则对一遍" : "Botins check each action against the rules below"
    }

    /// 组标题右边的小胶囊。
    public static func addRule(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "添加规则" : "Add rule"
    }

    /// 一组没有规则时的一行（参考 62）。
    public static func noRules(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "暂无规则" : "No rules yet"
    }

    /// 左滑删除。
    public static func delete(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "删除" : "Delete"
    }

    /// 修改页的红字（参考 64）。
    public static func deleteRule(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "删除规则" : "Delete rule"
    }

    /// 删除前确认的标题。
    public static func deleteConfirmation(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "删除这条规则？" : "Delete this rule?"
    }

    /// 表单里输入框的标题（参考 63）。
    public static func appliesTo(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "适用于" : "Applies to"
    }

    /// 输入框下面的脚注：怎么写一条规则（ThinkTin 自己的说法和例子，不照参考 63 的句式和邮件地址的例子）。
    public static func ruleFooter(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "一条只写一类操作。写得越具体，Botin 越不会判断错，比如“推送到 main 分支”。"
            : "Keep each rule to one kind of action. The more specific it is, the fewer wrong calls the Botin makes, "
                + "such as “pushing to the main branch”."
    }

    /// 太长了。
    public static func tooLong(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "最多 \(PermissionRuleDraft.maxLength) 个字。" : "Up to \(PermissionRuleDraft.maxLength) characters."
    }

    /// 页面最下面的说明：规则管不到哪些（规范 6.15：电脑上的高危操作不能被“自动允许”覆盖），现在是示例。
    public static func footer(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "电脑上的高危操作每次都要你在手机上确认，规则不能自动允许它们。现在列的是示例规则，按规则自动审查即将推出。"
            : "Risky actions on your computer always need your confirmation on this phone, and rules can't allow them "
                + "automatically. These are example rules; rule-based review is coming soon."
    }

    /// 进审批中心的一行（逐条批准，ThinkTin 现在的做法）。
    public static func approvalsDetail(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "逐条批准 Botin 要做的有风险的操作" : "Approve risky Botin actions one by one"
    }
}
