import SwiftUI
import ThinktinKit

/// 模型 key 配置（WBS 12.4）的接入点：`AppShell` 把 `route.feature == .models` 的页面都交给它。
///
/// 页面：模型 key 列表（`.credentials`，`CredentialsScreen`）、添加 key（`.addCredential`，sheet，`AddCredentialSheet`）、
/// key 详情（`.credential`，`CredentialDetailScreen`：改备注、启用 / 停用、换 key、删除）、实例的模型路由（`.modelRoutes`，
/// `ModelRoutesScreen`：main / fast / 自定义别名、按协议过滤的 key、降级链）、用量（`.usage`，`UsageScreen`：
/// 按天的柱状图、总计、四种分组的表格）。视图模型在 `ThinktinKit/ViewModels/Models/`。
///
/// 12.3 的实例详情、12.17 的引导、对话页的“等待 key”都跳到 `.modelRoutes(id)`；没有能用的 key 时路由页弹 `.addCredential`。
/// 每个页面按 id 重建（`.id`），从一个实例的路由跳到另一个实例的路由时不沿用上一个的草稿。
struct ModelsDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .credentials:
            CredentialsScreen()
        case .addCredential:
            AddCredentialSheet()
        case .credential(let id):
            CredentialDetailScreen(credentialID: id).id(id)
        case .modelRoutes(let id):
            ModelRoutesScreen(instanceID: id).id(id)
        case .usage:
            UsageScreen()
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("模型 key · 浅色中文") {
    ModelsDestination(route: .credentials).previewShell()
}

#Preview("模型路由 · 深色英文") {
    ModelsDestination(route: .modelRoutes(DemoData.writerID)).previewShell(.english, scheme: .dark)
}

#Preview("用量 · 浅色中文") {
    ModelsDestination(route: .usage).previewShell()
}

#Preview("添加 key · 深色英文") {
    ModelsDestination(route: .addCredential).previewShell(.english, scheme: .dark)
}
