import Foundation

/// Agent 目录、领养、实例详情（WBS 12.3）界面上的命名和文案：中英文都在这里，界面按 `DisplayLanguage` 取。
///
/// 命名按 docs/licenses.md 第 6 节第 2 条的商标要求：
/// - Claude 一律叫“Claude Agent”（Agent SDK 品牌指引允许的写法），不叫“Claude Code”，不用 Anthropic 的标志；
/// - Codex 只作为第三方 agent 的名字出现，旁边写“使用 OpenAI Codex”，不当成我们自己的产品名；
/// - 所有 agent 都不用对方的标志和图标：头像是名字的首字母（`monogram(of:)`）。
///
/// 目录里的介绍（`AgentInfo.description`）、许可说明是清单里人写的，不是 agent 生成的，不带 AI 生成标识；
/// agent 写的文字只有 agent 建的计划（`isAIGenerated(_:)`）会出现在这几页上。
public enum AgentsText {
    /// Claude 在目录里的 id（crates/catalog/manifests/claude.toml）。
    public static let claudeAgentID: AgentID = "claude"
    /// Codex 在目录里的 id。
    public static let codexAgentID: AgentID = "codex"
    /// Claude 在 App 里唯一允许的叫法。
    public static let claudeAgentName = "Claude Agent"

    // MARK: 名字

    /// agent 在界面上的名字：Claude 一律是“Claude Agent”；名字里写了“Claude Code”的换成“Claude Agent”；
    /// 服务端没给名字时用 id。
    public static func displayName(of agent: AgentInfo) -> String {
        displayName(agentID: agent.id, serverName: agent.name)
    }

    /// 只知道 agent 的 id（实例的 agent 已经不在目录里了）时的名字。
    public static func displayName(agentID: AgentID, serverName: String? = nil) -> String {
        if agentID == claudeAgentID { return claudeAgentName }
        let name = (serverName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return knownNames[agentID] ?? agentID.rawValue }
        if name.range(of: "Claude Code", options: .caseInsensitive) != nil {
            return name.replacingOccurrences(of: "Claude Code", with: claudeAgentName, options: .caseInsensitive)
        }
        return name
    }

    /// 实例的 agent 不在目录里时，按 id 认得出的几个名字（和清单一致）。
    static let knownNames: [AgentID: String] = [
        "codex": "Codex", "hermes": "Hermes Agent", "openclaw": "OpenClaw", "pi": "Pi",
    ]

    /// 名字下面的一行出处说明（商标要求的写法）：Claude 写明基于 Anthropic 的 Agent SDK，Codex 写“使用 OpenAI Codex”。
    /// 别的 agent 没有，为 nil。
    public static func byline(of agentID: AgentID, language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch agentID {
        case claudeAgentID: return zh ? "基于 Anthropic 的 Claude Agent SDK" : "Built on Anthropic's Claude Agent SDK"
        case codexAgentID: return zh ? "使用 OpenAI Codex" : "Uses OpenAI Codex"
        default: return nil
        }
    }

