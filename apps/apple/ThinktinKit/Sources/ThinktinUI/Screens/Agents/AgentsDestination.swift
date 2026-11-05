import SwiftUI
import ThinktinKit

/// 引擎目录与新建 Botin（WBS 12.3，代码里是 agent 目录与领养）的接入点：`AppShell` 把 `route.feature == .agents` 的页面都交给它。
///
/// 页面：引擎目录（`.agentCatalog`，`AgentCatalogScreen`）、引擎详情（`.agent`，`AgentDetailScreen`，“用它新建 Botin”
/// 打开预选它的新建表单）、Botin 资料（`.instance`，`InstanceDetailScreen`：状态说明、改名、升级 / 回滚、模型路由、
/// 计划和产出物入口、删除前列出级联影响的 `InstanceDeleteSheet`）、新建 Botin（`.adopt(agentID:)`，首页右上“+”和首页
/// 空状态弹的 sheet，`AdoptAgentSheet`：规范 4.7.1 的表单，在表单里选引擎；`agentID` 是预选的引擎）。
/// 视图模型在 `ThinktinKit/ViewModels/Agents/`。
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
        case .adopt(let agentID):
            AdoptAgentSheet(preselectedAgentID: agentID).id(agentID)
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("引擎目录 · 浅色中文") {
    AgentsDestination(route: .agentCatalog).previewShell()
}

#Preview("新建 Botin · 浅色中文") {
    AgentsDestination(route: .adopt(agentID: nil)).previewShell()
}

#Preview("实例详情 · 深色英文") {
    AgentsDestination(route: .instance(DemoData.writerID)).previewShell(.english, scheme: .dark)
}
