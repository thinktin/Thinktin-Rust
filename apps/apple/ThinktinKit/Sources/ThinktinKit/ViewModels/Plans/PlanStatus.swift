import Foundation

/// 计划在列表、详情上显示的状态（WBS 12.6）。按这个顺序认：待确认 → 已暂停 → 规则失效（而且没有别的会触发的规则）
/// → 按时运行（有下一次）→ 不会再运行（一次性的过了、没有规则）。
public enum PlanStatus: Hashable, Sendable {
    /// agent 新建或修改了、等用户确认（确认前不运行，也不能直接恢复）。
    case awaitingConfirmation
    /// 用户暂停了（或“全部停止”停的）。
    case paused
    /// 规则都失效了、被后台停用：不会再运行，要“修改规则”。
    case invalidRule
    /// 按时运行，下一次在这个时间（名义时间，削峰可能晚几分钟）。
    case scheduled(next: Date)
    /// 没有会再触发的规则（一次性的已经跑过了、规则都删了）。
    case idle

    /// 状态名（列表上的标签、读屏）。
    public func localizedName(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .awaitingConfirmation: return zh ? "待确认" : "Needs review"
        case .paused: return zh ? "已暂停" : "Paused"
        case .invalidRule: return zh ? "规则已失效" : "Rule no longer valid"
        case .scheduled: return zh ? "按时运行" : "Active"
        case .idle: return zh ? "不会再运行" : "No upcoming runs"
        }
    }

    /// 要用户处理（待确认、规则失效）。
    public var needsAttention: Bool {
        switch self {
        case .awaitingConfirmation, .invalidRule: true
        default: false
        }
    }
}

extension Plan {
    /// 计划现在的状态（见 `PlanStatus`）。
    public var status: PlanStatus {
        if awaitingConfirmation { return .awaitingConfirmation }
        if isPaused { return .paused }
        if let nextFireAt { return .scheduled(next: nextFireAt) }
        if hasInvalidTriggers { return .invalidRule }
        return .idle
    }

    /// 流水线用到的实例（计划所属的实例和每一步指定的实例，去重，按出现的顺序）。
    public var involvedInstanceIDs: [InstanceID] {
        var seen = Set<InstanceID>()
        return ([instanceID] + steps.map(\.instanceID)).filter { seen.insert($0).inserted }
    }

    /// 这个计划和实例有关：属于它，或者流水线的某一步在它上面跑（按实例筛选时用）。
    public func involves(_ instance: InstanceID) -> Bool {
        instanceID == instance || steps.contains { $0.instanceID == instance }
    }
}
