import Foundation
import Observation

/// 运行树里的一个节点（按深度优先排好，`depth` 用来缩进）。
public struct RunTreeNode: Identifiable, Hashable, Sendable {
    public var run: Run
    /// 第几层（根是 0）。
    public var depth: Int
    /// 直接的子运行有几个。
    public var childCount: Int
    /// 是打开页面时指定的那个运行（高亮）。
    public var isFocus: Bool

    public var id: RunID { run.id }

    public init(run: Run, depth: Int, childCount: Int, isFocus: Bool) {
        self.run = run
        self.depth = depth
        self.childCount = childCount
        self.isFocus = isFocus
    }

    /// 节点的标题：流水线步骤名，或者任务的第一行（最长 80 个字符）。
    public var title: String {
        if let step = run.stepKey, !step.isEmpty { return step }
        let first = run.prompt.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let line = first.trimmingCharacters(in: .whitespaces)
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    /// 标题要不要带 AI 生成标识（委派的任务是负责人 agent 写的；流水线步骤用的是步骤名，不标）。
    public var titleIsAIGenerated: Bool {
        (run.stepKey ?? "").isEmpty && AIGeneratedField.prompt(of: run).isAIGenerated
    }
}

/// 运行树（`.runTree(id)`：流水线、委派的子运行；`id` 是树里任意一个运行，页面定位到它所在的节点）。12.7 的流水线
/// 编辑器复用它，补流水线节点。
@Observable @MainActor
public final class RunTreeModel {
    public let runID: RunID
    public private(set) var nodes: [RunTreeNode] = []
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isMissing = false

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, runID: RunID) {
        self.client = client
        self.runID = runID
    }

    /// 树里还有没结束的运行。
    public var hasActiveRuns: Bool { nodes.contains { $0.run.state.isActive } }

    /// 根运行。
    public var root: Run? { nodes.first?.run }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            nodes = Self.build(try await client.runTree(runID), focus: runID)
            error = nil
            isMissing = nodes.isEmpty
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound {
                isMissing = true
            } else {
                self.error = failure
            }
        }
        hasLoaded = true
    }

    /// 平铺的运行排成树（深度优先，同一层按创建时间）。找不到父运行的（父运行不在结果里）当成根。
    public static func build(_ runs: [Run], focus: RunID?) -> [RunTreeNode] {
        let ids = Set(runs.map(\.id))
        var children: [RunID: [Run]] = [:]
        var roots: [Run] = []
        for run in runs {
            if let parent = run.parentRunID, ids.contains(parent), parent != run.id {
                children[parent, default: []].append(run)
            } else {
                roots.append(run)
            }
        }
        func ordered(_ list: [Run]) -> [Run] {
            list.sorted { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }
        }
        var out: [RunTreeNode] = []
        var visited: Set<RunID> = []
        func visit(_ run: Run, depth: Int) {
            guard visited.insert(run.id).inserted else { return }
            let kids = ordered(children[run.id] ?? [])
            out.append(RunTreeNode(run: run, depth: depth, childCount: kids.count, isFocus: run.id == focus))
            for kid in kids { visit(kid, depth: depth + 1) }
        }
        for root in ordered(roots) { visit(root, depth: 0) }
        return out
    }
}
