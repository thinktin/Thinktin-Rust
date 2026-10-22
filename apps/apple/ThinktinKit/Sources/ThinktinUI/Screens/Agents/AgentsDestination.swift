import SwiftUI
import ThinktinKit

/// Agent 目录与领养（WBS 12.3）的接入点：`AppShell` 把 `route.feature == .agents` 的页面都交给它。
///
/// 页面：Agent 目录（`.agentCatalog`）、Agent 详情（`.agent`）、实例详情（`.instance`：状态说明、改名、升级 / 回滚、删除）。
///
/// 现在是占位页。做 12.3 时在 `Screens/Agents/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Agents/`，测试放 `Tests/ThinktinKitTests/Agents/` 和 `Tests/ThinktinUITests/Agents/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct AgentsDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("Agent 目录 · 浅色中文") {
    AgentsDestination(route: .agentCatalog).previewShell()
}

#Preview("实例详情 · 深色英文") {
    AgentsDestination(route: .instance(DemoData.writerID)).previewShell(.english, scheme: .dark)
}
