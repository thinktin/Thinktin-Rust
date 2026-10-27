import SwiftUI
import ThinktinKit

/// 团队与流水线（WBS 12.7）的接入点：`AppShell` 把 `route.feature == .teams` 的页面都交给它。
///
/// 页面：团队列表（`.teams`）、团队详情（`.team`）、团队模板（`.teamTemplates`）、流水线编辑器（`.pipelineEditor`，
/// 计划详情和团队详情进来）。运行树（`.runTree`）在对话功能里，12.7 给它补了停止和等待提示。
struct TeamsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .teams: TeamsScreen()
        case .team(let id): TeamDetailScreen(teamID: id).id(id)
        case .teamTemplates: TeamTemplatesScreen()
        case .pipelineEditor(let planID, let teamID):
            PipelineEditorScreen(planID: planID, teamID: teamID).id(route)
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("团队 · 浅色中文") {
    TeamsDestination(route: .teams).previewShell()
}

#Preview("团队详情 · 深色英文") {
    TeamsDestination(route: .team(DemoData.releaseTeamID)).previewShell(.english, scheme: .dark)
}

#Preview("团队模板 · 浅色中文") {
    TeamsDestination(route: .teamTemplates).previewShell()
}
