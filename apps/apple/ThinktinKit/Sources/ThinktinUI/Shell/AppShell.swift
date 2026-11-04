import SwiftUI
import ThinktinKit

/// 应用框架（WBS 12.16）：按登录状态显示登录页、冻结页、升级页，或者已登录的主界面——导航栈和两层 sheet。
///
/// 已登录时（导航结构见 docs/ios-ui-redesign.md 第 3 节）：
/// - 主导航栈的根永远是首页（`.home`，实例列表 `Shell/Home/HomeScreen`），对话、实例资料这些压在上面；
///   设置（左上头像）、领养（右上“+”）是 sheet，抽屉的入口在首页左下的工作台菜单里；
/// - sheet 有自己的导航栈（`Router.sheetPath`），sheet 里再弹 sheet 页叠第二层（`nestedSheet`、`nestedSheetPath`）；
/// - 根页面、压进来的页面、sheet 都按 `AppRoute.feature` 交给功能目录里的接入点（`AppDestination`）；
/// - 每个页面顶部有统一的连接横幅、离线横幅（`ShellBanners`）。
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

/// 已登录的主界面：主导航栈（根是首页）+ 两层 sheet（各带导航栈）。
private struct SignedInShell: View {
    let model: AppModel

    var body: some View {
        let router = model.router
        NavigationStack(path: Binding(get: { router.path }, set: { router.path = $0 })) {
            AppDestination(route: router.rootRoute)
                .appRouteDestinations()
        }
        .sheet(item: Binding(get: { router.sheet }, set: { router.sheet = $0 })) { route in
            SheetStack(
                model: model, route: route, path: Binding(get: { router.sheetPath }, set: { router.sheetPath = $0 })
            )
            .sheet(item: Binding(get: { router.nestedSheet }, set: { router.nestedSheet = $0 })) { nested in
                SheetStack(
                    model: model, route: nested,
                    path: Binding(get: { router.nestedSheetPath }, set: { router.nestedSheetPath = $0 }))
            }
        }
    }
}

/// 一层 sheet：自己的导航栈（绑 `Router.sheetPath` / `nestedSheetPath`），根页面是 `route`。
struct SheetStack: View {
    let model: AppModel
    let route: AppRoute
    @Binding var path: [AppRoute]

    var body: some View {
        NavigationStack(path: $path) {
            root
                .appRouteDestinations()
        }
        .shellEnvironment(model)
        .tint(Theme.accent)
    }

    /// 设置、领养的根页面自己没有关闭按钮（以前是压栈的页面），这里补上左上的 ×。`route` 在这层 sheet 里不会变，
    /// 分支不会来回换。
    @ViewBuilder
    private var root: some View {
        let page = AppDestination(route: route)
        if Self.addsCloseButton(to: route) {
            page.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { model.router.dismissSheet() }
                }
            }
        } else {
            page
        }
    }

    /// 根页面是原来压栈的页面、自己不带“取消 / 完成”的 sheet。
    static func addsCloseButton(to route: AppRoute) -> Bool {
        switch route {
        case .settings, .adopt: true
        default: false
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

#Preview("设置 sheet · 浅色中文") {
    let model = AppModel(client: ShellPreviewClients.signedIn(), defaults: nil)
    AppShell(model: model)
        .task { model.router.open(.settings) }
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
