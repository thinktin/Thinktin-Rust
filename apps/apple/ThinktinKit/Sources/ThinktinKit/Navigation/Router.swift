import Foundation
import Observation

/// 导航状态（WBS 12.16）：导航栈、当前实例、抽屉、sheet，以及没登录时先记下的深链。
///
/// 界面（`AppShell`）把 `path` 绑到 `NavigationStack(path:)`、`sheet` 绑到 `.sheet(item:)`；各功能的页面从环境里取它
/// （`@Environment(Router.self)`）跳转：`router.open(.run(id))`。规则：
///
/// - 导航栈的根总是当前实例的对话（没有实例时是首页，`rootRoute`）：打开 `.conversation(id)` 等于切换实例、回到根。
/// - 抽屉入口（`openFromDrawer`）是顶级页面：先回到根再压它。
/// - 深链和推送（`show(_:in:)`、`handle(url:)`、`handle(push:)`）把返回栈重建成“根 → 目标页”，和安卓一致。
/// - `open` 会先关掉抽屉和 sheet（sheet 里的“去别处”按钮直接 `open` 就行）；sheet 里自己的多步流程用 sheet 自己的导航栈。
/// - 没登录、冻结、要升级时（`isHoldingRoutes`，由 `AppModel` 设置）深链和推送先记下，恢复正常后再跳，同一条只跳一次。
@Observable @MainActor
public final class Router {
    /// 导航栈（根之上的页面）。
    public var path: [AppRoute]
    /// 当前实例：导航栈的根显示它的对话。`AppModel` 在实例列表变了时校正它（被删了就换成最近活跃的）。
    public var currentInstanceID: InstanceID? {
        didSet {
            if oldValue != currentInstanceID { instanceSelectionDidChange?(currentInstanceID) }
        }
    }
    /// 侧边抽屉开着。
    public var isDrawerOpen: Bool
    /// 弹出的 sheet（`presentation == .sheet` 的页面）。
    public var sheet: AppRoute?
    /// 没登录时收到的深链、推送：恢复正常后再跳。
    public private(set) var pendingRoute: PendingRoute?
    /// 点“新任务”的次数：对话页（12.5）`onChange(of: router.newTaskRequest)` 时把焦点放进输入框。
    public private(set) var newTaskRequest = 0
    /// 暂时不跳转（没登录、冻结、要升级）：深链和推送先记进 `pendingRoute`；改回 false 时自动跳过去。
    public var isHoldingRoutes = false {
        didSet {
            if oldValue && !isHoldingRoutes { releasePendingRoute() }
        }
    }

    /// 当前实例变了（`AppModel` 用它记住上次选的实例）。
    @ObservationIgnored var instanceSelectionDidChange: ((InstanceID?) -> Void)?

    /// 先记下、之后再跳的页面。
    public struct PendingRoute: Hashable, Sendable {
        public var route: AppRoute
        /// 跳过去时顺带切换到的实例（推送里的实例 id）。
        public var instanceID: InstanceID?

        public init(route: AppRoute, instanceID: InstanceID? = nil) {
            self.route = route
            self.instanceID = instanceID
        }
    }

    public init(path: [AppRoute] = [], currentInstanceID: InstanceID? = nil, isDrawerOpen: Bool = false) {
        self.path = path
        self.currentInstanceID = currentInstanceID
        self.isDrawerOpen = isDrawerOpen
        self.sheet = nil
    }

    // MARK: 现在在哪

    /// 导航栈的根：当前实例的对话，没有实例时是首页。
    public var rootRoute: AppRoute {
        currentInstanceID.map(AppRoute.conversation) ?? .home
    }

    /// 最上面的页面（不算 sheet）。
    public var topRoute: AppRoute {
        path.last ?? rootRoute
    }

    /// 在导航栈的根上（对话页、首页）。
    public var isAtRoot: Bool { path.isEmpty }

    // MARK: 应用内跳转

