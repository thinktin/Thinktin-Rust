import Foundation
import Observation

/// agent 新建或修改的计划的确认页（WBS 12.6，`.confirmPlan`：`plan_confirm` 推送、收件箱、对话里的待确认卡片、
/// 计划列表的“待确认”分区进来；已拍板问题 3：agent 通过 thinktin.schedule 建的、改的计划先暂停，用户确认才生效）。
///
/// - 显示改了什么：App 这次运行里见过的生效版本（`PlanSnapshotStore`）和现在的比；没见过的，agent 新建的（版本号 2：
///   建的时候是 1，要确认时加一）说“新建了一个计划”，别的说“改了这个计划，没有之前的版本可以对比”，请用户完整核对。
/// - 确认带上用户看到的版本号（`confirmPlan(revision:)`）。返回冲突时重新拉一次：还在等确认就换成新内容、标出和刚才
///   看的那个版本比改了哪几处，让用户再看一遍再确认；已经不用确认了（在别的设备上确认过）就告诉用户。
/// - 等确认的计划不能用暂停 / 恢复绕过去，这一页只有确认、修改后确认（编辑页保存后回来按新版本确认）和删除。
@Observable @MainActor
public final class PlanConfirmModel {
    /// 确认的结果。
    public enum Outcome: Hashable, Sendable {
        /// 确认了，开始按时运行。
        case confirmed(Plan)
        /// 不用确认了（别处确认过，或者不是等确认的计划）。
        case notAwaiting(Plan)
        /// 删掉了。
        case deleted
    }

    public let planID: PlanID
    /// 用户正在看的版本（确认时带它的 `revision`）。
    public private(set) var plan: Plan?
    /// 拿来对比的旧版本（App 见过的、已经生效的）；没有为 nil。
    public private(set) var baseline: Plan?
    /// 确认时发现又被改过：和刚才看的版本比改了哪几处。
    public private(set) var conflictChanges: [PlanChangeItem]?

    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isMissing = false

    public private(set) var isConfirming = false
    public private(set) var isDeleting = false
    public private(set) var actionError: ClientError?
    public private(set) var outcome: Outcome?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let snapshots: PlanSnapshotStore

    public init(
        client: any ClientProtocol, planID: PlanID, plan: Plan? = nil, snapshots: PlanSnapshotStore = .shared
    ) {
        self.client = client
        self.planID = planID
        self.snapshots = snapshots
        if let plan, plan.id == planID { show(plan) }
    }

    // MARK: 加载

