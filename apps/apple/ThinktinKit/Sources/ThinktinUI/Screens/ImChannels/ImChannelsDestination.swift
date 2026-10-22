import SwiftUI
import ThinktinKit

/// IM 渠道设置（WBS 12.14）的接入点：`AppShell` 把 `route.feature == .imChannels` 的页面都交给它。
///
/// 页面：IM 渠道（`.imChannels`）。
///
/// 现在是占位页。做 12.14 时在 `Screens/ImChannels/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/ImChannels/`，测试放 `Tests/ThinktinKitTests/ImChannels/` 和 `Tests/ThinktinUITests/ImChannels/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct ImChannelsDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("IM 渠道 · 浅色中文") {
    ImChannelsDestination(route: .imChannels).previewShell()
}

#Preview("IM 渠道 · 深色英文") {
    ImChannelsDestination(route: .imChannels).previewShell(.english, scheme: .dark)
}