    /// 打开一个页面（按 `presentation`）：根页面回到根，sheet 弹出，其余压栈（和栈顶相同时不重复压）。
    /// 会关掉抽屉；压栈时也关掉 sheet。整页状态（登录、冻结、升级）不归导航管，忽略。
    public func open(_ route: AppRoute) {
        switch route.presentation {
        case .root:
            if case .conversation(let id) = route {
                selectInstance(id)
            } else {
                popToRoot()
            }
        case .push:
            isDrawerOpen = false
            sheet = nil
            if path.last != route { path.append(route) }
        case .sheet:
            isDrawerOpen = false
            sheet = route
        case .global:
            break
        }
    }

    /// 从抽屉打开：顶级页面先回到根再压它（返回就是对话页），其余同 `open`。
    public func openFromDrawer(_ route: AppRoute) {
        if route.presentation == .push {
            isDrawerOpen = false
            sheet = nil
            path = [route]
        } else {
            open(route)
        }
    }

    /// 切换当前实例并回到根（抽屉里的实例、标题栏的实例菜单）。传 nil 回到首页。
    public func selectInstance(_ instanceID: InstanceID?) {
        currentInstanceID = instanceID
        popToRoot()
    }

    /// “新任务”：回到当前实例的对话，并通知对话页把焦点放进输入框（`newTaskRequest`）。
    public func requestNewTask(in instanceID: InstanceID? = nil) {
        if let instanceID { currentInstanceID = instanceID }
        popToRoot()
        newTaskRequest += 1
    }

    public func push(_ route: AppRoute) {
        open(route)
    }

    /// 返回上一页。
    public func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    /// 回到根（关掉抽屉和 sheet）。
    public func popToRoot() {
        isDrawerOpen = false
        sheet = nil
        path = []
    }

    /// 弹出 sheet（不管页面平时怎么出现）。
    public func present(_ route: AppRoute) {
        isDrawerOpen = false
        sheet = route
    }

    public func dismissSheet() {
        sheet = nil
    }

    // MARK: 抽屉

    public func openDrawer() { isDrawerOpen = true }
    public func closeDrawer() { isDrawerOpen = false }
    public func toggleDrawer() { isDrawerOpen.toggle() }

    // MARK: 深链与推送

    /// 从外面跳进来（深链、推送、小组件）：关掉抽屉和 sheet，返回栈重建成“根 → 目标页”。`instanceID`（或页面
    /// 自己所属的实例）会先设成当前实例，返回时回到它的对话。`isHoldingRoutes` 时先记下。
    public func show(_ route: AppRoute, in instanceID: InstanceID? = nil) {
        if isHoldingRoutes {
            if route.presentation != .global { pendingRoute = PendingRoute(route: route, instanceID: instanceID) }
            return
        }
        isDrawerOpen = false
        sheet = nil
        if let instanceID = instanceID ?? route.instanceID { currentInstanceID = instanceID }
        switch route.presentation {
        case .root: path = []
        case .push: path = [route]
        case .sheet:
            path = []
            sheet = route
        case .global: break
        }
    }

    /// 处理深链（App 的 `onOpenURL`）。是认得的 `thinktin://` 深链返回 true。
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let route = DeepLink.route(from: url) else { return false }
        show(route)
        return true
    }

    /// 处理点开的推送（12.8 的通知代理调）：跳到 `payload.route`，顺带切到推送里的实例。
    public func handle(push payload: PushPayload) {
        show(payload.route, in: payload.instanceID)
    }

    /// 清掉记下的深链（不跳了）。
    public func discardPendingRoute() {
        pendingRoute = nil
    }

    private func releasePendingRoute() {
        guard let pending = pendingRoute else { return }
        pendingRoute = nil
        show(pending.route, in: pending.instanceID)
    }

    // MARK: 退出登录

    /// 退出登录：导航全部清空（包括当前实例和记下的深链），换账号后不能看到上一个账号的页面。
    public func reset() {
        path = []
        sheet = nil
        isDrawerOpen = false
        pendingRoute = nil
        currentInstanceID = nil
    }
}
