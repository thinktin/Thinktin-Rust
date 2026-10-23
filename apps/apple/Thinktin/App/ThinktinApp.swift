import SwiftUI
import ThinktinKit
import ThinktinUI

/// App 入口（WBS 12.1）。界面全部在 ThinktinUI 里；这里只做装配：启动时按 `AppConfiguration` 选好客户端
/// （Debug 默认 Mock，见 `AppEnvironment`；用真核心时先把 client-core 的日志接进系统日志，请求带设备语言的
/// `Accept-Language`），连同全局状态交给 `RootView`。
///
/// 深链（`thinktin://…`，project.yml 的 `CFBundleURLTypes` 注册了 scheme）交给 `Router`（WBS 12.16）：没登录、
/// 冻结时先记下，回到正常再跳。
///
/// 设置里选的外观和界面语言（WBS 12.12，`SettingsPreferences.shared`）由 `.settingsPreferences()` 套在根视图上生效：
/// 放在这里而不是 `RootView` 里，预览和界面测试照样能自己设 `\.displayLanguage` 和深浅色。
@main
struct ThinktinApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(model: environment.appModel)
                .settingsPreferences()
                .onOpenURL { url in
                    _ = environment.appModel.router.handle(url: url)
                }
        }
    }
}
