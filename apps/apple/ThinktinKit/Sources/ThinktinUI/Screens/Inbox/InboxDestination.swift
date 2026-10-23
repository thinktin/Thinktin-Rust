import SwiftUI
import ThinktinKit

/// 推送与收件箱（WBS 12.8）的接入点：`AppShell` 把 `route.feature == .inbox` 的页面都交给它。
///
/// 页面：收件箱（`.inbox`）、收件箱里的一条（`.inboxItem`，推送和深链 `thinktin://inbox/{id}` 点进来）。
///
/// 现在是占位页。做 12.8 时在 `Screens/Inbox/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Inbox/`，测试放 `Tests/ThinktinKitTests/Inbox/` 和 `Tests/ThinktinUITests/Inbox/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct InboxDestination: View {
    let route: AppRoute

    var body: some View {
        DestinationPlaceholder(route: route)
    }
}

#Preview("收件箱 · 浅色中文") {
    InboxDestination(route: .inbox).previewShell()
}

#Preview("一条通知 · 深色英文") {
    InboxDestination(route: .inboxItem("0192f3a0-0000-7000-8000-000000001001")).previewShell(.english, scheme: .dark)
}
