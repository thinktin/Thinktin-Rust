import SwiftUI
import ThinktinKit

/// 对话与运行过程（WBS 12.5）的接入点：`AppShell` 把 `route.feature == .conversation` 的页面都交给它。
///
/// 页面：首页（`.home`，没有实例时的根）、实例对话（`.conversation`，导航栈的根）、运行详情（`.run`）、运行树（`.runTree`，12.7 复用）、进行中（`.activeRuns`）。
///
/// 现在是占位页。做 12.5 时在 `Screens/Conversation/` 里写页面，把 `body` 换成按 `route` 分派到各页面；视图模型放
/// `ThinktinKit/ViewModels/Conversation/`，测试放 `Tests/ThinktinKitTests/Conversation/` 和 `Tests/ThinktinUITests/Conversation/`。
/// 全局状态、跳转、客户端从环境里取（`@Environment(AppModel.self)`、`@Environment(Router.self)`、`@Environment(\.client)`），
/// 规则见 docs/ios.md 第 9 节。
struct ConversationDestination: View {
    let route: AppRoute

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        switch route {
        case .home:
            DestinationPlaceholder(
                route: route, heading: Greeting.text(name: app.user?.nameForDisplay, language: language))
        case .conversation(let id):
            DestinationPlaceholder(route: route, heading: app.instances.first { $0.id == id }?.name)
        default:
            DestinationPlaceholder(route: route)
        }
    }
}

#Preview("实例对话 · 浅色中文") {
    ConversationDestination(route: .conversation(DemoData.writerID)).previewShell()
}

#Preview("运行详情 · 深色英文") {
    ConversationDestination(route: .run(DemoData.postRunID)).previewShell(.english, scheme: .dark)
}
