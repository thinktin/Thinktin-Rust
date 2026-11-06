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
///
/// 截图脚本启动的（Debug 构建，`AppConfiguration.isScreenshotLaunch`）关掉 Botin 的脸的动效（`\.botinFaceMotion`）：
/// 不眨眼、不转眼、不做小动作和反应，换形状不做动画，每次截出来的一样。
@main
struct ThinktinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Botin 的脸动不动：截图脚本启动的不动（启动时读一次环境变量，只有 Debug 构建认）。
    #if DEBUG
        private static let botinFaceMotion = !AppConfiguration.isScreenshotLaunch(
            environment: ProcessInfo.processInfo.environment)
    #else
        private static let botinFaceMotion = true
    #endif

    var body: some Scene {
        let environment = delegate.environment
        let model = environment.appModel
        WindowGroup {
            RootView(model: model)
                .settingsPreferences()
                .environment(\.botinFaceMotion, Self.botinFaceMotion)
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
                .task {
                    // 截图脚本（tools/apple/screenshots.sh）用环境变量指定启动后打开的页面，只有 Debug 构建认。
                    #if DEBUG
                        let environment = ProcessInfo.processInfo.environment
                        if let url = AppConfiguration.launchURL(environment: environment) {
                            _ = model.router.handle(url: url)
                        }
                        if let screen = AppConfiguration.openScreen(environment: environment) {
                            await screen.open(in: model)
                        }
                    #endif
                }
        }
    }
}