    /// 头像上的字：名字的第一个字（字母大写）。不用对方的标志。
    public static func monogram(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    // MARK: 版本、许可证、接入方式、协议

    /// “v0.90.0”：数字开头的版本号前面加 v，别的原样。
    public static func versionLabel(_ version: String) -> String {
        guard let first = version.first, first.isNumber else { return version }
        return "v" + version
    }

    /// 专有许可（`LicenseRef-…`）：领养前要把许可说明给用户看。
    public static func isProprietary(_ license: String?) -> Bool {
        license?.hasPrefix("LicenseRef-") ?? false
    }

    /// 许可证的显示名：SPDX 原样（“Apache-2.0”），Anthropic 的专有条款、别的 `LicenseRef-…` 写成人话，没写的写“未注明”。
    public static func licenseName(_ license: String?, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        let license = (license ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if license.isEmpty { return zh ? "未注明许可证" : "License not specified" }
        if license == "LicenseRef-Anthropic-Commercial" {
            return zh ? "Anthropic 商业条款（专有）" : "Anthropic commercial terms (proprietary)"
        }
        if isProprietary(license) { return zh ? "专有许可" : "Proprietary license" }
        return license
    }

    /// 接入方式的显示名（`acp`、`cli`；认不出的原样）。
    public static func harnessName(_ harness: String, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch harness {
        case "acp": return zh ? "ACP 适配器" : "ACP adapter"
        case "cli": return zh ? "命令行" : "Command line"
        default: return harness
        }
    }

    /// 接入方式的一句说明（领养表单里选的时候看）。
    public static func harnessDetail(_ harness: String, language: DisplayLanguage = .current) -> String? {
        let zh = language == .chinese
        switch harness {
        case "acp":
            return zh
                ? "通过 ACP（Agent Client Protocol）适配器运行。"
                : "Runs through an ACP (Agent Client Protocol) adapter."
        case "cli":
            return zh ? "直接运行 agent 的命令行模式。" : "Runs the agent's command-line mode directly."
        default:
            return nil
        }
    }

    /// 模型接口的显示名。
    public static func protocolName(_ modelProtocol: ModelProtocol) -> String {
        switch modelProtocol {
        case .anthropic: "Anthropic Messages"
        case .chat: "OpenAI Chat Completions"
        case .responses: "OpenAI Responses"
        case .unknown(let raw): raw
        }
    }

    /// 能用的地区（`sites`）的显示名。
    public static func siteName(_ site: String, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch site {
        case "cn": return zh ? "中国大陆" : "Mainland China"
        case "global": return zh ? "海外" : "Outside mainland China"
        default: return site
        }
    }

    /// 用顿号（中文）或逗号（英文）连起来。
    public static func list(_ items: [String], language: DisplayLanguage = .current) -> String {
        items.joined(separator: language == .chinese ? "、" : ", ")
    }

    // MARK: 实例状态

    /// 实例状态的说明（docs/architecture-v3.md 4.10 的休眠与唤醒）：这个状态是什么意思、下任务会怎样。
    public static func stateExplanation(_ state: InstanceState, language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch state {
        case .provisioning:
            return zh
                ? "正在创建沙箱，第一次通常要一两分钟。这期间下的任务会先排队，创建好就开始。"
                : "Setting up the sandbox. The first time usually takes a minute or two; tasks you send meanwhile "
                    + "wait in line and start once it's ready."
        case .running:
            return zh ? "沙箱正在运行，随时可以接任务。" : "The sandbox is running and ready for tasks."
        case .paused:
            return zh
                ? "空闲一段时间后，沙箱存成了内存快照。下任务、计划到点时会自动唤醒，通常几秒就好。"
                : "After sitting idle, the sandbox was saved as a memory snapshot. It wakes up on its own when you "
                    + "send a task or a plan fires, usually within seconds."
        case .archived:
            return zh
                ? "7 天没有活动，只留下了工作区。下任务、计划到点时会从模板重建沙箱，会慢一些，工作区里的文件都在。"
                : "After 7 days without activity, only the workspace was kept. The next task or plan rebuilds the "
                    + "sandbox from its template, which takes a little longer; files in the workspace are kept."
        case .deleted:
            return zh ? "这个实例已经删除了。" : "This instance has been deleted."
        case .unknown:
            return zh ? "状态暂时认不出，可以稍后刷新再看。" : "This status isn't recognized yet. Refresh later to check again."
        }
    }

    // MARK: AI 生成标识（这几页上的规则）

    /// 计划的标题和目标要不要带 AI 生成标识：agent 建的（`createdBy == .agent`）要带，用户自己建的不带
    /// （ios-packages.md 12.5 “AI 生成标识要有一张规则表”）。
    public static func isAIGenerated(_ plan: Plan) -> Bool {
        plan.createdBy == .agent
    }
}

// MARK: - 实例名字的规则

/// 实例名字的问题（领养、改名时本地先查，和服务端一致：去掉首尾空白后 1 到 64 个字符）。
public enum InstanceNameProblem: Hashable, Sendable {
    case empty
    case tooLong(max: Int)

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .empty: return zh ? "起个名字吧。" : "Give it a name."
        case .tooLong(let max): return zh ? "名字最多 \(max) 个字。" : "Names can be up to \(max) characters."
        }
    }
}

/// 实例名字的规则。
public enum InstanceNameRule {
    /// 最长几个字符（服务端按 Unicode 标量数，和 `chars().count` 一致）。
    public static let maxLength = 64

    /// 去掉首尾空白。
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 名字有什么问题；没问题为 nil。
    public static func problem(_ name: String) -> InstanceNameProblem? {
        let name = normalized(name)
        if name.isEmpty { return .empty }
        if name.unicodeScalars.count > maxLength { return .tooLong(max: maxLength) }
        return nil
    }
}

// MARK: - 错误

/// 视图模型里把调用失败转成界面显示的错误。
enum AgentsErrors {
    /// 任务被取消（页面关了）返回 nil，不算出错；不是 `ClientError` 的按内部错误。
    static func from(_ error: any Error) -> ClientError? {
        if error is CancellationError { return nil }
        return (error as? ClientError) ?? .internal(message: String(describing: error))
    }

    /// 并发拉取时把结果包成 `Result`（`async let` 里用）。
    nonisolated static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
