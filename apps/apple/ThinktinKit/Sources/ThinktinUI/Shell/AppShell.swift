import SwiftUI
import ThinktinKit

/// 应用框架（WBS 12.16）：按登录状态显示登录页、冻结页、升级页，或者已登录的主界面——导航栈加侧边抽屉。
///
/// 已登录时（导航结构见 docs/ios-ui-redesign.md 第 3 节）：
/// - 主导航栈的根永远是首页（`.home`），对话、实例资料这些压在上面；
/// - sheet 有自己的导航栈（`Router.sheetPath`），sheet 里再弹 sheet 页叠第二层（`nestedSheet`、`nestedSheetPath`）；
/// - 压进来的页面、sheet 都按 `AppRoute.feature` 交给功能目录里的接入点（`AppDestination`）；
/// - 每个页面顶部有统一的连接横幅、离线横幅（`ShellBanners`）；
/// - 过渡：首页还是旧的问候页，导航栏左边是抽屉按钮（抽屉开没开是这里的本地状态，`Router` 不管了），标题是实例切换菜单；
///   第 0 轮下一步换成实例列表的首页（`Shell/Home/`），去掉抽屉和实例切换。
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

/// 已登录的主界面：主导航栈 + 两层 sheet（各带导航栈）+ 过渡用的抽屉。
private struct SignedInShell: View {
    let model: AppModel

    /// 抽屉开着（过渡用，首页那一步删掉抽屉时一起删）。
    @State private var isDrawerOpen = false

    var body: some View {
        let router = model.router
        ZStack(alignment: .leading) {
            NavigationStack(path: Binding(get: { router.path }, set: { router.path = $0 })) {
                RootPage(model: model, isDrawerOpen: $isDrawerOpen)
                    .appRouteDestinations()
            }
            .solidTopScrollEdge()
            ShellDrawer(model: model, isOpen: $isDrawerOpen)
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
        .onChange(of: router.path) { isDrawerOpen = false }
        .onChange(of: router.sheet) { isDrawerOpen = false }
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
        .solidTopScrollEdge()
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

/// 主导航栈的根：首页，导航栏有抽屉按钮和实例切换菜单（过渡，见 `AppShell`）。
private struct RootPage: View {
    let model: AppModel
    @Binding var isDrawerOpen: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let router = model.router
        AppDestination(route: router.rootRoute)
            // 过渡：首页还不能原地搜索（首页那一步做），先把搜索页压上来。
            .onChange(of: router.searchRequest) {
                if router.path.isEmpty { router.path = [.search] }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        isDrawerOpen = true
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
                            if value.translation.width > 60 { isDrawerOpen = true }
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
