import Foundation
import Observation

/// 计划列表（WBS 12.6，抽屉里的“计划”）：全部实例的计划，按实例筛选；agent 建的、改的等确认的置顶（角标是它们的数量），
/// 其余分“按时运行”“已暂停”两组；每一行有下一次触发的时间、规则失效的提示。
///
/// - 列表接口（11.8 起）直接带触发器、步骤、`nextFireAt`、`invalidTriggers`，不用逐个拉详情。
/// - 只拉一次全部计划，按实例筛选在本地做（流水线的某一步在这个实例上跑的也算“和它有关”），切换筛选不用再请求。
/// - 计划不缓存（docs/ios.md 6.2）：离线时只有已经拉到的，没有就是空状态。
/// - 拉到的、已经生效的版本记进 `PlanSnapshotStore`，agent 之后改了，确认页能告诉用户改了什么。
@Observable @MainActor
public final class PlanListModel {
    /// 全部计划（接口返回的顺序）。
    public private(set) var plans: [Plan] = []
    /// 按实例筛选；nil 是全部。
    public var instanceFilter: InstanceID?

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?

    /// 正在暂停、恢复、删除的计划。
    public private(set) var busyPlanIDs: Set<PlanID> = []
    /// 暂停、恢复、删除失败的错误。
    public private(set) var actionError: ClientError?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let snapshots: PlanSnapshotStore

    public init(client: any ClientProtocol, instanceFilter: InstanceID? = nil, snapshots: PlanSnapshotStore = .shared) {
        self.client = client
        self.instanceFilter = instanceFilter
        self.snapshots = snapshots
    }

    // MARK: 加载

    /// 拉全部计划（打开页面、下拉刷新、从别的页面回来、联网后）。正在拉时再调直接返回。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.plans(instanceID: nil)
            plans = fresh
            error = nil
            snapshots.record(fresh)
        } catch {
            guard let failure = PlansErrors.from(error) else { return }
            self.error = failure
        }
        hasLoaded = true
    }

    // MARK: 显示

    /// 按筛选条件留下的计划。
    public var visiblePlans: [Plan] {
        guard let instanceFilter else { return plans }
        return plans.filter { $0.involves(instanceFilter) }
    }

    /// 分组：待确认（置顶，新的在前）、按时运行（下一次早的在前，没有下一次的、规则失效的排后面）、已暂停（新的在前）。
    public var sections: PlanListSections {
        var awaiting: [Plan] = []
        var active: [Plan] = []
        var paused: [Plan] = []
        for plan in visiblePlans {
            if plan.awaitingConfirmation {
                awaiting.append(plan)
            } else if plan.isPaused {
                paused.append(plan)
            } else {
                active.append(plan)
            }
        }
        let newestFirst: (Plan, Plan) -> Bool = { ($0.createdAt, $0.id.rawValue) > ($1.createdAt, $1.id.rawValue) }
        active.sort { a, b in
            switch (a.nextFireAt, b.nextFireAt) {
            case (let x?, let y?): return x != y ? x < y : a.title < b.title
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return newestFirst(a, b)
            }
        }
        return PlanListSections(
            awaiting: awaiting.sorted(by: newestFirst), active: active, paused: paused.sorted(by: newestFirst))
    }

    /// 等确认的有几个（不管筛选，和抽屉里的角标一致）。
    public var awaitingCount: Int { plans.filter(\.awaitingConfirmation).count }

    /// 和这个实例有关的计划有几个（筛选按钮上的数字）；nil 是全部。
    public func count(for instance: InstanceID?) -> Int {
        guard let instance else { return plans.count }
        return plans.filter { $0.involves(instance) }.count
    }

    /// 筛选按钮列出哪些实例：先是 `instances` 里的（应用框架的实例列表，按它的顺序），再补上计划里出现、
    /// 列表里没有的（刚删掉的实例的流水线步骤）。
    public func filterInstances(_ instances: [Instance]) -> [InstanceID] {
        var seen = Set<InstanceID>()
        var out: [InstanceID] = []
        for id in instances.map(\.id) + plans.flatMap(\.involvedInstanceIDs) where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    // MARK: 操作

    /// 暂停或恢复。等确认的计划不能直接恢复（要去确认页按版本确认），这里直接拒绝。
    @discardableResult
    public func setPaused(_ planID: PlanID, paused: Bool) async -> Bool {
        guard let plan = plans.first(where: { $0.id == planID }), !busyPlanIDs.contains(planID) else { return false }
        guard paused || !plan.awaitingConfirmation else { return false }
        busyPlanIDs.insert(planID)
        actionError = nil
        defer { busyPlanIDs.remove(planID) }
        do {
            let updated = try await client.setPlanPaused(planID, paused: paused)
            replace(updated)
            snapshots.record(updated)
            return true
        } catch {
            guard let failure = PlansErrors.from(error) else { return false }
            if failure.isNotFound {
                remove(planID)
            } else {
                actionError = failure
            }
            return false
        }
    }

    /// 删除（界面先二次确认）。已经不在了也算删掉了。
    @discardableResult
    public func delete(_ planID: PlanID) async -> Bool {
        guard !busyPlanIDs.contains(planID) else { return false }
        busyPlanIDs.insert(planID)
        actionError = nil
        defer { busyPlanIDs.remove(planID) }
        do {
            try await client.deletePlan(planID)
        } catch {
            guard let failure = PlansErrors.from(error) else { return false }
            guard failure.isNotFound else {
                actionError = failure
                return false
            }
        }
        remove(planID)
        snapshots.forget(planID)
        return true
    }

    public func clearActionError() {
        actionError = nil
    }

    private func replace(_ plan: Plan) {
        if let i = plans.firstIndex(where: { $0.id == plan.id }) { plans[i] = plan }
    }

    private func remove(_ planID: PlanID) {
        plans.removeAll { $0.id == planID }
    }
}

/// 计划列表的分组。
public struct PlanListSections: Hashable, Sendable {
    /// 等确认的（置顶）。
    public var awaiting: [Plan]
    /// 按时运行的（包括规则失效、不会再运行的，它们排在后面）。
    public var active: [Plan]
    public var paused: [Plan]

    public var isEmpty: Bool { awaiting.isEmpty && active.isEmpty && paused.isEmpty }
}

/// 视图模型里把调用失败转成界面显示的错误。
enum PlansErrors {
    /// 任务被取消（页面关了）返回 nil，不算出错；不是 `ClientError` 的按内部错误。
    static func from(_ error: any Error) -> ClientError? {
        if error is CancellationError { return nil }
        return (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}
