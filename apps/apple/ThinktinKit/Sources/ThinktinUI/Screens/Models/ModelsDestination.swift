import SwiftUI
import ThinktinKit

/// 模型 key 配置（WBS 12.4）的接入点：`AppShell` 把 `route.feature == .models` 的页面都交给它。
///
/// 页面：模型 key 列表（`.credentials`）、添加 key（`.addCredential`，sheet）、key 详情（`.credential`）、实例的模型路由（`.modelRoutes`）、用量（`.usage`）。
///
/// 现在是占位页。做 12.4 时在 `Screens/Models/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Models/`，测试放 `Tests/ThinktinKitTests/Models/` 和 `Tests/ThinktinUITests/Models/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct ModelsDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("模型 key · 浅色中文") {
    ModelsDestination(route: .credentials).previewShell()
}

#Preview("模型路由 · 深色英文") {
    ModelsDestination(route: .modelRoutes(DemoData.writerID)).previewShell(.english, scheme: .dark)
}
