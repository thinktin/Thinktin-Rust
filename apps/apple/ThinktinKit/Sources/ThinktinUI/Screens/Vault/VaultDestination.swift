import SwiftUI
import ThinktinKit

/// 密码保险箱界面（WBS 12.13）的接入点：`AppShell` 把 `route.feature == .vault` 的页面都交给它。
///
/// 页面：保险箱（`.vault`）、条目（`.vaultItem`）、填写请求（`.vaultRequest`，深链 `thinktin://vault/request/{id}`、推送、
/// 收件箱进来）。对话里的填写卡片在 `ApprovalCardView.swift`（`VaultRequestCardView`）。
struct VaultDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .vault: VaultScreen()
        case .vaultItem(let id): VaultItemScreen(itemID: id).id(id)
        case .vaultRequest(let id): VaultRequestScreen(requestID: id).id(id)
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("保险箱 · 浅色中文") {
    VaultDestination(route: .vault).previewShell()
}

#Preview("填写请求 · 深色英文") {
    VaultDestination(route: .vaultRequest(DemoData.npmVaultRequestID)).previewShell(.english, scheme: .dark)
}

#Preview("条目 · 浅色中文") {
    VaultDestination(route: .vaultItem(DemoData.githubVaultID)).previewShell()
}
