import Foundation

/// 计划的一处改动（确认页的“改了什么”、确认时发现又被改过的那几处）。
public enum PlanChangeItem: Hashable, Sendable {
    case title(from: String, to: String)
    case goal(from: String, to: String)
    /// 新加的触发规则（agent 改规则时是删掉全部再加，所以按规则内容比，不按 id）。
    case triggersAdded([Schedule])
    case triggersRemoved([Schedule])
    case preauthorizedTools(from: [String], to: [String])
    case approvalTimeout(from: Int, to: Int)
    case timeoutAction(from: ApprovalTimeoutAction, to: ApprovalTimeoutAction)
    case budget(from: RunBudget, to: RunBudget)
    case dailyTokenLimit(from: Int?, to: Int?)
    case waitTimeout(from: Int, to: Int)
    case catchUp(from: CatchUp, to: CatchUp)
    case steps(from: [PlanStep], to: [PlanStep])
}

/// 比较两个版本的计划（WBS 12.6）。
public enum PlanDiff {
    /// `old` 到 `new` 改了哪些地方（按页面上的顺序：标题、目标、触发规则、策略、补跑、流水线）。
    public static func changes(from old: Plan, to new: Plan) -> [PlanChangeItem] {
        var out: [PlanChangeItem] = []
        if old.title != new.title { out.append(.title(from: old.title, to: new.title)) }
        if old.goal != new.goal { out.append(.goal(from: old.goal, to: new.goal)) }
        let (added, removed) = scheduleDifference(old.triggers.map(\.schedule), new.triggers.map(\.schedule))
        if !removed.isEmpty { out.append(.triggersRemoved(removed)) }
        if !added.isEmpty { out.append(.triggersAdded(added)) }
        let (a, b) = (old.policy, new.policy)
        if Set(a.preauthorizedTools) != Set(b.preauthorizedTools) {
            out.append(.preauthorizedTools(from: a.preauthorizedTools, to: b.preauthorizedTools))
        }
        if a.approvalTimeoutSecs != b.approvalTimeoutSecs {
            out.append(.approvalTimeout(from: a.approvalTimeoutSecs, to: b.approvalTimeoutSecs))
        }
        if a.onApprovalTimeout != b.onApprovalTimeout {
            out.append(.timeoutAction(from: a.onApprovalTimeout, to: b.onApprovalTimeout))
        }
        if a.budget != b.budget { out.append(.budget(from: a.budget, to: b.budget)) }
        if a.dailyTokenLimit != b.dailyTokenLimit {
            out.append(.dailyTokenLimit(from: a.dailyTokenLimit, to: b.dailyTokenLimit))
        }
        if a.waitTimeoutSecs != b.waitTimeoutSecs {
            out.append(.waitTimeout(from: a.waitTimeoutSecs, to: b.waitTimeoutSecs))
        }
        if old.catchUp != new.catchUp { out.append(.catchUp(from: old.catchUp, to: new.catchUp)) }
        if old.steps != new.steps { out.append(.steps(from: old.steps, to: new.steps)) }
        return out
    }

    /// 两组规则的差别（当多重集合比：同一条规则出现两次算两条）。返回（新加的，删掉的），各自保持原来的顺序。
    static func scheduleDifference(_ old: [Schedule], _ new: [Schedule]) -> (added: [Schedule], removed: [Schedule]) {
        var remaining = old
        var added: [Schedule] = []
        for schedule in new {
            if let i = remaining.firstIndex(of: schedule) {
                remaining.remove(at: i)
            } else {
                added.append(schedule)
            }
        }
        return (added, remaining)
    }
}

/// 这次运行（App 进程）里看过的、确认过的计划版本：agent 改了计划之后，确认页拿它和新版本比，告诉用户改了什么。
///
/// 服务端不保存旧版本，所以只能比 App 自己见过的：打开计划列表、详情时记下当时不是“待确认”的版本，确认之后记下确认的
/// 版本。只放在内存里（退出 App 就没了），不落盘：计划的标题、目标不该在退出登录之后还留在设备上。按计划 id 记，
/// 换了账号也对不上别人的计划。
@MainActor
public final class PlanSnapshotStore {
    /// App 里共用的一份。
    public static let shared = PlanSnapshotStore()

    private var snapshots: [PlanID: Plan] = [:]

    public init() {}

    /// 记下一个版本：只记已经生效的（不是待确认的），而且不比已经记下的旧。
    public func record(_ plan: Plan) {
        guard !plan.awaitingConfirmation else { return }
        if let known = snapshots[plan.id], known.revision > plan.revision { return }
        snapshots[plan.id] = plan
    }

    public func record(_ plans: [Plan]) {
        plans.forEach(record)
    }

    /// 记下的、比 `revision` 旧的版本（确认页对比用）；没有为 nil。
    public func baseline(for planID: PlanID, before revision: Int) -> Plan? {
        guard let known = snapshots[planID], known.revision < revision else { return nil }
        return known
    }

    /// 计划删掉了。
    public func forget(_ planID: PlanID) {
        snapshots[planID] = nil
    }

    public func removeAll() {
        snapshots = [:]
    }
}

/// 流水线的步骤按依赖分层（只读展示用）：第一层没有依赖，之后每层只依赖前面几层。成环、依赖了不存在的步骤的
/// （服务端不会存这种）放在最后一层，不丢。
public enum PipelineLayout {
    public static func stages(_ steps: [PlanStep]) -> [[PlanStep]] {
        let keys = Set(steps.map(\.key))
        var done = Set<String>()
        var remaining = steps
        var out: [[PlanStep]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { step in
                step.dependsOn.allSatisfy { done.contains($0) || !keys.contains($0) }
            }
            if ready.isEmpty {
                out.append(remaining)
                break
            }
            out.append(ready)
            done.formUnion(ready.map(\.key))
            remaining.removeAll { done.contains($0.key) }
        }
        return out
    }
}
