import Foundation
import Observation

/// Agent 目录（WBS 12.3）：`agents()` 的列表，每个 agent 一张卡片（名字、版本、许可证、接入方式）。
///
/// 目录不缓存（docs/ios.md 第 6.2 节：离线时“暂无数据”）：拉不到时留着上次拉到的，错误给界面显示；
/// 联网后界面再调一次 `load()`。
@Observable @MainActor
public final class AgentCatalogModel {
    /// 目录里的 agent，按服务端的顺序。
    public private(set) var agents: [AgentInfo]
    /// 拉到过一次（区分“加载中”和“目录是空的”）。
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 最近一次拉取的错误；成功后清掉。
    public private(set) var error: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    /// - Parameter agents: 已经有的目录（比如别的页面拉过的），先显示它。
    public init(client: any ClientProtocol, agents: [AgentInfo] = []) {
        self.client = client
        self.agents = agents
    }

    /// 拉目录（打开页面、下拉刷新、联网后）。正在拉时再调直接返回。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            agents = try await client.agents()
            hasLoaded = true
            error = nil
        } catch {
            if let failure = AgentsErrors.from(error) { self.error = failure }
        }
    }

    /// 拉过了，目录是空的。
    public var isEmpty: Bool { hasLoaded && agents.isEmpty }

    /// 还没有可以显示的（第一次在拉，或者拉失败了）。
    public var hasNothingToShow: Bool { agents.isEmpty }

    public func agent(_ id: AgentID) -> AgentInfo? {
        agents.first { $0.id == id }
    }

    /// 目录的卡片。`instances` 是当前账号的实例（卡片上写“N 个 Botin 在用”）。
    public func cards(instances: [Instance], language: DisplayLanguage = .current) -> [AgentCatalogCard] {
        let counts = Self.adoptedCounts(instances)
        return agents.map { AgentCatalogCard(agent: $0, adoptedCount: counts[$0.id] ?? 0, language: language) }
    }

    /// 每个 agent 领养了几个实例（已删除的不算）。
    public static func adoptedCounts(_ instances: [Instance]) -> [AgentID: Int] {
        instances.filter { $0.state != .deleted }.reduce(into: [:]) { $0[$1.agentID, default: 0] += 1 }
    }
}

/// 目录里的一张卡片（界面直接显示这些字段）。
public struct AgentCatalogCard: Identifiable, Hashable, Sendable {
    public var id: AgentID
    /// 按商标要求处理过的名字（`AgentsText.displayName(of:)`）。
    public var name: String
    /// 头像上的字。
    public var monogram: String
    /// 名字下面的出处说明（Claude、Codex 才有）。
    public var byline: String?
    /// 一句话介绍（老的服务端为空）。
    public var summary: String
    /// “v0.90.0”。
    public var versionLabel: String
    public var licenseLabel: String
    /// 专有许可：卡片上的许可证标签换成提醒的样子。
    public var isProprietary: Bool
    /// 接入方式，默认的在前。
    public var harnessLabels: [String]
    /// 已经领养了几个。
    public var adoptedCount: Int
    /// 能不能用来新建 Botin（`AgentInfo.canPowerNewBotin`）：不能的，列表行右边的按钮灰掉。
    public var isAvailable: Bool

    public init(agent: AgentInfo, adoptedCount: Int = 0, language: DisplayLanguage = .current) {
        id = agent.id
        name = AgentsText.displayName(of: agent)
        monogram = AgentsText.monogram(of: name)
        byline = AgentsText.byline(of: agent.id, language: language)
        summary = agent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        versionLabel = AgentsText.versionLabel(agent.version)
        licenseLabel = AgentsText.licenseName(agent.license, language: language)
        isProprietary = AgentsText.isProprietary(agent.license)
        harnessLabels = agent.catalogHarnesses.map { AgentsText.harnessName($0, language: language) }
        self.adoptedCount = adoptedCount
        isAvailable = agent.canPowerNewBotin
    }

    /// 列表行名字下面的灰字（参考 101、104 的行：最多两行）：一句话介绍，老的服务端没有介绍时用出处。
    public var rowSubtitle: String {
        summary.isEmpty ? (byline ?? "") : summary
    }

    /// 列表行右边的小胶囊（参考的“连接”位置）：“选这个”，点了用它新建 Botin（在新建表单里时换成它）；不能用的“暂不可用”。
    public func actionTitle(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        if !isAvailable { return zh ? "暂不可用" : "Unavailable" }
        return zh ? "选这个" : "Use"
    }

    /// 小胶囊的读屏标签：“用 Claude Agent 新建 Botin”。
    public func actionAccessibilityLabel(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        if !isAvailable { return zh ? "\(name) 暂不可用" : "\(name) is unavailable" }
        return zh ? "用 \(name) 新建 Botin" : "Create a Botin with \(name)"
    }

    /// “2 个 Botin 在用”（用它当引擎的 Botin 数）；还没有 Botin 用它时为 nil。
    public func adoptedLabel(_ language: DisplayLanguage = .current) -> String? {
        guard adoptedCount > 0 else { return nil }
        if language == .chinese { return "\(adoptedCount) 个 Botin 在用" }
        return adoptedCount == 1 ? "Used by 1 Botin" : "Used by \(adoptedCount) Botins"
    }

    /// 读屏念的一句话：名字、出处、版本、许可证、接入方式、几个 Botin 在用。
    public func accessibilityLabel(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        var parts = [name]
        if let byline { parts.append(byline) }
        parts.append((zh ? "版本 " : "version ") + versionLabel)
        parts.append((zh ? "许可证 " : "license ") + licenseLabel)
        if !harnessLabels.isEmpty {
            parts.append((zh ? "接入方式 " : "runs via ") + AgentsText.list(harnessLabels, language: language))
        }
        if let adopted = adoptedLabel(language) { parts.append(adopted) }
        return parts.joined(separator: zh ? "，" : ", ")
    }
}

extension AgentInfo {
    /// 接入方式，默认的排第一个（领养表单默认选它）。
    public var catalogHarnesses: [String] {
        guard harnesses.contains(defaultHarness) else { return harnesses }
        return [defaultHarness] + harnesses.filter { $0 != defaultHarness }
    }

    /// 可以用的版本，最新的在前；服务端没给列表时只有当前版本。
    public var catalogVersions: [String] {
        versions.isEmpty ? [version] : versions
    }

    /// 最新的版本（`versions` 的第一个，没有时是 `version`）。
    public var catalogLatestVersion: String {
        versions.first ?? version
    }
}
