import Foundation
import Observation

/// 导航状态（WBS 12.16，改版后的结构见 docs/ios-ui-redesign.md 第 3.3、3.4 节）：主导航栈、当前实例、两层 sheet 和
/// 它们各自的导航栈，以及没登录时先记下的深链。
///
/// 界面（`AppShell`）把 `path` 绑到主 `NavigationStack(path:)`，`sheet` / `sheetPath` 绑到 `.sheet(item:)` 和它里面的
/// `NavigationStack(path:)`，`nestedSheet` / `nestedSheetPath` 同理叠在第一层 sheet 上面；各功能的页面从环境里取它
/// （`@Environment(Router.self)`）跳转：`router.open(.run(id))`。规则：
///
/// - 主导航栈的根永远是首页（实例列表，`.home`）。打开 `.conversation(id)` 是压栈，并把它记成当前实例。
/// - `open` 按 `presentation`：根页面关掉 sheet、回到首页（`.search` 顺带让首页激活搜索，`searchRequest`）；sheet 页弹出，
///   已经开着 sheet 时叠一层（`nestedSheet`，最多两层，再开就换掉第二层）；压栈的页面压进最前面那一层的导航栈
///   （sheet 开着时压进 sheet 自己的栈、不关 sheet）。`.conversation` 例外：总是先关掉所有 sheet，再压进主栈。
/// - 工作台菜单的入口（`openTopLevel`）是顶级页面：先关掉 sheet、回到首页再压它。
/// - 深链和推送（`show(_:in:)`、`handle(url:)`、`handle(push:)`）先关掉 sheet，把返回栈重建成“首页 → 目标页”，
///   和实例有关的是“首页 → 实例的对话 → 目标页”（`DeepLink.backStack(to:instanceID:)`）。
/// - 没登录、冻结、要升级时（`isHoldingRoutes`，由 `AppModel` 设置）深链和推送先记下，恢复正常后再跳，同一条只跳一次。
@Observable @MainActor
public final class Router {
    /// 主导航栈（首页之上的页面）。
    public var path: [AppRoute]
    /// 当前实例：最近打开的对话（新任务、小组件、快捷指令默认用它）。`AppModel` 在实例列表变了时校正它
    /// （被删了就换成上次选的或最近活跃的）。
    public var currentInstanceID: InstanceID? {
        didSet {
            if oldValue != currentInstanceID { instanceSelectionDidChange?(currentInstanceID) }
        }
    }
    /// 弹出的 sheet（第一层）。换了或关掉时它的导航栈和上面叠的那层一起清掉（系统下滑关掉也一样）。
    public var sheet: AppRoute? {
        didSet {
            if oldValue != sheet {
                sheetPath = []
                nestedSheet = nil
            }
        }
    }
    /// 第一层 sheet 自己的导航栈（sheet 根页面之上的页面）：设置里点保险箱、模型 key、用量都压在这里，不关设置。
    public var sheetPath: [AppRoute] = []
    /// 叠在第一层 sheet 上的第二层（设置 → 模型 key → 添加 key）。换了或关掉时它的导航栈一起清掉。
    public var nestedSheet: AppRoute? {
        didSet {
            if oldValue != nestedSheet { nestedSheetPath = [] }
        }
    }
    /// 第二层 sheet 自己的导航栈。
    public var nestedSheetPath: [AppRoute] = []
    /// 没登录时收到的深链、推送：恢复正常后再跳。
    public private(set) var pendingRoute: PendingRoute?
    /// 点“新任务”的次数：对话页（12.5）`onChange(of: router.newTaskRequest)` 时把焦点放进输入框。
    public private(set) var newTaskRequest = 0
    /// 要搜索的次数（`open(.search)`、深链）：首页 `onChange(of: router.searchRequest)` 时激活搜索栏。
    public private(set) var searchRequest = 0
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

    public init(path: [AppRoute] = [], currentInstanceID: InstanceID? = nil) {
        self.path = path
        self.currentInstanceID = currentInstanceID
        self.sheet = nil
        self.nestedSheet = nil
    }

    // MARK: 现在在哪

    /// 主导航栈的根：永远是首页。
    public var rootRoute: AppRoute { .home }

    /// 主导航栈最上面的页面（不算 sheet）。
    public var topRoute: AppRoute {
        path.last ?? rootRoute
    }

    /// 主导航栈在首页上（不管有没有 sheet）。
    public var isAtRoot: Bool { path.isEmpty }

    /// 最前面那层 sheet（第二层，没有就是第一层；都没开为 nil）。
    public var frontSheet: AppRoute? { nestedSheet ?? sheet }

    /// 用户眼前的页面：最前面那层（sheet 或主栈）的栈顶。页面回到最前面时刷新用：
    /// `.onChange(of: router.visibleRoute) { if router.visibleRoute == .vault { … } }`。
    public var visibleRoute: AppRoute {
        if let nestedSheet { return nestedSheetPath.last ?? nestedSheet }
        if let sheet { return sheetPath.last ?? sheet }
        return topRoute
    }

    /// 最前面那层 sheet 底下的页面（从哪个页面弹出来的）；没开 sheet 时为 nil。
    public var routeBelowSheet: AppRoute? {
        if let sheet, nestedSheet != nil { return sheetPath.last ?? sheet }
        return sheet == nil ? nil : topRoute
    }

    // MARK: 应用内跳转

