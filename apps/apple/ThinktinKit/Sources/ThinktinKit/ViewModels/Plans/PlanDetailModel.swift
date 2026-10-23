import Foundation
import Observation

/// 计划详情（WBS 12.6，深链 `thinktin://plan/{id}`）：目标、触发规则（下一次 / 上一次，规则失效的标红并给
/// “修改规则”）、策略、流水线步骤（只读，编辑在 12.7）、运行历史、暂停 / 恢复、删除。
///
/// - 运行历史用 `listRuns(filter: .plan(id))`（11.8，服务端按计划过滤，跨实例，流水线的步骤在别的实例上跑也列得全），
///   只要根运行（一次触发一行，步骤在运行树里看），按 `before` 往下翻。
/// - 等确认的计划不能直接恢复：`canResume` 为 false，界面给“去确认”（`confirmPlan` 带 revision）。
/// - 流水线有步骤在已删除的实例上（11.9）：恢复报 409，查一次实例列表认出来（`blockedSteps`），说要先改步骤，不说
///   “内容被改过了”（`PlanBlockedSteps`）。
/// - “修改规则”：服务端没有改触发器的接口，是加一条新的、再删掉旧的；已经满 10 条时先删再加。
@Observable @MainActor
public final class PlanDetailModel {
    public let planID: PlanID
    public private(set) var plan: Plan?

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// 计划本身拉不到。
    public private(set) var error: ClientError?
    /// 计划不存在了（删掉了，或者 agent 取消了）。
    public private(set) var isMissing = false

    /// 运行历史（新的在前）。
    public private(set) var runs: [Run] = []
    public private(set) var runsLoaded = false
    public private(set) var isLoadingRuns = false
    public private(set) var hasMoreRuns = false
    public private(set) var runsError: ClientError?

    /// 正在暂停、恢复、删除、改触发器。
    public private(set) var isUpdating = false
    public private(set) var actionError: ClientError?
    /// 删掉了：界面离开这一页。
    public private(set) var isDeleted = false
    /// 恢复被挡住了（11.9）：这些步骤在已删除的实例上，服务端报 409，先改步骤才能恢复。恢复报冲突后查实例列表填上；
    /// 换上新的计划（重新拉到、编辑页保存）时只留还在的。
    public private(set) var blockedSteps: [PlanStep] = []

    /// 运行历史一页几个。
    public static let runsPageSize = 20

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let snapshots: PlanSnapshotStore

    /// - Parameter plan: 已经有的计划（列表里的），先显示它。
    public init(
        client: any ClientProtocol, planID: PlanID, plan: Plan? = nil, snapshots: PlanSnapshotStore = .shared
    ) {
        self.client = client
        self.planID = planID
        self.plan = plan?.id == planID ? plan : nil
        self.snapshots = snapshots
    }

    // MARK: 加载

