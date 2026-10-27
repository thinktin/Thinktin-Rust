import Foundation
import Observation

/// 搜索结果的种类（分组显示的顺序）。
public enum SearchKind: String, CaseIterable, Hashable, Sendable {
    case instance, run, inbox, plan, artifact
}

/// 一条搜索结果：标题、匹配到的那一段（`snippet`）、点开去哪。
public struct SearchResult: Identifiable, Hashable, Sendable {
    public var kind: SearchKind
    public var key: String
    public var title: String
    /// 匹配到的那一段（标题里没匹配到时，从正文里截一段），或者补充说明（实例名、时间）。
    public var snippet: String?
    /// 标题或片段是 agent 写的（运行的摘要、委派的任务、产出物名、agent 建的计划、收件箱里标了的）：带“AI 生成”标识。
    public var isAIGenerated: Bool
    public var date: Date?
    public var route: AppRoute

    public var id: String { "\(kind.rawValue)-\(key)" }

    public init(
        kind: SearchKind, key: String, title: String, snippet: String? = nil, isAIGenerated: Bool = false,
        date: Date? = nil, route: AppRoute
    ) {
        self.kind = kind
        self.key = key
        self.title = title
        self.snippet = snippet
        self.isAIGenerated = isAIGenerated
        self.date = date
        self.route = route
    }
}

/// 一组结果（只放前 `limit` 条，`total` 是一共几条）。
public struct SearchGroup: Identifiable, Hashable, Sendable {
    public var kind: SearchKind
    public var results: [SearchResult]
    public var total: Int

    public var id: SearchKind { kind }
}

/// 搜索（WBS 12.21，`.search`）：在本机缓存里搜实例（名字）、运行（任务、摘要）、收件箱（标题、正文）；计划、产出物本机没有缓存，
/// 联网时打开页面拉一次放在内存里一起搜（离线时只搜缓存，页面上说一声）。
///
/// 关键词按空白拆开，每个词都要出现（不分大小写、全角半角、变音符号）；标题匹配的排前面，同一档按时间新的在前。
/// 每组最多显示 `groupLimit` 条。
@Observable @MainActor
public final class SearchModel {
    public var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    public private(set) var groups: [SearchGroup] = []
    /// 计划、产出物拉到了（联网时）。
    public private(set) var hasOnlineSources = false
    public private(set) var isLoadingOnline = false

    public static let groupLimit = 20
    /// 每个实例最多搜多少条缓存的运行。
    public static let runsPerInstance = 200
    public static let inboxLimit = 500

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private var instances: [Instance] = []
    @ObservationIgnored private var runs: [Run] = []
    @ObservationIgnored private var inbox: [InboxItem] = []
    @ObservationIgnored private var plans: [Plan] = []
    @ObservationIgnored private var artifacts: [Artifact] = []
    @ObservationIgnored private var hasLoadedCache = false

    public init(client: any ClientProtocol) {
        self.client = client
    }

    public var isSearching: Bool { !Self.terms(query).isEmpty }

    public var isEmpty: Bool { groups.isEmpty }

    /// 读本机缓存（很快，同步）。
    public func loadCache() {
        instances = ((try? client.cachedInstances()) ?? []).filter { $0.state != .deleted }
        runs = instances.flatMap { (try? client.cachedRuns(instanceID: $0.id, limit: Self.runsPerInstance)) ?? [] }
        inbox = (try? client.cachedInbox(before: nil, limit: Self.inboxLimit)) ?? []
        hasLoadedCache = true
        refresh()
    }

    /// 联网时拉计划、各实例的产出物（失败了就只搜缓存）。
    public func loadOnline() async {
        guard !isLoadingOnline else { return }
        if !hasLoadedCache { loadCache() }
        isLoadingOnline = true
        defer { isLoadingOnline = false }
        let client = self.client
        let ids = instances.map(\.id)
        guard let plans = try? await client.plans(instanceID: nil) else { return }
        var artifacts: [Artifact] = []
        for id in ids {
            if let list = try? await client.instanceArtifacts(id, limit: 100) { artifacts += list }
        }
        self.plans = plans
        self.artifacts = artifacts
        hasOnlineSources = true
        refresh()
    }

