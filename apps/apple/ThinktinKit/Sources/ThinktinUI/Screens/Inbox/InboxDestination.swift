import SwiftUI
import ThinktinKit

/// 推送与收件箱（WBS 12.8）的接入点：`AppShell` 把 `route.feature == .inbox` 的页面都交给它。
///
/// 页面：收件箱（`.inbox`，`InboxScreen`）、收件箱里的一条（`.inboxItem`，推送和深链 `thinktin://inbox/{id}` 点进来，
/// `InboxItemScreen`）。视图模型在 `ThinktinKit/ViewModels/Inbox/`；推送的系统回调在 App 的 `AppDelegate`，
/// 交给 `AppModel`（`open(push:)`、`receive(push:)`、`rejectFromNotification`、`didReceivePushToken`）。
struct InboxDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .inbox: InboxScreen()
        case .inboxItem(let id): InboxItemScreen(itemID: id).id(id)
        default: DestinationPlaceholder(route: route)
        }
    }
}

#Preview("收件箱 · 浅色中文") {
    InboxDestination(route: .inbox).previewShell()
}

#Preview("一条通知 · 深色英文") {
    InboxDestination(route: .inboxItem("0192f3a0-0000-7000-8000-000000001001")).previewShell(.english, scheme: .dark)
}
