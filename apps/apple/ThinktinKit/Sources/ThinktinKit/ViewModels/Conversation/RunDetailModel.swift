import Foundation
import Observation

/// 运行详情（`.run(id)`：时间线里的状态行、收件箱、推送 `tt.run`、计划的运行历史进来，docs/ios-packages.md 12.5
/// “运行详情页”）：状态和说明、来源、所属计划、尝试次数、已用 token、时间、摘要（AI 生成标识）、失败原因、产出物、
/// 停止 / 停止整棵树、运行树入口、“只看本次过程”。
///
/// - 先找缓存（`cachedRuns`，离线也能看），再拉 `getRun`；知道了实例就建一个只看这个运行的 `ConversationModel`
///   （`process`）订阅事件流：状态跟着事件变，“只看本次过程”直接用它。
/// - 产出物（`runArtifacts`）、运行树（`runTree`，有子运行时才有入口）、计划（`getPlan`）拉不到不影响页面。
@Observable @MainActor
public final class RunDetailModel {
    public let runID: RunID
    /// 只看这个运行的过程（知道实例之后才有）：状态、用量跟着事件流变。
    public private(set) var process: ConversationModel?
    /// 拉到的运行记录（`process` 有了以后以它里面的为准，见 `run`）。
    public private(set) var fetchedRun: Run?
    public private(set) var artifacts: [Artifact]?
    /// 整棵运行树（只有自己一个时不显示入口）。
    public private(set) var tree: [Run]?
    public private(set) var plan: Plan?
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    /// 拉不到附加信息（产出物、运行树、计划）时的第一个错误。
    public private(set) var detailsError: ClientError?
    public private(set) var isMissing = false
    public private(set) var isStopping = false
    public private(set) var stopError: ClientError?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let biometricGate: any BiometricGate
    @ObservationIgnored private let now: () -> Date
    /// 先在这几个实例的缓存里找（应用框架的实例列表）。
    @ObservationIgnored private let instanceHints: [InstanceID]

    /// - Parameters:
    ///   - run: 已经有的运行记录（从对话、进行中点进来时），先显示它。
    ///   - instanceHints: 缓存里先找这几个实例的运行（应用框架的实例列表）。
    public init(
        client: any ClientProtocol, runID: RunID, run: Run? = nil, instanceHints: [InstanceID] = [],
        biometricGate: any BiometricGate = PassthroughBiometricGate(), now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.runID = runID
        self.fetchedRun = run?.id == runID ? run : nil
        self.instanceHints = instanceHints
        self.biometricGate = biometricGate
        self.now = now
    }

    // MARK: 显示

    /// 现在的运行记录：事件流更新过的优先。
    public var run: Run? { process?.runs[runID] ?? fetchedRun }

    /// 这个运行那一组（状态行、最近一次用量）。
    public var turn: ConversationTurn? { process?.turn(for: runID) }

    /// 现在的状态：归并出来的（事件流最新的）优先。
    public var state: RunState? { turn?.state ?? run?.state }

    /// 状态行（等待原因、等待原因码、尝试次数）。
    public var statusLine: RunStatusLine? {
        if let line = turn?.items.last.flatMap({ item -> RunStatusLine? in
            if case .runStatus(let line) = item.content { return line }
            return nil
        }) {
            return line
        }
        guard let run else { return nil }
        return RunStatusLine(
            state: run.state, reason: run.stateReason, attempt: run.attempt, tokensUsed: run.tokensUsed,
            error: run.error, startedAt: run.startedAt, finishedAt: run.finishedAt, waitCode: run.waitCode)
    }

    /// 还没结束：可以停止。
    public var canStop: Bool { state?.isActive ?? false }

    /// 有子运行（流水线、委派）：显示运行树入口。
    public var hasTree: Bool { (tree?.count ?? 0) > 1 }

    /// 树里还有没结束的子运行：可以停止整棵树。
    public var canStopTree: Bool {
        hasTree && (tree?.contains { $0.id != runID && $0.state.isActive } ?? false)
    }

