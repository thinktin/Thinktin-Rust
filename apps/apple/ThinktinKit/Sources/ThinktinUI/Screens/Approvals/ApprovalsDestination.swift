import SwiftUI
import ThinktinKit

/// 云端审批（审批卡与审批中心）（WBS 12.15）的接入点：`AppShell` 把 `route.feature == .approvals` 的页面都交给它。
///
/// 页面：审批中心（`.approvals`）、审批详情（`.approval`，推送和深链 `thinktin://approval/{id}`）；对话里的审批卡组件也放这个目录，给 12.5 嵌入。
///
/// 审批中心是 `ApprovalCenterScreen`，详情是 `ApprovalDetailScreen`（`ApprovalScreens.swift`），视图模型在
/// `ThinktinKit/ViewModels/Approvals/`。对话里的审批卡片（12.5 先做的 `ApprovalCardView`）在对话目录。
/// 详情按 id 重建（`.id`），从一条审批跳到另一条时不沿用上一条的状态。
struct ApprovalsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .approvals:
            ApprovalCenterScreen()
        case .approval(let id):
            ApprovalDetailScreen(approvalID: id).id(id)
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("审批中心 · 浅色中文") {
    ApprovalsDestination(route: .approvals).previewShell()
}

#Preview("审批详情 · 深色英文") {
    ApprovalsDestination(route: .approval(DemoData.pendingApprovalID)).previewShell(.english, scheme: .dark)
}
