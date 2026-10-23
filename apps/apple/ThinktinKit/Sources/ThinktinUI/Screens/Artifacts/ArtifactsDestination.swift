import SwiftUI
import ThinktinKit

/// 产出物（WBS 12.18）的接入点：`AppShell` 把 `route.feature == .artifacts` 的页面都交给它。
///
/// 页面：产出物库（`.artifacts`：`instanceID` 为 nil 时是全部实例的）；运行详情、时间线里的产出物卡片组件也放这个目录。
///
/// 现在是占位页。做 12.18 时在 `Screens/Artifacts/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Artifacts/`，测试放 `Tests/ThinktinKitTests/Artifacts/` 和 `Tests/ThinktinUITests/Artifacts/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct ArtifactsDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("产出物库 · 浅色中文") {
    ArtifactsDestination(route: .artifacts(instanceID: nil)).previewShell()
}

#Preview("实例的产出物 · 深色英文") {
    ArtifactsDestination(route: .artifacts(instanceID: DemoData.writerID)).previewShell(.english, scheme: .dark)
}
