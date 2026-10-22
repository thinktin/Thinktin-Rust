import SwiftUI
import ThinktinKit

/// 计划管理（WBS 12.6）的接入点：`AppShell` 把 `route.feature == .plans` 的页面都交给它。
///
/// 页面：计划列表（`.plans`）、计划详情（`.plan`）、新建（`.newPlan`，sheet）、编辑（`.editPlan`，sheet）、
/// agent 建的或改的计划的确认页（`.confirmPlan`，压栈：`plan_confirm` 推送、收件箱、对话里的待确认卡片进来）。
///
/// 现在是占位页。做 12.6 时在 `Screens/Plans/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Plans/`，测试放 `Tests/ThinktinKitTests/Plans/` 和 `Tests/ThinktinUITests/Plans/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct PlansDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("计划 · 浅色中文") {
    PlansDestination(route: .plans).previewShell()
}

#Preview("计划详情 · 深色英文") {
    PlansDestination(route: .plan(DemoData.digestPlanID)).previewShell(.english, scheme: .dark)
}
