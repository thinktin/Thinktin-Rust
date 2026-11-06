import Foundation
import Observation

/// 计划列表（WBS 12.6，`.plans(instanceID:)`）：全部实例的计划，按实例筛选；agent 建的、改的等确认的置顶（角标是它们的数量），
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

    /// 这一页只看一个 Botin 的计划（Botin 资料的“计划”进来）：筛选固定在它上面，不显示筛选条（规范 4.5.1）。
    /// 全部计划（nil，计划确认页、详情页的“看全部计划”进来）顶上一排按 Botin 筛选的胶囊。
    public let scopeInstanceID: InstanceID?

    public init(client: any ClientProtocol, instanceFilter: InstanceID? = nil, snapshots: PlanSnapshotStore = .shared) {
        self.client = client
        self.instanceFilter = instanceFilter
        self.scopeInstanceID = instanceFilter
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

    /// 顶上的“按 Botin 筛选”胶囊要不要显示：只看一个 Botin 的页面不显示；全部的页面有计划时显示。
    public var showsInstanceFilter: Bool { scopeInstanceID == nil && !plans.isEmpty }

    /// 列表空着时显示什么；有计划可列时为 nil。
    public var placeholder: PlanListPlaceholder? {
        guard sections.isEmpty else { return nil }
        if !hasLoaded { return .loading }
        if plans.isEmpty, let error { return .unavailable(offline: error.isOffline) }
        if scopeInstanceID == nil, instanceFilter != nil, !plans.isEmpty { return .noneForFilter }
        return .empty
    }

    /// 等确认的有几个（不管筛选）。
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

/// 计划列表空着时（`PlanListModel.placeholder`）。
public enum PlanListPlaceholder: Hashable, Sendable {
    /// 第一次在拉。
    case loading
    /// 一个计划都没拉到、出错了（离线或别的错误）。
    case unavailable(offline: Bool)
    /// 全部计划的页面筛了一个 Botin，它没有计划（可以“看全部”）。
    case noneForFilter
    /// 没有计划（参考 21：屏幕正中一段说明；ThinkTin 多一个“新建计划”）。
    case empty
}

/// 视图模型里把调用失败转成界面显示的错误。
enum PlansErrors {
    /// 任务被取消（页面关了）返回 nil，不算出错；不是 `ClientError` 的按内部错误。
    static func from(_ error: any Error) -> ClientError? {
        if error is CancellationError { return nil }
        return (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}
