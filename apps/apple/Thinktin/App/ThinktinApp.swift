import SwiftUI
import ThinktinKit
import ThinktinUI
import UIKit

/// App 入口（WBS 12.1）。界面全部在 ThinktinUI 里；这里只做装配：启动时按 `AppConfiguration` 选好客户端
/// （Debug 默认 Mock，见 `AppEnvironment`；用真核心时先把 client-core 的日志接进系统日志，请求带设备语言的
/// `Accept-Language`），连同全局状态交给 `RootView`。
///
/// 深链（`thinktin://…`，project.yml 的 `CFBundleURLTypes` 注册了 scheme）交给 `Router`（WBS 12.16）：没登录、
/// 冻结时先记下，回到正常再跳。推送（12.8）的系统回调在 `AppDelegate`，装配（`AppEnvironment`）也由它建：冷启动点开
/// 通知时，回调可能比界面先到。登录时带上 APNs 令牌（`\.signInPushRegistration`）。登录之后（同意了隐私政策）才向 APNs
/// 注册（12.17：同意之前不收集信息）；通知权限在引导的最后一步才问（`\.notificationAuthorizer`）。
///
/// 设置里选的外观和界面语言（WBS 12.12，`SettingsPreferences.shared`）由 `.settingsPreferences()` 套在根视图上生效：
/// 放在这里而不是 `RootView` 里，预览和界面测试照样能自己设 `\.displayLanguage` 和深浅色。
@main
struct ThinktinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let environment = delegate.environment
        let model = environment.appModel
        WindowGroup {
            RootView(model: model)
                .settingsPreferences()
                .environment(\.signInPushRegistration, SignInPushRegistration { model.pushRegistration })
                .environment(\.notificationAuthorizer, PushAuthorizer(registrar: environment.pushRegistrar))
                // 手机控制电脑（12.9）：安全芯片里的签名密钥、client-core 的编码、扫码。
                .environment(\.deviceSigner, environment.deviceSigner)
                .environment(\.pairingCodec, environment.pairingCodec)
                .environment(\.pairingScanner, PairingCodeScanner.environmentValue)
                .onChange(of: model.phase, initial: true) {
                    if model.phase == .signedIn, Bundle.main.bundleURL.pathExtension == "app" {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
                .onOpenURL { url in
                    _ = model.router.handle(url: url)
                }
        }
    }
}
