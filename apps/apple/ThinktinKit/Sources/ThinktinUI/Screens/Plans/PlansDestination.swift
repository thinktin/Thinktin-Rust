import SwiftUI
import ThinktinKit

/// 计划管理（WBS 12.6）的接入点：`AppShell` 把 `route.feature == .plans` 的页面都交给它。
///
/// 页面：计划列表（`.plans`，`PlanListScreen`）、计划详情（`.plan`，`PlanDetailScreen`）、新建（`.newPlan`，sheet）、
/// 编辑（`.editPlan`，sheet，`PlanEditorScreen`；触发器编辑器 `TriggerEditorView` 在编辑页里压栈）、agent 建的或改的
/// 计划的确认页（`.confirmPlan`，压栈，`PlanConfirmScreen`）。视图模型在 `ThinktinKit/ViewModels/Plans/`。
///
/// 每个页面按 id 重建（`.id`），从一个计划跳到另一个计划时不沿用上一个的状态。
struct PlansDestination: View {
    let route: AppRoute

    @Environment(Router.self) private var router

    var body: some View {
        switch route {
        case .plans:
            PlanListScreen()
        case .plan(let id):
            PlanDetailScreen(planID: id).id(id)
        case .newPlan(let instanceID):
            PlanEditorScreen(mode: .create(instanceID: instanceID)) { saved in
                router.dismissSheet()
                // 建好了直接看它。
                if let saved { router.open(.plan(saved.id)) }
            }
        case .editPlan(let id):
            PlanEditorScreen(mode: .edit(id)) { _ in
                router.dismissSheet()
            }
            .id(id)
        case .confirmPlan(let id):
            PlanConfirmScreen(planID: id).id(id)
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("计划 · 浅色中文") {
    PlansDestination(route: .plans).previewShell()
}

#Preview("计划详情 · 深色英文") {
    PlansDestination(route: .plan(DemoData.digestPlanID)).previewShell(.english, scheme: .dark)
}

#Preview("新建计划 · 深色英文") {
    PlansDestination(route: .newPlan(instanceID: DemoData.writerID)).previewShell(.english, scheme: .dark)
}

#Preview("确认计划 · 浅色中文") {
    PlansDestination(route: .confirmPlan(DemoData.agentPlanID)).previewShell()
}
