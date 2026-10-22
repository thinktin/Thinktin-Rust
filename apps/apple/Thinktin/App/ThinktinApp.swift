import SwiftUI
import ThinktinKit
import ThinktinUI

/// App 入口（WBS 12.1）。界面全部在 ThinktinUI 里；这里只做装配：启动时按 `AppConfiguration` 选好客户端
/// （Debug 默认 Mock，见 `AppEnvironment`），连同全局状态交给 `RootView`。
///
/// 深链（`thinktin://…`，project.yml 的 `CFBundleURLTypes` 注册了 scheme）交给 `Router`（WBS 12.16）：没登录、
/// 冻结时先记下，回到正常再跳。
@main
struct ThinktinApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(model: environment.appModel)
                .onOpenURL { url in
                    _ = environment.appModel.router.handle(url: url)
                }
        }
    }
}
