import Foundation

/// 流水线有步骤在已删除的实例上（11.9，crates/client-core/src/ffi.rs 的 `delete_instance`）：删除实例时，别的实例的
/// 流水线有一步在它上面的（正在生效的）被暂停，之后恢复（`setPlanPaused(.., false)`）、确认（`confirmPlan`）都报 409
/// `conflict`，要先把这些步骤改到别的实例上（流水线编辑在 12.7）。
///
/// 409 只说“冲突”：计划详情、确认页按实例列表认出是这个原因，换成专门的说明，不说“内容被改过了，刷新后重试”
/// （刷新、重试都没用，确认页也不会一直说“又被改过了”）。
public enum PlanBlockedSteps {
    /// 计划里在已删除的实例上的步骤：现有的实例（`liveInstances`，没删除的；`AppModel.instances` 就是）里没有的。
    /// 不是流水线时为空。
    public static func steps(in plan: Plan, liveInstances: Set<InstanceID>) -> [PlanStep] {
        plan.steps.filter { !liveInstances.contains($0.instanceID) }
    }

    /// 拉一次实例列表再找（恢复、确认报了冲突之后）。不是流水线为空；实例列表拉不到为 nil（不知道，照常按冲突处理）。
    static func find(in plan: Plan, client: any ClientProtocol) async -> [PlanStep]? {
        guard plan.isPipeline else { return [] }
        guard let instances = try? await client.instances() else { return nil }
        return steps(in: plan, liveInstances: Set(instances.filter { $0.state != .deleted }.map(\.id)))
    }

    /// 页面上的说明：哪几步，要先改步骤。`confirming` 是确认页（等确认的计划），否则是计划详情（恢复）。
    public static func message(_ steps: [PlanStep], confirming: Bool, language: DisplayLanguage = .current) -> String {
        let keys = AgentsText.list(steps.map(\.key), language: language)
        let zh = language == .chinese
        if confirming {
            return zh
                ? "步骤 \(keys) 所在的实例已经删除了，确认之前要先把这些步骤改到别的实例上。"
                : "The instance for step \(keys) was deleted. Move these steps to another instance before confirming."
        }
        return zh
            ? "步骤 \(keys) 所在的实例已经删除了，这条流水线暂停着，把这些步骤改到别的实例上才能恢复。"
            : "The instance for step \(keys) was deleted, so this pipeline stays paused. Move these steps to another "
                + "instance to resume it."
    }
}
