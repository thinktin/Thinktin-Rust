import SwiftUI
import ThinktinKit

/// 密码保险箱界面（WBS 12.13）的接入点：`AppShell` 把 `route.feature == .vault` 的页面都交给它。
///
/// 页面：保险箱（`.vault`）、条目（`.vaultItem`）、填写请求（`.vaultRequest`，深链 `thinktin://vault/request/{id}`）。
///
/// 现在是占位页。做 12.13 时在 `Screens/Vault/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Vault/`，测试放 `Tests/ThinktinKitTests/Vault/` 和 `Tests/ThinktinUITests/Vault/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct VaultDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("保险箱 · 浅色中文") {
    VaultDestination(route: .vault).previewShell()
}

#Preview("填写请求 · 深色英文") {
    VaultDestination(route: .vaultRequest(DemoData.npmVaultRequestID)).previewShell(.english, scheme: .dark)
}
