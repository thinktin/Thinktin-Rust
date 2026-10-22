import SwiftUI
import ThinktinKit

/// Agent 目录与领养（WBS 12.3）的接入点：`AppShell` 把 `route.feature == .agents` 的页面都交给它。
///
/// 页面：Agent 目录（`.agentCatalog`，`AgentCatalogScreen`）、Agent 详情（`.agent`，`AgentDetailScreen`，“领养”弹出
/// `AdoptAgentSheet`）、实例详情（`.instance`，`InstanceDetailScreen`：状态说明、改名、升级 / 回滚、模型路由、
/// 计划和产出物入口、删除前列出级联影响的 `InstanceDeleteSheet`）。视图模型在 `ThinktinKit/ViewModels/Agents/`。
///
/// 每个页面按 id 重建（`.id`），从一个实例的详情跳到另一个实例的详情时不沿用上一个的状态。
struct AgentsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .agentCatalog:
            AgentCatalogScreen()
        case .agent(let id):
            AgentDetailScreen(agentID: id).id(id)
        case .instance(let id):
            InstanceDetailScreen(instanceID: id).id(id)
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("Agent 目录 · 浅色中文") {
    AgentsDestination(route: .agentCatalog).previewShell()
}

#Preview("实例详情 · 深色英文") {
    AgentsDestination(route: .instance(DemoData.writerID)).previewShell(.english, scheme: .dark)
}