    /// 任务要不要带 AI 生成标识（委派、流水线步骤、agent 建的计划触发的）。
    public var promptIsAIGenerated: Bool {
        guard let run else { return false }
        return AIGeneratedField.prompt(of: run, planAuthor: plan?.createdBy).isAIGenerated
    }

    /// 用时（开始到结束，还没结束到现在）。
    public var duration: TimeInterval? { run?.duration(now: now()) }

    /// 最近一轮的用量（`agent.usage` 的 input / output tokens）。
    public var lastUsage: (input: Int?, output: Int?)? {
        guard let usage = turn?.lastUsage else { return nil }
        let input = usage["input_tokens"]?.intValue ?? usage["inputTokens"]?.intValue
        let output = usage["output_tokens"]?.intValue ?? usage["outputTokens"]?.intValue
        if input == nil && output == nil { return nil }
        return (input, output)
    }

    // MARK: 加载

    /// 打开页面、下拉刷新。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if fetchedRun == nil { fetchedRun = findCachedRun() }
        do {
            fetchedRun = try await client.getRun(runID)
            error = nil
            isMissing = false
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound {
                isMissing = true
            } else {
                self.error = failure
            }
        }
        if let run = fetchedRun, !isMissing {
            if process == nil {
                process = ConversationModel(
                    client: client, instanceID: run.instanceID, focusRunID: runID, biometricGate: biometricGate,
                    now: now)
            }
            await process?.start()
            await loadDetails(run)
        }
        hasLoaded = true
    }

    /// 缓存里找：先找给了的几个实例，再找缓存里的其余实例。
    private func findCachedRun() -> Run? {
        func find(in ids: [InstanceID]) -> Run? {
            for id in ids {
                if let run = (try? client.cachedRuns(instanceID: id, limit: 200))?.first(where: { $0.id == runID }) {
                    return run
                }
            }
            return nil
        }
        if let run = find(in: instanceHints) { return run }
        let others = ((try? client.cachedInstances()) ?? []).map(\.id).filter { !instanceHints.contains($0) }
        return find(in: others)
    }

    private func loadDetails(_ run: Run) async {
        let client = self.client
        let id = runID
        async let artifacts = ConversationTasks.attempt { try await client.runArtifacts(id) }
        async let tree = ConversationTasks.attempt { try await client.runTree(id) }
        var errors: [ClientError] = []
        switch await artifacts {
        case .success(let list): self.artifacts = list.sorted { $0.createdAt < $1.createdAt }
        case .failure(let error): if let e = ConversationErrors.from(error) { errors.append(e) }
        }
        switch await tree {
        case .success(let list): self.tree = list
        case .failure(let error): if let e = ConversationErrors.from(error) { errors.append(e) }
        }
        if let planID = run.planID {
            do {
                plan = try await client.getPlan(planID)
            } catch {
                // 计划删掉了：不算出错，只是没有链接。
                if let e = ConversationErrors.from(error), !e.isNotFound { errors.append(e) }
            }
        }
        detailsError = errors.first
    }

    // MARK: 停止

    /// 停止这个运行；`wholeTree` 时连同整棵运行树（流水线、委派的子运行）。
    public func stop(wholeTree: Bool) async {
        guard !isStopping else { return }
        isStopping = true
        stopError = nil
        defer { isStopping = false }
        do {
            fetchedRun = try await client.cancelRun(runID, wholeTree: wholeTree)
            if let process { await process.fetchRuns([runID]) }
            if wholeTree, let list = try? await client.runTree(runID) { tree = list }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isConflict {
                if let fresh = try? await client.getRun(runID) { fetchedRun = fresh }
            } else {
                stopError = failure
            }
        }
    }

    public func clearStopError() {
        stopError = nil
    }
}

/// 并发拉取时把结果包成 `Result`（`async let` 里用）。
enum ConversationTasks {
    nonisolated static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