    private func refresh() {
        let terms = Self.terms(query)
        guard !terms.isEmpty else {
            groups = []
            return
        }
        let names = Dictionary(instances.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var all: [SearchKind: [(SearchResult, Int)]] = [:]
        func add(_ result: SearchResult, rank: Int) { all[result.kind, default: []].append((result, rank)) }

        for instance in instances {
            if let rank = Self.rank(terms, title: instance.name, body: "") {
                add(
                    SearchResult(
                        kind: .instance, key: instance.id.rawValue, title: instance.name, date: instance.lastActiveAt,
                        route: .conversation(instance.id)), rank: rank)
            }
        }
        for run in runs {
            let summary = run.summary ?? ""
            guard let rank = Self.rank(terms, title: run.prompt, body: summary) else { continue }
            let promptMatches = Self.matches(terms, in: run.prompt)
            let snippet = promptMatches ? names[run.instanceID] : Self.snippet(summary, terms: terms)
            add(
                SearchResult(
                    kind: .run, key: run.id.rawValue, title: Self.firstLine(run.prompt), snippet: snippet,
                    isAIGenerated: promptMatches
                        ? AIGeneratedField.prompt(of: run).isAIGenerated : AIGeneratedField.runSummary.isAIGenerated,
                    date: run.createdAt, route: .run(run.id)), rank: rank)
        }
        for item in inbox {
            guard let rank = Self.rank(terms, title: item.title, body: item.body) else { continue }
            add(
                SearchResult(
                    kind: .inbox, key: item.id.rawValue, title: item.title,
                    snippet: Self.matches(terms, in: item.title) ? nil : Self.snippet(item.body, terms: terms),
                    isAIGenerated: item.isAIGenerated, date: item.createdAt, route: .inboxItem(item.id)), rank: rank)
        }
        for plan in plans {
            guard let rank = Self.rank(terms, title: plan.title, body: plan.goal) else { continue }
            add(
                SearchResult(
                    kind: .plan, key: plan.id.rawValue, title: plan.title,
                    snippet: Self.matches(terms, in: plan.title)
                        ? names[plan.instanceID] : Self.snippet(plan.goal, terms: terms),
                    isAIGenerated: AIGeneratedField.planTitle(createdBy: plan.createdBy).isAIGenerated,
                    date: plan.createdAt, route: .plan(plan.id)), rank: rank)
        }
        for artifact in artifacts {
            guard let rank = Self.rank(terms, title: artifact.name, body: "") else { continue }
            add(
                SearchResult(
                    kind: .artifact, key: artifact.id.rawValue, title: artifact.name,
                    snippet: names[artifact.instanceID],
                    isAIGenerated: AIGeneratedField.artifactName.isAIGenerated, date: artifact.createdAt,
                    route: .artifact(artifact.id, runID: artifact.runID)), rank: rank)
        }

        groups = SearchKind.allCases.compactMap { kind in
            guard let list = all[kind], !list.isEmpty else { return nil }
            let sorted = list.sorted { a, b in
                a.1 != b.1 ? a.1 < b.1 : (a.0.date ?? .distantPast) > (b.0.date ?? .distantPast)
            }
            return SearchGroup(kind: kind, results: sorted.prefix(Self.groupLimit).map(\.0), total: sorted.count)
        }
    }

    // MARK: 匹配

    /// 关键词：按空白拆开，去掉空的。
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func matches(_ terms: [String], in text: String) -> Bool {
        !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: options) != nil }
    }

    /// 排序档：0 是标题里全有，1 是标题和正文合起来全有；都没有为 nil。
    static func rank(_ terms: [String], title: String, body: String) -> Int? {
        if matches(terms, in: title) { return 0 }
        if terms.allSatisfy({
            title.range(of: $0, options: options) != nil || body.range(of: $0, options: options) != nil
        }) {
            return 1
        }
        return nil
    }

    /// 正文里第一个关键词附近的一段（前后各留一些，最长约 80 个字）。
    static func snippet(_ text: String, terms: [String], radius: Int = 30) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let hit = terms.lazy.compactMap({ flat.range(of: $0, options: options) }).first else { return nil }
        let start = flat.index(hit.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(hit.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        let piece = flat[start..<end].trimmingCharacters(in: .whitespaces)
        return (start > flat.startIndex ? "…" : "") + piece + (end < flat.endIndex ? "…" : "")
    }

    static func firstLine(_ text: String) -> String {
        let line =
            text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }
}

/// 搜索的文案。
public enum SearchText {
    public static func groupTitle(_ kind: SearchKind, language: DisplayLanguage) -> String {
        let zh = language == .chinese
        switch kind {
        case .instance: return zh ? "实例" : "Instances"
        case .run: return zh ? "运行" : "Runs"
        case .inbox: return zh ? "收件箱" : "Inbox"
        case .plan: return zh ? "计划" : "Plans"
        case .artifact: return zh ? "产出物" : "Files"
        }
    }

    public static func more(_ count: Int, language: DisplayLanguage) -> String {
        language == .chinese ? "还有 \(count) 条，换个更具体的词试试" : "\(count) more. Try a more specific search."
    }

    public static func prompt(_ language: DisplayLanguage) -> String {
        language == .chinese ? "搜实例、任务、收件箱、计划、产出物" : "Search instances, tasks, inbox, plans, files"
    }

    public static func hint(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "在这台设备上的缓存里搜，没联网也能用。几个词用空格隔开，要都出现才算。"
            : "Searches what's cached on this device, so it works offline. Separate words with spaces; all must match."
    }

    public static func cacheOnly(_ language: DisplayLanguage) -> String {
        language == .chinese
            ? "没联网：只搜了缓存，计划和产出物要联网才能搜到。"
            : "Offline: only cached items were searched. Plans and files need a connection."
    }

    public static func noResults(_ query: String, language: DisplayLanguage) -> String {
        language == .chinese ? "没有找到“\(query)”" : "No results for “\(query)”"
    }
}
