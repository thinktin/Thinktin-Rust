import SwiftUI
import ThinktinKit

/// 连接（改版规范 4.8、6.12；第 2 轮的新功能）的接入点：`AppShell` 把 `route.feature == .connections` 的页面都交给它。
///
/// 页面：连接目录（`.connections(category:)`，`ConnectionsCatalogScreen`：分类胶囊、为你推荐、精选、搜索，参考 36、40–51）、
/// 已连接（`.connectedApps`，`ConnectedAppsScreen`，参考 37）、完整列表（`.connectionList`，`ConnectionListScreen`，参考 101–104）、
/// 应用详情（`.connection(id)`，`ConnectionDetailScreen`；目录、列表里点行弹的是同一个页面的 sheet，参考 38、39、52、105–107）。
/// 入口：设置里的“连接”一行。视图模型和本地的演示目录在 `ThinktinKit/ViewModels/Connections/`。
struct ConnectionsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .connections(let category):
            ConnectionsCatalogScreen(category: category).id(category)
        case .connectedApps:
            ConnectedAppsScreen()
        case .connectionList(let list):
            ConnectionListScreen(list: list).id(list)
        case .connection(let id):
            ConnectionDetailScreen(connectionID: id).id(id)
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("连接目录 · 浅色中文") {
    ConnectionsDestination(route: .connections(category: nil)).previewShell()
}

#Preview("已连接 · 深色英文") {
    ConnectionsDestination(route: .connectedApps).previewShell(.english, scheme: .dark)
}
