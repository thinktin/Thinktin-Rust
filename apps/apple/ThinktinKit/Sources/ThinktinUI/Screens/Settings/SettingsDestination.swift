import SwiftUI
import ThinktinKit

/// 设置、多语言与开源许可（WBS 12.12）的接入点：`AppShell` 把 `route.feature == .settings` 的页面都交给它。
///
/// 页面：设置中心（`.settings`）、开源许可（`.licenses`）、关于（`.about`）。
///
/// 现在是占位页。做 12.12 时在 `Screens/Settings/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Settings/`，测试放 `Tests/ThinktinKitTests/Settings/` 和 `Tests/ThinktinUITests/Settings/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct SettingsDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("设置 · 浅色中文") {
    SettingsDestination(route: .settings).previewShell()
}

#Preview("关于 · 深色英文") {
    SettingsDestination(route: .about).previewShell(.english, scheme: .dark)
}
