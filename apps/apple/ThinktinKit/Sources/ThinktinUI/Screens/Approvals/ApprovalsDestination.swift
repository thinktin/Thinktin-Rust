import SwiftUI
import ThinktinKit

/// 云端审批（审批卡与审批中心）（WBS 12.15）的接入点：`AppShell` 把 `route.feature == .approvals` 的页面都交给它。
///
/// 页面：审批中心（`.approvals`）、审批详情（`.approval`，推送和深链 `thinktin://approval/{id}`）；对话里的审批卡组件也放这个目录，给 12.5 嵌入。
///
/// 现在是占位页。做 12.15 时在 `Screens/Approvals/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Approvals/`，测试放 `Tests/ThinktinKitTests/Approvals/` 和 `Tests/ThinktinUITests/Approvals/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct ApprovalsDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("审批中心 · 浅色中文") {
    ApprovalsDestination(route: .approvals).previewShell()
}

#Preview("审批详情 · 深色英文") {
    ApprovalsDestination(route: .approval(DemoData.pendingApprovalID)).previewShell(.english, scheme: .dark)
}