    /// 拉计划和第一页运行历史（打开页面、下拉刷新、从编辑页回来）。正在拉时再调直接返回。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let client = self.client
        let id = planID
        async let fresh = PlansErrors.attempt { try await client.getPlan(id) }
        async let page = PlansErrors.attempt {
            try await client.listRuns(filter: .plan(id), before: nil, limit: Self.runsPageSize)
        }
        switch await fresh {
        case .success(let plan): apply(plan)
        case .failure(let error): noteLoadFailure(error)
        }
        if !isMissing {
            switch await page {
            case .success(let list): setFirstPage(list)
            case .failure(let error): runsError = PlansErrors.from(error)
            }
        } else {
            _ = await page
        }
        hasLoaded = true
    }

    /// 只重新拉计划（改了触发器之后）。
    public func reloadPlan() async {
        do {
            apply(try await client.getPlan(planID))
        } catch {
            noteLoadFailure(error)
        }
    }

    /// 编辑页保存了：直接换上保存后的计划。
    public func apply(_ plan: Plan) {
        guard plan.id == planID else { return }
        self.plan = plan
        blockedSteps = blockedSteps.filter(plan.steps.contains)
        error = nil
        isMissing = false
        snapshots.record(plan)
    }

    private func noteLoadFailure(_ error: any Error) {
        guard let failure = PlansErrors.from(error) else { return }
        if failure.isNotFound {
            isMissing = true
            self.error = nil
            snapshots.forget(planID)
        } else {
            self.error = failure
        }
    }

    // MARK: 运行历史

    private func setFirstPage(_ list: [Run]) {
        runs = list
        runsLoaded = true
        runsError = nil
        hasMoreRuns = list.count >= Self.runsPageSize
    }

    /// 重新拉第一页运行历史。
    public func reloadRuns() async {
        guard !isLoadingRuns else { return }
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        do {
            setFirstPage(try await client.listRuns(filter: .plan(planID), before: nil, limit: Self.runsPageSize))
        } catch {
            runsError = PlansErrors.from(error)
        }
    }

    /// 往下翻一页（上一页最后一个之前的）。
    public func loadMoreRuns() async {
        guard hasMoreRuns, !isLoadingRuns, let last = runs.last else { return }
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        do {
            let page = try await client.listRuns(filter: .plan(planID), before: last.id, limit: Self.runsPageSize)
            let known = Set(runs.map(\.id))
            runs.append(contentsOf: page.filter { !known.contains($0.id) })
            hasMoreRuns = page.count >= Self.runsPageSize
            runsError = nil
        } catch {
            runsError = PlansErrors.from(error)
        }
    }

    // MARK: 显示

    /// 能直接恢复：暂停着、而且不是在等确认（等确认的要去确认页）。
    public var canResume: Bool {
        guard let plan else { return false }
        return plan.isPaused && !plan.awaitingConfirmation
    }

    /// 能暂停：没暂停、不在等确认（等确认的本来就不运行）。
    public var canPause: Bool {
        guard let plan else { return false }
        return !plan.isPaused && !plan.awaitingConfirmation
    }

    /// 流水线的步骤按依赖分层。
    public var stages: [[PlanStep]] {
        PipelineLayout.stages(plan?.steps ?? [])
    }

    /// 规则失效、被停用的触发器。
    public var invalidTriggers: [Trigger] {
        plan?.triggers.filter(\.isInvalid) ?? []
    }

    // MARK: 操作

    /// 暂停或恢复。
    @discardableResult
    public func setPaused(_ paused: Bool) async -> Bool {
        guard !isUpdating, paused ? canPause : canResume else { return false }
        let ok = await perform {
            self.apply(try await self.client.setPlanPaused(self.planID, paused: paused))
        }
        // 恢复报冲突：多半是步骤在已删除的实例上（11.9），认出来就换成专门的说明。
        if !ok, !paused, actionError?.isConflict == true, let plan,
            let steps = await PlanBlockedSteps.find(in: plan, client: client), !steps.isEmpty
        {
            blockedSteps = steps
            actionError = nil
        }
        return ok
    }

    /// 删除（界面先二次确认）。已经不在了也算删掉了。
    @discardableResult
    public func delete() async -> Bool {
        guard !isUpdating, !isDeleted else { return false }
        isUpdating = true
        actionError = nil
        defer { isUpdating = false }
        do {
            try await client.deletePlan(planID)
        } catch {
            guard let failure = PlansErrors.from(error) else { return false }
            guard failure.isNotFound else {
                actionError = failure
                return false
            }
        }
        isDeleted = true
        snapshots.forget(planID)
        return true
    }

    /// 加一条触发规则。
    @discardableResult
    public func addTrigger(_ schedule: Schedule) async -> Bool {
        guard !isUpdating, plan != nil else { return false }
        return await perform {
            _ = try await self.client.addTrigger(planID: self.planID, schedule: schedule)
            await self.reloadPlan()
        }
    }

    /// 删一条触发规则（已经不在了也算删掉了）。
    @discardableResult
    public func deleteTrigger(_ triggerID: TriggerID) async -> Bool {
        guard !isUpdating, plan != nil else { return false }
        return await perform {
            try await self.deleteIgnoringMissing(triggerID)
            await self.reloadPlan()
        }
    }

    /// “修改规则”：用新规则换掉旧的（规则失效的那条，或者任意一条）。没满 10 条时先加后删（加失败了旧的还在），
    /// 满了先删后加。中途失败时重新拉一次计划，界面显示真实的情况。
    @discardableResult
    public func replaceTrigger(_ triggerID: TriggerID, with schedule: Schedule) async -> Bool {
        guard !isUpdating, let plan else { return false }
        let full = plan.triggers.count >= Plan.maxTriggers
        let ok = await perform {
            if full {
                try await self.deleteIgnoringMissing(triggerID)
                _ = try await self.client.addTrigger(planID: self.planID, schedule: schedule)
            } else {
                _ = try await self.client.addTrigger(planID: self.planID, schedule: schedule)
                try await self.deleteIgnoringMissing(triggerID)
            }
        }
        await reloadPlan()
        return ok
    }

    public func clearActionError() {
        actionError = nil
    }

    private func deleteIgnoringMissing(_ triggerID: TriggerID) async throws {
        do {
            try await client.deleteTrigger(triggerID)
        } catch let error as ClientError where error.isNotFound {
            // 别处已经删了。
        }
    }

    /// 执行一个写操作：失败时记下错误；计划不存在了标成不存在。
    private func perform(_ body: () async throws -> Void) async -> Bool {
        isUpdating = true
        actionError = nil
        defer { isUpdating = false }
        do {
            try await body()
            return true
        } catch {
            guard let failure = PlansErrors.from(error) else { return false }
            if failure.isNotFound {
                // 计划没了（触发器的 not_found 已经在 deleteIgnoringMissing 里吃掉了）。
                isMissing = true
            } else {
                actionError = failure
            }
            return false
        }
    }
}

extension PlansErrors {
    /// 并发拉取时把结果包成 `Result`（`async let` 里用）。
    nonisolated static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