    /// 拉最新的计划（打开页面、下拉刷新、从编辑页回来）。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.getPlan(planID)
            show(fresh)
            error = nil
            if !fresh.awaitingConfirmation, outcome == nil {
                snapshots.record(fresh)
                outcome = .notAwaiting(fresh)
            }
        } catch {
            noteFailure(error)
        }
        hasLoaded = true
    }

    /// 编辑页保存了（“修改后确认”）：用户看的就是保存后的版本，之前的冲突提示作废。
    public func applyEdit(_ plan: Plan) {
        guard plan.id == planID else { return }
        show(plan)
        conflictChanges = nil
        actionError = nil
    }

    private func show(_ plan: Plan) {
        self.plan = plan
        baseline = snapshots.baseline(for: plan.id, before: plan.revision)
    }

    private func noteFailure(_ error: any Error) {
        guard let failure = PlansErrors.from(error) else { return }
        if failure.isNotFound {
            isMissing = true
            self.error = nil
            snapshots.forget(planID)
        } else {
            self.error = failure
        }
    }

    // MARK: 显示

    /// agent 做了什么：新建、改了（有旧版本可比）、改了（没有旧版本）。
    public var reviewKind: PlanReviewKind {
        guard let plan else { return .updatedWithoutBaseline }
        if let baseline { return .updated(PlanDiff.changes(from: baseline, to: plan)) }
        if plan.createdBy == .agent && plan.revision <= Self.freshAgentRevision { return .created }
        return .updatedWithoutBaseline
    }

    /// agent 新建、还没人动过的计划的版本号：建的时候是 1，要确认时加一。
    static let freshAgentRevision = 2

    /// 还在等确认（可以确认）。
    public var canConfirm: Bool {
        guard let plan else { return false }
        return plan.awaitingConfirmation && outcome == nil && !isConfirming && !isDeleting
    }

    /// 某个字段是不是这次改过的（页面上标“改过”）：和旧版本比，以及确认时冲突的那几处。
    public func isChanged(_ field: PlanReviewField) -> Bool {
        var items = conflictChanges ?? []
        if case .updated(let changes) = reviewKind { items += changes }
        return items.contains { PlanReviewField($0) == field }
    }

    // MARK: 操作

    /// 确认用户看到的版本。冲突时重新拉、标出改动（返回 false，用户再看一遍再确认）。
    @discardableResult
    public func confirm() async -> Bool {
        guard canConfirm, let reviewed = plan else { return false }
        isConfirming = true
        actionError = nil
        defer { isConfirming = false }
        do {
            let confirmed = try await client.confirmPlan(planID, revision: reviewed.revision)
            plan = confirmed
            conflictChanges = nil
            snapshots.record(confirmed)
            outcome = .confirmed(confirmed)
            return true
        } catch {
            guard let failure = PlansErrors.from(error) else { return false }
            if failure.isNotFound {
                isMissing = true
                snapshots.forget(planID)
            } else if failure.isConflict {
                await refetchAfterConflict(reviewed: reviewed)
            } else {
                actionError = failure
            }
            return false
        }
    }

    /// 确认冲突：又被改过（版本号不对），或者已经不用确认了。重新拉，再给用户看。
    private func refetchAfterConflict(reviewed: Plan) async {
        do {
            let fresh = try await client.getPlan(planID)
            if fresh.awaitingConfirmation {
                plan = fresh
                baseline = snapshots.baseline(for: fresh.id, before: fresh.revision)
                conflictChanges = PlanDiff.changes(from: reviewed, to: fresh)
            } else {
                plan = fresh
                snapshots.record(fresh)
                outcome = .notAwaiting(fresh)
            }
        } catch {
            noteFailure(error)
            if !isMissing { actionError = PlansErrors.from(error) }
        }
    }

    /// 删除（界面先二次确认）：不想要这个计划。已经不在了也算删掉了。
    @discardableResult
    public func delete() async -> Bool {
        guard !isDeleting, !isConfirming, outcome != .deleted else { return false }
        isDeleting = true
        actionError = nil
        defer { isDeleting = false }
        do {
            try await client.deletePlan(planID)
        } catch {
            guard let failure = PlansErrors.from(error) else { return false }
            guard failure.isNotFound else {
                actionError = failure
                return false
            }
        }
        snapshots.forget(planID)
        outcome = .deleted
        return true
    }

    public func clearActionError() {
        actionError = nil
    }
}

/// agent 对计划做了什么（确认页顶上的说明）。
public enum PlanReviewKind: Hashable, Sendable {
    /// 新建的。
    case created
    /// 改了，和 App 见过的旧版本比改了这些。
    case updated([PlanChangeItem])
    /// 改了，但 App 没见过旧版本。
    case updatedWithoutBaseline
}

/// 确认页上的几块（标“改过”用）。
public enum PlanReviewField: Hashable, Sendable {
    case title, goal, triggers, policy, catchUp, steps

    init(_ change: PlanChangeItem) {
        switch change {
        case .title: self = .title
        case .goal: self = .goal
        case .triggersAdded, .triggersRemoved: self = .triggers
        case .preauthorizedTools, .approvalTimeout, .timeoutAction, .budget, .dailyTokenLimit, .waitTimeout:
            self = .policy
        case .catchUp: self = .catchUp
        case .steps: self = .steps
        }
    }
}
