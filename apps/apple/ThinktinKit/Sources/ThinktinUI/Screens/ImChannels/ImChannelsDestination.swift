import SwiftUI
import ThinktinKit

/// IM 渠道设置（WBS 12.14）的接入点：`AppShell` 把 `route.feature == .imChannels` 的页面都交给它。
///
/// 页面：IM 渠道（`.imChannels`，`ImChannelsScreen`；新建、修改是 sheet）。视图模型在
/// `ThinktinKit/ViewModels/ImChannels/`。
struct ImChannelsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .imChannels:
            ImChannelsScreen()
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("IM 渠道 · 浅色中文") {
    ImChannelsDestination(route: .imChannels).previewShell()
}

#Preview("IM 渠道 · 深色英文") {
    ImChannelsDestination(route: .imChannels).previewShell(.english, scheme: .dark)
}
