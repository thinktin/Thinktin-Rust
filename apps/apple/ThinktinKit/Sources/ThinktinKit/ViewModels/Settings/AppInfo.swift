import Foundation

/// 关于页（WBS 12.12；12.11、16.1）上的 App 信息：名字、版本号、构建号、备案号。
///
/// 版本号和构建号从 Info.plist 读（project.yml 的 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` 展开进
/// `CFBundleShortVersionString`、`CFBundleVersion`）。
public struct AppInfo: Hashable, Sendable {
    /// 品牌名（不用 Claude、Anthropic 的名字）。
    public static let appName = "ThinkTin"

    /// 版本号（`0.1.0`）；Info.plist 里没有时是“—”。
    public var version: String
    /// 构建号（`1`）。
    public var build: String
    /// App 备案号（工信部，16.1）：办下来之前是 nil，关于页显示“办理中”。
    public var icpFilingNumber: String?

    public init(version: String, build: String, icpFilingNumber: String? = AppInfo.icpFilingNumber) {
        self.version = version
        self.build = build
        self.icpFilingNumber = icpFilingNumber
    }

    /// 从 Info.plist 读；没有、为空、没展开（`$(MARKETING_VERSION)`）时是“—”。
    public init(infoDictionary: [String: Any]?) {
        self.init(
            version: Self.value(infoDictionary?["CFBundleShortVersionString"]),
            build: Self.value(infoDictionary?["CFBundleVersion"]))
    }

    /// 这个进程的 App（`Bundle.main`）。
    public static var current: AppInfo { AppInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// App 备案号：16.1 办下来后填在这里（形如“京ICP备XXXXXXXX号-XA”，和 App Store Connect 里填的一致）。
    public static let icpFilingNumber: String? = nil

    /// 工信部的备案查询网站（备案号要能点开去查，工信部要求在显著位置标明）。
    public static let icpLookupURL = URL(string: "https://beian.miit.gov.cn/")!

    /// “0.1.0（1）” / “0.1.0 (1)”。
    public func versionText(_ language: DisplayLanguage = .current) -> String {
        language == .chinese ? "\(version)（\(build)）" : "\(version) (\(build))"
    }

    /// 设置中心最底下的一行：“ThinkTin 0.1.0（1）”。
    public func footer(_ language: DisplayLanguage = .current) -> String {
        "\(Self.appName) \(versionText(language))"
    }

    /// 备案号那一行的值：办下来之前是“办理中”。
    public func icpFilingText(_ language: DisplayLanguage = .current) -> String {
        if let number = icpFilingNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty {
            return number
        }
        return language == .chinese ? "办理中" : "Pending"
    }

    /// 备案号办下来了（关于页给查询链接）。
    public var hasICPFiling: Bool {
        guard let number = icpFilingNumber?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !number.isEmpty
    }

    private static func value(_ raw: Any?) -> String {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
            !text.hasPrefix("$(")
        else { return "—" }
        return text
    }
}

/// 关于页的文案（WBS 12.12；docs/compliance.md 第 1 节、16.3）。
public enum AboutText {
    /// 品牌下面的一句话介绍。
    public static func tagline(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "领养云端的 agent，让它们替你做事。" : "Adopt agents in the cloud and let them get things done for you."
    }

    /// “AI 生成内容说明”的几段话：哪些内容是 AI 生成的、怎么标识、要注意什么。和服务端的标识（`proto::labels`）、
    /// 合规说明（docs/compliance.md）一致。
    public static func aiContentParagraphs(_ language: DisplayLanguage = .current) -> [String] {
        let label = language.aiGeneratedLabel
        if language == .chinese {
            return [
                "ThinkTin 里的 agent 由第三方大模型驱动。它们写的回复、思考过程、待办清单、运行摘要、计划、审批说明和产出物都是人工智能生成的内容。",
                "这些内容旁边都有“\(label)”标识；复制、分享时会带上标识，下载的文本产出物末尾也会注明由人工智能生成；系统通知里 agent 写的正文前面有“【AI 生成】”。平台不提供去掉标识的选项。",
                "AI 生成的内容可能不准确、不完整或已经过时，重要的事情请自己核实。agent 要做有风险的操作时会先请你审批。",
                "发现违法或不当的内容，长按那条回复或产出物选“举报”，我们会尽快处理并把结果发到你的收件箱。",
            ]
        }
        return [
            "Agents in ThinkTin are powered by third-party AI models. Their replies, reasoning, to-do lists, run "
                + "summaries, plans, approval requests and artifacts are AI-generated content.",
            "All of it is marked \"\(label)\". The label stays on when you copy or share, downloaded text artifacts "
                + "end with a note that they were AI-generated, and notification text written by an agent starts with "
                + "\"[AI-generated]\". The label can't be turned off.",
            "AI-generated content can be wrong, incomplete or out of date, so double-check anything important. Agents "
                + "ask for your approval before risky actions.",
            "If you see something illegal or inappropriate, long-press the reply or artifact and choose Report. We'll "
                + "review it and send the outcome to your inbox.",
        ]
    }
}
