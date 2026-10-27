import Foundation
import Observation

/// 开源许可页（WBS 12.12、16.5，`.licenses`，入口：设置 → 关于 → 开源许可）。三部分：
///
/// 1. agent 的许可证：`agents()` 的 `license`、`licenseNote`、`upstream`（目录里人写的说明，不是 agent 生成的，不带 AI 标识）；
/// 2. App 用的 Swift 包：现在没有第三方包（`SwiftPackageLicenses`），写明一句；
/// 3. 客户端核心（Rust）带的第三方组件：ThinktinCore 资源里的 `inventory.json`（`LicenseInventory`），按许可证分组，
///    点进去看原文；`NOTICES.md` 整份也能看。
///
/// 清单在本机，不联网也能看（`OfflinePolicy.local`）；agent 列表要联网，拉不到时只有那一节显示提示。
@Observable @MainActor
public final class LicensesModel {
    public enum InventoryState: Hashable, Sendable {
        case loading
        case loaded(LicenseInventory)
        case failed(LicenseInventoryError)
    }

    public private(set) var inventoryState: InventoryState = .loading
    public private(set) var agents: [AgentInfo] = []
    public private(set) var hasLoadedAgents = false
    public private(set) var isLoadingAgents = false
    public private(set) var agentsError: ClientError?
    /// 搜索框里的字。
    public var query = ""

    /// 清单目录（`CoreLicenses.locate()`）；nil 是 App 里没带。
    public let directory: URL?
    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, directory: URL?) {
        self.client = client
        self.directory = directory
    }

    // MARK: 加载

    /// 页面出现时（从组件详情返回也会再调）：清单（本机）和 agent 列表（联网）；都拉到过的不再拉，下拉刷新用 `loadAgents()`。
    public func load() async {
        await loadInventory()
        if !hasLoadedAgents { await loadAgents() }
    }

    /// 读清单（在后台线程上解析，几百个组件）。读过的不再读。
    public func loadInventory() async {
        if case .loaded = inventoryState { return }
        guard let directory else {
            inventoryState = .failed(.notBundled)
            return
        }
        inventoryState = .loading
        inventoryState = await Self.readInventory(in: directory)
    }

    /// 拉 agent 列表（下拉刷新、联网后）。
    public func loadAgents() async {
        guard !isLoadingAgents else { return }
        isLoadingAgents = true
        defer { isLoadingAgents = false }
        do {
            agents = try await client.agents()
            hasLoadedAgents = true
            agentsError = nil
        } catch is CancellationError {
            return
        } catch {
            agentsError = SettingsSupport.clientError(error)
        }
    }

    private nonisolated static func readInventory(in directory: URL) async -> InventoryState {
        await Task.detached(priority: .userInitiated) { () -> InventoryState in
            do {
                return .loaded(try LicenseInventory.load(from: directory))
            } catch let error as LicenseInventoryError {
                return .failed(error)
            } catch {
                return .failed(.malformed(String(describing: error)))
            }
        }.value
    }

    // MARK: 派生

    public var inventory: LicenseInventory? {
        if case .loaded(let inventory) = inventoryState { return inventory }
        return nil
    }

    /// 在搜。
    public var isSearching: Bool { !LicenseSearch.tokens(query).isEmpty }

    /// 客户端核心的组件，按许可证分组，按搜索词过滤。
    public var groups: [LicenseGroup] { inventory?.groups(matching: query) ?? [] }

    /// agent 的许可证，按搜索词过滤；目录里的顺序。
    public func agentEntries(_ language: DisplayLanguage = .current) -> [AgentLicenseEntry] {
        let tokens = LicenseSearch.tokens(query)
        return agents.map { AgentLicenseEntry(agent: $0, language: language) }
            .filter { tokens.isEmpty || $0.matches(tokens: tokens) }
    }

    /// App 用的第三方 Swift 包（现在没有），按搜索词过滤。
    public var swiftPackages: [LicenseComponent] {
        let tokens = LicenseSearch.tokens(query)
        return SwiftPackageLicenses.components.filter { tokens.isEmpty || $0.matches(tokens: tokens) }
    }

    /// 搜了但什么都没找到。
    public func hasNoResults(_ language: DisplayLanguage = .current) -> Bool {
        isSearching && groups.isEmpty && agentEntries(language).isEmpty && swiftPackages.isEmpty
    }

    /// 客户端核心那一节的说明：“289 个第三方组件，16 种许可证”。
    public func inventorySummary(_ language: DisplayLanguage = .current) -> String? {
        guard let inventory else { return nil }
        let components = inventory.components.count
        let licenses = inventory.licenseCount
        return language == .chinese
            ? "\(components) 个第三方组件，\(licenses) 种许可证。点开组件看许可证原文。"
            : "\(components) third-party \(components == 1 ? "component" : "components") under \(licenses) "
                + "\(licenses == 1 ? "license" : "licenses"). Open one to read its license text."
    }

    /// 能不能打开整份 `NOTICES.md`。
    public var noticesPath: String? {
        guard inventory != nil else { return nil }
        return LicenseInventory.noticesFileName
    }

    // MARK: 文案

    /// 页面顶上的说明。
    public nonisolated static func intro(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "ThinkTin 用到的开源软件和它们的许可证。感谢这些项目的作者。"
            : "The open-source software ThinkTin uses, and the licenses it comes under. Thanks to everyone who made it."
    }

    /// Swift 包那一节没有第三方包时的说明。
    public nonisolated static func noSwiftPackagesMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "App 目前没有用第三方 Swift 包：界面只用系统框架，网络、缓存这些都在下面的客户端核心里。"
            : "The app doesn't use any third-party Swift packages yet: the interface uses only system frameworks, and "
                + "networking and caching live in the client core below."
    }

    /// agent 那一节的说明。
    public nonisolated static func agentsFootnote(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "agent 在云端的沙箱里运行，不装在手机上。每个 agent 按它自己的许可证提供，专有许可的条款以上游为准。"
            : "Agents run in cloud sandboxes, not on your phone. Each one is provided under its own license; for "
                + "proprietary licenses, the upstream terms apply."
    }
}

