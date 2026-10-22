import SwiftUI
import ThinktinKit

/// 注册登录与设备管理（WBS 12.2）的接入点：`AppShell` 把 `route.feature == .account` 的页面都交给它。
///
/// 页面：登录（`.signIn`，没登录时 `AppShell` 整页显示）、账号（`.account`：昵称、注销）、登录设备（`.devices`）。
///
/// 现在是占位页。做 12.2 时在 `Screens/Account/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Account/`，测试放 `Tests/ThinktinKitTests/Account/` 和 `Tests/ThinktinUITests/Account/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct AccountDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("登录 · 浅色中文") {
    AccountDestination(route: .signIn).previewShell()
}

#Preview("登录设备 · 深色英文") {
    AccountDestination(route: .devices).previewShell(.english, scheme: .dark)
}
