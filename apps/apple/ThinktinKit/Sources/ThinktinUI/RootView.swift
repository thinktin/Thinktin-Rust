import SwiftUI
import ThinktinKit

/// 界面的根（App 的 `WindowGroup` 里只放它）：应用框架 `AppShell`（WBS 12.16）——按登录状态显示登录页、冻结页、
/// 升级页或主界面（导航栈 + 侧边抽屉）。
///
/// 界面只认 `ClientProtocol`，不知道背后是 Mock 还是真核心（见 App 的 `AppEnvironment`）。
public struct RootView: View {
    private let shell: AppShell

    /// 自己建全局状态（预览、测试）。
    public init(client: any ClientProtocol) {
        shell = AppShell(client: client)
    }

    /// 用 App 装配好的全局状态：App 的 `onOpenURL` 把深链交给同一个 `model.router`。
    public init(model: AppModel) {
        shell = AppShell(model: model)
    }

    public var body: some View {
        shell
    }
}

#Preview("根页面 · 浅色中文") {
    RootView(client: MockClient(autoReply: false))
        .environment(\.displayLanguage, .chinese)
}

#Preview("根页面 · 深色英文") {
    RootView(client: MockClient(autoReply: false))
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
