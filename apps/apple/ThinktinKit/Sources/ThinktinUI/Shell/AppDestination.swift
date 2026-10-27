import SwiftUI
import ThinktinKit

/// 一个页面（WBS 12.16）：按 `route.feature` 交给功能目录里的接入点（`Screens/<功能>/<功能>Destination.swift`），
/// 再在顶部放全局横幅（事件流的连接状态、离线）。
///
/// 导航栈的根、压栈的页面、sheet 里的页面都经过它。各功能只改自己的 `XxxDestination`，不用改这里；
/// 加了新功能才在这里加一行（`AppFeature` 加了 case 编译器会提示）。
struct AppDestination: View {
    let route: AppRoute

    var body: some View {
        destination
            .safeAreaInset(edge: .top, spacing: 0) {
                ShellBanners(route: route)
            }
    }

    @ViewBuilder
    private var destination: some View {
        switch route.feature {
        case .account: AccountDestination(route: route)
        case .agents: AgentsDestination(route: route)
        case .models: ModelsDestination(route: route)
        case .conversation: ConversationDestination(route: route)
        case .plans: PlansDestination(route: route)
        case .teams: TeamsDestination(route: route)
        case .inbox: InboxDestination(route: route)
        case .settings: SettingsDestination(route: route)
        case .vault: VaultDestination(route: route)
        case .imChannels: ImChannelsDestination(route: route)
        case .approvals: ApprovalsDestination(route: route)
        case .onboarding: OnboardingDestination(route: route)
        case .artifacts: ArtifactsDestination(route: route)
        case .search: SearchDestination(route: route)
        case .shell: ShellDestination(route: route)
        }
    }
}

extension View {
    /// 导航栈里压进来的 `AppRoute` 都交给 `AppDestination`。主导航栈和每个 sheet 的导航栈都要加。
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppDestination(route: route)
        }
    }
}

/// 页面顶部的全局横幅：事件流在连 / 在重连，离线（文案按页面的离线策略，docs/ios.md 第 6.2 节）。
struct ShellBanners: View {
    let route: AppRoute

    @Environment(AppModel.self) private var model
    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: 0) {
            if model.phase == .signedIn, model.connection.isVisible {
                ConnectionBanner(state: model.connection)
            }
            if model.isOffline, let message = route.offlinePolicy.bannerMessage(language) {
                OfflineBanner(message: message) {
                    Task { await model.refresh() }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.connection)
        .animation(.easeInOut(duration: 0.2), value: model.isOffline)
    }
}
