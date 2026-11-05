import Foundation
import ThinktinKit

/// 截图脚本的 `THINKTIN_OPEN_SCREEN`（tools/apple/screenshots.sh；只有 Debug 构建认，`ThinktinApp` 启动时调）：打开首页
/// 第一个 Botin（演示数据里是“写作助手”）的对应页面，或者别的页面。和深链一样走 `Router.show`：Botin 的页面返回栈是
/// “首页 → 对话 → 目标页”（docs/ios-ui-redesign.md 3.4），设置、新建 Botin、新任务、引导、选择主 Botin 弹 sheet，团队、
/// 引擎、连接压在首页上，搜索回首页激活搜索栏；设置里的页面先弹设置，再压进设置 sheet 的栈。页面里本地打开的子页（编辑 Botin、
/// 头像、工作区、引擎详情、保险箱的新建表单、设备详情、外观……）接着用 `Router.requestSubpages(_:)` 一层层打开（`subpages`）。
/// 首页的置顶、隐藏（只记在这台设备上）在打开之前摆好（`homeArrangement`）。
extension AppConfiguration.OpenScreen {
    /// 首页的置顶、隐藏摆成什么样。
    enum HomeArrangement: Equatable {
        /// 第一行置顶。
        case pinFirst
        /// 最后一行隐藏。
        case hideLast
        /// 全部隐藏。
        case hideAll
    }

    /// 在 Botin `instanceID` 上要打开的页面；要 Botin 的（`needsInstance`）没有 Botin 时为 nil。设置里的页面是压进设置的那一页，
    /// 设置根页的子页（外观、语言、触感反馈）是 `.settings`，首页的置顶和全部隐藏是 `.home`。
    func route(instanceID: InstanceID?) -> AppRoute? {
        if needsInstance {
            guard let id = instanceID else { return nil }
            switch self {
            case .homepinned, .homeallhidden: return .home
            case .hiddenbotins: return .hiddenBotins
            case .conversation, .conversationfind: return .conversation(id)
            case .botinedit, .botinavatar, .workspace: return .instance(id)
            case .instancescreen: return .instanceScreen(id)
            case .plans: return .plans(instanceID: id)
            case .artifacts, .artifactsmedia: return .artifacts(instanceID: id)
            default: return nil
            }
        }
        switch self {
        case .search: return .search
        case .primarybotin: return .primaryBotin
        case .adopt: return .adopt(agentID: nil)
        case .engines, .enginedetail: return .agentCatalog
        case .teams: return .teams
        case .newtask: return .newTask
        case .onboarding: return .onboarding
        case .connections: return .connections(category: nil)
        case .connected, .connectiondetail: return .connectedApps
        case .settings, .appearance, .language, .haptics: return .settings
        case .account: return .account
        case .usage: return .usage
        case .subscription: return .subscription
        case .modelkeys: return .credentials
        case .vault, .vaultlogin, .vaultcard, .vaultcontact: return .vault
        case .permissions, .permissionrule: return .permissions
        case .devices, .devicedetail, .computerdetail: return .devices
        case .importmemory: return .importMemory
        case .feedback: return .feedback
        default: return nil
        }
    }

    /// 打开 `route` 之后接着依次打开的子页。
    var subpages: [Subpage] {
        switch self {
        case .conversationfind: [.conversationFind]
        case .botinedit: [.botinEdit]
        case .botinavatar: [.botinEdit, .botinAvatar]
        case .workspace: [.workspace]
        case .enginedetail: [.engineDetail]
        case .artifactsmedia: [.artifactsMedia]
        case .connectiondetail: [.connectionDetail(ConnectionsDemoData.computerID)]
        case .vaultlogin: [.newVaultItem(.login)]
        case .vaultcard: [.newVaultItem(.card)]
        case .vaultcontact: [.newVaultItem(.contact)]
        case .permissionrule: [.newPermissionRule]
        case .devicedetail: [.currentDevice]
        case .computerdetail: [.computerDevice]
        case .appearance: [.appearanceSettings]
        case .language: [.languageSettings]
        case .haptics: [.hapticsSettings]
        default: []
        }
    }

    /// 打开之前首页的置顶、隐藏要摆成什么样；nil 是不动。
    var homeArrangement: HomeArrangement? {
        switch self {
        case .homepinned: .pinFirst
        case .hiddenbotins: .hideLast
        case .homeallhidden: .hideAll
        default: nil
        }
    }

    /// 打开这一页，返回打开的页面（设置里的页面返回压进设置的那一页）。Botin 的页面先等实例列表拿到（`AppModel.start()`
    /// 由界面调，缓存或服务端的结果），最多等 `timeout`，取首页的第一行；没等到、没有 Botin 时什么也不做，返回 nil。
    @MainActor @discardableResult
    func open(in model: AppModel, timeout: Duration = .seconds(10)) async -> AppRoute? {
        var instanceID: InstanceID?
        if needsInstance {
            let deadline = ContinuousClock.now + timeout
            while !model.hasLoadedInstances, ContinuousClock.now < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return nil
                }
            }
            instanceID = model.homeRows.first?.id
        }
        guard let route = route(instanceID: instanceID) else { return nil }
        if let homeArrangement { arrange(homeArrangement, in: model) }
        if isInSettings {
            model.router.show(.settings)
            model.router.open(route)
        } else {
            model.router.show(route)
        }
        if !subpages.isEmpty { model.router.requestSubpages(subpages) }
        return route
    }

    /// 首页的置顶、隐藏先全部清掉，再按 `arrangement` 摆。
    @MainActor
    private func arrange(_ arrangement: HomeArrangement, in model: AppModel) {
        let store = model.local.preferences
        store.forget(store.pinned + Array(store.hidden))
        let ids = model.homeRows.map(\.id)
        switch arrangement {
        case .pinFirst:
            if let first = ids.first { store.setPinned(true, for: first) }
        case .hideLast:
            if let last = ids.last { store.setHidden(true, for: last) }
        case .hideAll:
            for id in ids { store.setHidden(true, for: id) }
        }
    }
}
