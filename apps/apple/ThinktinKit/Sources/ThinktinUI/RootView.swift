import SwiftUI
import ThinktinKit

/// 界面的根（App 的 `WindowGroup` 里只放它）。接收装配好的客户端（Mock 或真核心，见 App 的 `AppEnvironment`），
/// 界面只认 `ClientProtocol`，不知道背后是哪一个。
///
/// 现在先显示欢迎页的占位（`WelcomeView`）；登录（12.2）、对话（12.5）、抽屉导航与全局状态（12.16）接进来后，
/// 在这里按登录状态、冻结、强制升级切换根页面。
public struct RootView: View {
    private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    public var body: some View {
        WelcomeView(client: client)
    }
}

#Preview("根页面") {
    RootView(client: MockClient())
}

#Preview("根页面 · 深色") {
    RootView(client: MockClient())
        .preferredColorScheme(.dark)
}
