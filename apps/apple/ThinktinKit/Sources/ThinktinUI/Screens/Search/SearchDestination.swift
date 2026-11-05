import SwiftUI
import ThinktinKit

/// 搜索（WBS 12.21）的接入点：`AppShell` 把 `route.feature == .search` 的页面都交给它。
///
/// 页面：搜索（`.search`，搜本机缓存；联网时另拉计划和产出物）。改版后 `.search` 不压栈：`Router` 回到首页、
/// `searchRequest` 加一，首页原地搜索（规范 4.2.4，首页嵌这里的 `SearchResultsView`：筛选胶囊、没输入时列 Botin、
/// “谁发给谁”的结果行）。`SearchScreen` 只在有人用 `NavigationLink(value: AppRoute.search)` 压栈时出现，内容一样。
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
