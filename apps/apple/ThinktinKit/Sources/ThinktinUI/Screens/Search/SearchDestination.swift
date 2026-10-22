import SwiftUI
import ThinktinKit

/// 搜索（WBS 12.21）的接入点：`AppShell` 把 `route.feature == .search` 的页面都交给它。
///
/// 页面：搜索（`.search`，只搜本机缓存）。
///
/// 现在是占位页。做 12.21 时在 `Screens/Search/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Search/`，测试放 `Tests/ThinktinKitTests/Search/` 和 `Tests/ThinktinUITests/Search/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct SearchDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("搜索 · 浅色中文") {
    SearchDestination(route: .search).previewShell()
}

#Preview("搜索 · 深色英文") {
    SearchDestination(route: .search).previewShell(.english, scheme: .dark)
}
