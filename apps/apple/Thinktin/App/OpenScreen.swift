import Foundation
import ThinktinKit

/// 截图脚本的 `THINKTIN_OPEN_SCREEN`（tools/apple/screenshots.sh；只有 Debug 构建认，`ThinktinApp` 启动时调）：打开首页
/// 第一个实例（演示数据里是“写作助手”）的对应页面。和深链一样走 `Router.show`，实例的页面返回栈是“首页 → 对话 → 目标页”
/// （docs/ios-ui-redesign.md 3.4），设置、新建 Botin 弹 sheet，搜索回首页激活搜索栏。
extension AppConfiguration.OpenScreen {
    /// 在实例 `instanceID` 上要打开的页面；实例的页面（对话、计划、产出物）没有实例时为 nil。
    func route(instanceID: InstanceID?) -> AppRoute? {
        switch self {
        case .conversation: instanceID.map { AppRoute.conversation($0) }
        case .plans: instanceID.map { AppRoute.plans(instanceID: $0) }
        case .artifacts: instanceID.map { AppRoute.artifacts(instanceID: $0) }
        case .settings: .settings
        case .search: .search
        case .adopt: .adopt(agentID: nil)
        }
    }

    /// 打开这一页，返回打开的页面。实例的页面先等实例列表拿到（`AppModel.start()` 由界面调，缓存或服务端的结果），
    /// 最多等 `timeout`，取首页的第一行；没等到、没有实例时什么也不做，返回 nil。
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
        model.router.show(route)
        return route
    }
}
