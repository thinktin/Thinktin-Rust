import SwiftUI
import ThinktinKit

// 应用框架放进环境里的东西（WBS 12.16）：各功能的页面这样取——
//
//     @Environment(AppModel.self) private var app       // 全局状态：当前实例、角标、离线……
//     @Environment(Router.self) private var router      // 跳转：router.open(.run(id))
//     @Environment(\.client) private var client         // 调接口（包了一层的 ObservedClient）
//
// `AppShell` 在最外层注入，sheet 里也会重新注入一遍；预览用 `.previewShell()`。

private struct ClientKey: EnvironmentKey {
    /// 没注入时的兜底（只有忘了 `.previewShell()` 的预览会用到）：演示数据的 Mock。
    static let defaultValue: any ClientProtocol = MockClient(autoReply: false)
}

extension EnvironmentValues {
    /// 调接口用的客户端。`AppShell` 注入的是 `AppModel.client`（`ObservedClient`），所以任何调用遇到登录失效、
    /// 冻结、要升级都会自动切换全局状态；页面只管显示自己的行内错误（`ErrorBanner`）。
    public var client: any ClientProtocol {
        get { self[ClientKey.self] }
        set { self[ClientKey.self] = newValue }
    }
}

extension View {
    /// 注入应用框架的全局状态、导航和客户端。
    func shellEnvironment(_ model: AppModel) -> some View {
        environment(model)
            .environment(model.router)
            .environment(\.client, model.client)
    }

    /// 预览用：放进导航栈（按 `AppRoute` 分派），注入 Mock 客户端的 `AppModel`、`Router`，设好语言和深浅色。
    ///
    /// ```swift
    /// #Preview("收件箱 · 深色英文") {
    ///     InboxDestination(route: .inbox).previewShell(.english, scheme: .dark)
    /// }
    /// ```
    func previewShell(
        _ language: DisplayLanguage = .chinese, scheme: ColorScheme = .light, client: (any ClientProtocol)? = nil
    ) -> some View {
        PreviewShell(language: language, scheme: scheme, client: client ?? MockClient(autoReply: false)) { self }
    }
}

/// `previewShell()` 的容器：持有一个启动过的 `AppModel`。
private struct PreviewShell<Content: View>: View {
    let language: DisplayLanguage
    let scheme: ColorScheme
    let content: Content
    @State private var model: AppModel

    init(
        language: DisplayLanguage, scheme: ColorScheme, client: any ClientProtocol, @ViewBuilder content: () -> Content
    ) {
        self.language = language
        self.scheme = scheme
        self.content = content()
        _model = State(initialValue: AppModel(client: client, defaults: nil))
    }

    var body: some View {
        NavigationStack {
            content.appRouteDestinations()
        }
        .shellEnvironment(model)
        .tint(Theme.accent)
        .environment(\.displayLanguage, language)
        .preferredColorScheme(scheme)
        .task { await model.start() }
    }
}

/// 预览、界面测试用的几种客户端。
enum ShellPreviewClients {
    /// 演示数据，已登录。
    static func signedIn() -> MockClient { MockClient(autoReply: false) }

    /// 没登录。
    static func signedOut() -> MockClient { MockClient(state: DemoData.state(signedIn: false), autoReply: false) }

    /// 账号被冻结（启动时 `me()` 发现）。
    static func frozen() -> MockClient {
        var state = DemoData.state()
        state.user.status = .frozen
        return MockClient(state: state, autoReply: false)
    }

    /// 版本太老（启动时第一个调用就返回 `upgradeRequired`）。
    static func upgradeRequired() -> MockClient {
        let client = MockClient(autoReply: false)
        client.failNext(with: .upgradeRequired)
        return client
    }

    /// 还没有实例（新用户）。
    static func empty() -> MockClient {
        var state = DemoData.state()
        state.instances = []
        state.runs = []
        return MockClient(state: state, autoReply: false)
    }
}
