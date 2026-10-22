import SwiftUI
import ThinktinKit

/// 团队与流水线（WBS 12.7）的接入点：`AppShell` 把 `route.feature == .teams` 的页面都交给它。
///
/// 页面：团队列表（`.teams`）、团队详情（`.team`）、团队模板（`.teamTemplates`）、流水线编辑器（`.pipelineEditor`）。
///
/// 现在是占位页。做 12.7 时在 `Screens/Teams/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Teams/`，测试放 `Tests/ThinktinKitTests/Teams/` 和 `Tests/ThinktinUITests/Teams/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct TeamsDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("团队 · 浅色中文") {
    TeamsDestination(route: .teams).previewShell()
}

#Preview("团队详情 · 深色英文") {
    TeamsDestination(route: .team(DemoData.releaseTeamID)).previewShell(.english, scheme: .dark)
}
