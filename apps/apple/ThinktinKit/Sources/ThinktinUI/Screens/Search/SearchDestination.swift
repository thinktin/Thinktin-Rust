import SwiftUI
import ThinktinKit

/// 搜索（WBS 12.21）的接入点：`AppShell` 把 `route.feature == .search` 的页面都交给它。
///
/// 页面：搜索（`.search`，搜本机缓存；联网时另拉计划和产出物）。
struct SearchDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .search: SearchScreen()
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("搜索 · 浅色中文") {
    SearchDestination(route: .search).previewShell()
}

#Preview("搜索 · 深色英文") {
    SearchDestination(route: .search).previewShell(.english, scheme: .dark)
}