/// agent 的许可证（开源许可页的第一节）。
public struct AgentLicenseEntry: Identifiable, Hashable, Sendable {
    public var id: AgentID
    /// 界面上的名字（商标规则：Claude 叫“Claude Agent”，`AgentsText.displayName`）。
    public var name: String
    /// 出处说明（“基于 Anthropic 的 Claude Agent SDK”）。
    public var byline: String?
    /// “v0.90.0”。
    public var version: String
    /// 许可证的显示名（`AgentsText.licenseName`）。
    public var licenseName: String
    /// 原始的 SPDX 写法（`Apache-2.0`、`LicenseRef-Anthropic-Commercial`）。
    public var spdx: String?
    public var isProprietary: Bool
    /// 许可说明（专有许可证必有，按请求语言给）。
    public var note: String?
    public var upstreamURL: URL?

    public init(agent: AgentInfo, language: DisplayLanguage = .current) {
        id = agent.id
        name = AgentsText.displayName(of: agent)
        byline = AgentsText.byline(of: agent.id, language: language)
        version = AgentsText.versionLabel(agent.version)
        licenseName = AgentsText.licenseName(agent.license, language: language)
        let spdx = agent.license?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.spdx = spdx?.isEmpty == false ? spdx : nil
        isProprietary = AgentsText.isProprietary(agent.license)
        let note = agent.licenseNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note?.isEmpty == false ? note : nil
        upstreamURL = agent.upstreamURL
    }

    func matches(tokens: [String]) -> Bool {
        let fields = [name, id.rawValue, licenseName, spdx ?? "", byline ?? ""]
        return tokens.allSatisfy { token in fields.contains { LicenseSearch.contains($0, token) } }
    }
}

/// 一份原文（或整份 `NOTICES.md`）的页面：在后台线程上读，分段显示。
@Observable @MainActor
public final class LicenseTextModel {
    public enum State: Hashable, Sendable {
        case loading
        case loaded(paragraphs: [String])
        case failed(LicenseInventoryError)
    }

    public private(set) var state: State = .loading
    /// 相对清单目录的路径。
    public let path: String
    @ObservationIgnored private let directory: URL?

    public init(path: String, directory: URL?) {
        self.path = path
        self.directory = directory
    }

    /// 读过的不再读。
    public func load() async {
        if case .loaded = state { return }
        guard let directory else {
            state = .failed(.notBundled)
            return
        }
        state = await Self.read(path, in: directory)
    }

    /// 全文（复制用）。
    public var fullText: String? {
        guard case .loaded(let paragraphs) = state else { return nil }
        return paragraphs.joined(separator: "\n\n")
    }

    private nonisolated static func read(_ path: String, in directory: URL) async -> State {
        await Task.detached(priority: .userInitiated) { () -> State in
            do {
                let paragraphs = LicenseFiles.paragraphs(try LicenseFiles.readText(path, in: directory))
                return .loaded(paragraphs: paragraphs)
            } catch let error as LicenseInventoryError {
                return .failed(error)
            } catch {
                return .failed(.unreadable(path))
            }
        }.value
    }
}
