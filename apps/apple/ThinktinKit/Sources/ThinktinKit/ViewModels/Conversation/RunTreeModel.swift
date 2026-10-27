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

/// 运行树（`.runTree(id)`：流水线、委派的子运行；`id` 是树里任意一个运行，页面定位到它所在的节点）。
///
/// 12.7 补上：单个节点停止（`stop`）、整棵树停止（`stopTree`，`cancelRun(wholeTree:)`）；子步骤在等用户处理（审批、key、
/// 电脑）时冒泡到页面顶上（`attention`）；还有没结束的运行时页面定时刷新，新加的子运行会出现。
@Observable @MainActor
public final class RunTreeModel {
    public let runID: RunID
    public private(set) var nodes: [RunTreeNode] = []
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isMissing = false
    /// 正在停止的运行（整树停止时是根）。
    public private(set) var stopping: Set<RunID> = []
    public private(set) var stopError: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, runID: RunID) {
        self.client = client
        self.runID = runID
    }

    /// 树里还有没结束的运行。
    public var hasActiveRuns: Bool { nodes.contains { $0.run.state.isActive } }

    /// 根运行。
    public var root: Run? { nodes.first?.run }

    /// 子孙里第一个在等用户处理的运行（审批、key、电脑）：冒泡到页面顶上，点了去它的运行详情。
    public var attention: Run? {
        nodes.first { node in
            node.depth > 0 && [.waitingApproval, .waitingQuota, .waitingDevice].contains(node.run.state)
        }?.run
    }

    /// 有没结束的运行时每隔 `interval` 刷新一次，都结束了就停（页面的 `.task` 跑，离开页面取消）。
    public func refreshWhileActive(every interval: Duration = .seconds(5)) async {
        while hasActiveRuns, !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// 只停这一个运行（服务端：流水线的根运行停了就是整条停）。
    public func stop(_ runID: RunID) async {
        await cancel(runID, wholeTree: false)
    }

    /// 整棵树都停。
    public func stopTree() async {
        guard let root else { return }
        await cancel(root.id, wholeTree: true)
    }

    public func clearStopError() {
        stopError = nil
    }

    private func cancel(_ runID: RunID, wholeTree: Bool) async {
        guard !stopping.contains(runID) else { return }
        stopping.insert(runID)
        stopError = nil
        defer { stopping.remove(runID) }
        do {
            _ = try await client.cancelRun(runID, wholeTree: wholeTree)
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            // 已经结束了（冲突）：刷新就能看到。
            if !failure.isConflict { stopError = failure }
        }
        await load()
    }

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
