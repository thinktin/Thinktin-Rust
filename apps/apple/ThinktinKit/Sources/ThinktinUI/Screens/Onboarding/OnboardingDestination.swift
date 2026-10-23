import SwiftUI
import ThinktinKit

/// 首次启动、引导与空状态（WBS 12.17）的接入点：`AppShell` 把 `route.feature == .onboarding` 的页面都交给它。
///
/// 页面：新用户引导（`.onboarding`，sheet：领养 → 加 key → 配 main → 发第一个任务）。
///
/// 现在是占位页。做 12.17 时在 `Screens/Onboarding/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Onboarding/`，测试放 `Tests/ThinktinKitTests/Onboarding/` 和 `Tests/ThinktinUITests/Onboarding/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct OnboardingDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("引导 · 浅色中文") {
    OnboardingDestination(route: .onboarding).previewShell()
}

#Preview("引导 · 深色英文") {
    OnboardingDestination(route: .onboarding).previewShell(.english, scheme: .dark)
}
