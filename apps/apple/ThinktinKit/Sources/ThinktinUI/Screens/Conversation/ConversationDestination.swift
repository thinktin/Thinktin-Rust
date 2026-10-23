import SwiftUI
import ThinktinKit

/// 对话与运行过程（WBS 12.5）的接入点：`AppShell` 把 `route.feature == .conversation` 的页面都交给它。
///
/// 页面：首页（`.home`，没有实例时的根，`ConversationHomeScreen`）、实例对话（`.conversation`，导航栈的根，
/// `ConversationScreen`）、运行详情（`.run`，`RunDetailScreen`，里面的“只看本次过程”是 `RunProcessScreen`）、
/// 运行树（`.runTree`，`RunTreeScreen`，12.7 复用）、进行中（`.activeRuns`，`ActiveRunsScreen`）。
/// 视图模型在 `ThinktinKit/ViewModels/Conversation/`。
///
/// 每个页面按 id 重建（`.id`），从一个运行跳到另一个运行时不沿用上一个的状态。
struct ConversationDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .home:
            ConversationHomeScreen()
        case .conversation(let id):
            ConversationScreen(instanceID: id).id(id)
        case .run(let id):
            RunDetailScreen(runID: id).id(id)
        case .runTree(let id):
            RunTreeScreen(runID: id).id(id)
        case .activeRuns:
            ActiveRunsScreen()
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("实例对话 · 浅色中文") {
    ConversationDestination(route: .conversation(DemoData.writerID)).previewShell()
}

#Preview("运行详情 · 深色英文") {
    ConversationDestination(route: .run(DemoData.postRunID)).previewShell(.english, scheme: .dark)
}
