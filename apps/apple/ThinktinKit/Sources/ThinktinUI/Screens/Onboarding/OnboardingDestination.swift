import SwiftUI
import ThinktinKit

/// 首次启动、引导与空状态（WBS 12.17）的接入点：`AppShell` 把 `route.feature == .onboarding` 的页面都交给它。
///
/// 页面：新用户引导（`.onboarding`，sheet：领养 → 加 key → 配 main → 发第一个任务 → 打开通知，`OnboardingScreen`）。
/// 新用户登录后弹出（`SignInModel`），换了新手机第一次登录、账号还没有实例或 key 时弹一次（`AppShell` 里的 `OnboardingCheck`），
/// 设置的“关于”里随时能再打开。视图模型在 `ThinktinKit/ViewModels/Onboarding/`。
struct OnboardingDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .onboarding: OnboardingScreen()
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("引导 · 浅色中文") {
    OnboardingDestination(route: .onboarding).previewShell()
}

#Preview("引导 · 深色英文") {
    OnboardingDestination(route: .onboarding).previewShell(.english, scheme: .dark)
}