    /// 打开一个页面（按 `presentation`，规则见类型的说明）：根页面回到首页，sheet 页弹出（开着 sheet 时叠一层），
    /// 压栈的页面压进最前面那一层的导航栈（和栈顶相同时不重复压）；`.conversation` 先关掉 sheet 再压进主栈。
    /// 整页状态（登录、冻结、升级）不归导航管，忽略。
    public func open(_ route: AppRoute) {
        switch route.presentation {
        case .root:
            popToRoot()
            if route == .search { searchRequest += 1 }
        case .push:
            if case .conversation(let id) = route {
                openConversation(id)
            } else if nestedSheet != nil {
                if nestedSheetPath.last != route { nestedSheetPath.append(route) }
            } else if sheet != nil {
                if sheetPath.last != route { sheetPath.append(route) }
            } else if path.last != route {
                path.append(route)
            }
        case .sheet:
            present(route)
        case .global:
            break
        }
    }

    /// 从首页的工作台菜单打开：压栈的页面先关掉 sheet、回到首页再压它（返回就是首页），其余同 `open`。
    public func openTopLevel(_ route: AppRoute) {
        guard route.presentation == .push else {
            open(route)
            return
        }
        dismissAllSheets()
        if case .conversation(let id) = route { currentInstanceID = id }
        path = [route]
    }

    /// 打开实例的对话并记成当前实例：先关掉 sheet；主栈里已经有这个对话就退回到它，没有就压上去。
    private func openConversation(_ instanceID: InstanceID) {
        currentInstanceID = instanceID
        dismissAllSheets()
        let route = AppRoute.conversation(instanceID)
        if let index = path.firstIndex(of: route) {
            path.removeSubrange(path.index(after: index)...)
        } else {
            path.append(route)
        }
    }

    /// 切换当前实例并重新从首页进它的对话（“首页 → 对话”，关掉 sheet）。传 nil 只是回到首页、清掉当前实例。
    public func selectInstance(_ instanceID: InstanceID?) {
        dismissAllSheets()
        currentInstanceID = instanceID
        path = instanceID.map { [.conversation($0)] } ?? []
    }

    /// “新任务”：进实例（默认当前实例）的对话（“首页 → 对话”），并通知对话页把焦点放进输入框（`newTaskRequest`）。
    /// 没有实例时只回到首页。
    public func requestNewTask(in instanceID: InstanceID? = nil) {
        guard let target = instanceID ?? currentInstanceID else {
            popToRoot()
            return
        }
        selectInstance(target)
        newTaskRequest += 1
    }

    public func push(_ route: AppRoute) {
        open(route)
    }

    /// 返回上一页：退最前面那一层的导航栈；那一层已经在根上、又是 sheet 时关掉这层 sheet。主栈在首页时什么也不做。
    public func pop() {
        if nestedSheet != nil {
            if nestedSheetPath.isEmpty { nestedSheet = nil } else { nestedSheetPath.removeLast() }
        } else if sheet != nil {
            if sheetPath.isEmpty { sheet = nil } else { sheetPath.removeLast() }
        } else if !path.isEmpty {
            path.removeLast()
        }
    }

    /// 回到首页（关掉所有 sheet）。
    public func popToRoot() {
        dismissAllSheets()
        path = []
    }

    /// 弹出 sheet（不管页面平时怎么出现）：没开 sheet 时是第一层；开着时叠成第二层（第二层开着就换掉它）。
    /// 已经开着的那一层就是它时不重复弹（是第一层时关掉上面叠的那层，回到它）。
    public func present(_ route: AppRoute) {
        if sheet == nil || sheet == route {
            sheet = route
            nestedSheet = nil
        } else {
            nestedSheet = route
        }
    }

    /// 关掉最前面那层 sheet（sheet 里的“取消”“完成”）。
    public func dismissSheet() {
        if nestedSheet != nil {
            nestedSheet = nil
        } else {
            sheet = nil
        }
    }

    /// 关掉所有 sheet。
    public func dismissAllSheets() {
        nestedSheet = nil
        sheet = nil
    }

    /// 实例没了（被删了）：各层导航栈从它的第一个页面起都拿掉（后面的是从它那里进去的），根页面是它的 sheet 关掉。
    /// 当前实例不在这里换（`AppModel` 校正）。
    public func removeRoutes(of instanceID: InstanceID) {
        func truncate(_ stack: inout [AppRoute]) {
            if let index = stack.firstIndex(where: { $0.instanceID == instanceID }) {
                stack.removeSubrange(index...)
            }
        }
        if nestedSheet?.instanceID == instanceID { nestedSheet = nil } else { truncate(&nestedSheetPath) }
        if sheet?.instanceID == instanceID { sheet = nil } else { truncate(&sheetPath) }
        truncate(&path)
    }

    // MARK: 深链与推送

    /// 从外面跳进来（深链、推送、小组件）：关掉 sheet，返回栈重建成“首页 → 目标页”，和实例有关的是“首页 → 实例的对话 →
    /// 目标页”（`DeepLink.backStack(to:instanceID:)`）。`instanceID`（或页面自己所属的实例）会记成当前实例。
    /// `isHoldingRoutes` 时先记下。
    public func show(_ route: AppRoute, in instanceID: InstanceID? = nil) {
        if isHoldingRoutes {
            if route.presentation != .global { pendingRoute = PendingRoute(route: route, instanceID: instanceID) }
            return
        }
        dismissAllSheets()
        let owner = instanceID ?? route.instanceID
        if let owner { currentInstanceID = owner }
        switch route.presentation {
        case .root:
            path = []
            if route == .search { searchRequest += 1 }
        case .push:
            path = DeepLink.backStack(to: route, instanceID: owner)
        case .sheet:
            path = []
            sheet = route
        case .global:
            break
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
        dismissAllSheets()
        pendingRoute = nil
        currentInstanceID = nil
    }
}
