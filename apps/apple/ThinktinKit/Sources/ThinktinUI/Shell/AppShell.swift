import SwiftUI
import ThinktinKit

/// 应用框架（WBS 12.16）：按登录状态显示登录页、冻结页、升级页，或者已登录的主界面——导航栈加侧边抽屉。
///
/// 已登录时（参考 Claude iOS App 的版式，品牌是 ThinkTin）：
/// - 导航栈的根是当前实例的对话（没有实例时是首页），导航栏左边是抽屉按钮，标题是实例切换菜单；
/// - 压进来的页面、sheet 都按 `AppRoute.feature` 交给功能目录里的接入点（`AppDestination`）；
/// - 每个页面顶部有统一的连接横幅、离线横幅（`ShellBanners`）；
/// - 抽屉从左边盖上来（`ShellDrawer`），根页面左边缘向右划也能打开。
///
/// 全局状态都在 `AppModel` 里，导航在 `Router` 里（`model.router`），都放进了环境，各页面直接取。
public struct AppShell: View {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// 自己建 `AppModel`（预览、测试）。
    public init(client: any ClientProtocol) {
        _model = State(initialValue: AppModel(client: client))
    }

    /// 用 App 装配好的 `AppModel`（App 的 `onOpenURL` 要把深链交给同一个 `model.router`）。
    public init(model: AppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        content
            .shellEnvironment(model)
            .tint(Theme.accent)
            .task { await model.start() }
            .onChange(of: scenePhase) {
                switch scenePhase {
                case .active: Task { await model.sceneDidBecomeActive() }
                case .background: model.sceneDidEnterBackground()
                default: break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .signedOut:
            NavigationStack {
                AccountDestination(route: .signIn)
                    .appRouteDestinations()
            }
        case .signedIn:
            SignedInShell(model: model)
        case .frozen:
            NavigationStack {
                FrozenView(model: model)
            }
        case .upgradeRequired:
            NavigationStack {
                UpgradeView()
            }
        }
    }
}

/// 已登录的主界面：导航栈 + 抽屉 + sheet。
private struct SignedInShell: View {
    let model: AppModel

    var body: some View {
        let router = model.router
        ZStack(alignment: .leading) {
            NavigationStack(path: Binding(get: { router.path }, set: { router.path = $0 })) {
                RootPage(model: model)
                    .appRouteDestinations()
            }
            .solidTopScrollEdge()
            ShellDrawer(model: model)
        }
        .sheet(item: Binding(get: { router.sheet }, set: { router.sheet = $0 })) { route in
            NavigationStack {
                AppDestination(route: route)
                    .appRouteDestinations()
            }
            .solidTopScrollEdge()
            .shellEnvironment(model)
            .tint(Theme.accent)
        }
    }
}

/// 导航栈的根：当前实例的对话（或首页），导航栏有抽屉按钮和实例切换菜单。
private struct RootPage: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let router = model.router
        AppDestination(route: router.rootRoute)
            // 换了实例就是另一个页面（对话页的状态不带过去）。
            .id(router.rootRoute)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        router.openDrawer()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel(Text(language == .chinese ? "打开侧边栏" : "Open sidebar"))
                }
                ToolbarItem(placement: .principal) {
                    InstanceSwitcher(model: model)
                }
            }
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .overlay(alignment: .leading) {
                // 左边缘向右划打开抽屉（Claude 的习惯）。窄窄一条，不挡内容的点按；读屏用导航栏的按钮。
                Color.clear
                    .frame(width: Metrics.Spacing.m)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 10).onEnded { value in
                            if value.translation.width > 60 { router.openDrawer() }
                        }
                    )
                    .accessibilityHidden(true)
            }
    }
}

#Preview("主界面 · 浅色中文") {
    AppShell(model: AppModel(client: ShellPreviewClients.signedIn(), defaults: nil))
        .environment(\.displayLanguage, .chinese)
}

#Preview("主界面 · 深色英文") {
    AppShell(model: AppModel(client: ShellPreviewClients.signedIn(), defaults: nil))
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}

#Preview("抽屉打开 · 浅色中文") {
    let model = AppModel(client: ShellPreviewClients.signedIn(), defaults: nil)
    AppShell(model: model)
        .task { model.router.openDrawer() }
        .environment(\.displayLanguage, .chinese)
}

#Preview("没登录 · 深色英文") {
    AppShell(model: AppModel(client: ShellPreviewClients.signedOut(), defaults: nil))
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}

#Preview("冻结 · 浅色中文") {
    AppShell(model: AppModel(client: ShellPreviewClients.frozen(), defaults: nil))
        .environment(\.displayLanguage, .chinese)
}

#Preview("要升级 · 深色英文") {
    AppShell(model: AppModel(client: ShellPreviewClients.upgradeRequired(), defaults: nil))
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
