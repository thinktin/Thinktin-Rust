// swift-tools-version: 6.0
// Linux 上给 ThinktinUI、App target、小组件扩展和 macOS App 做类型检查的包（tools/apple/uicheck/run.sh）：SwiftUI / UIKit / AppKit / Security /
// OSLog / Charts / UserNotifications / WidgetKit / AppIntents / ActivityKit / LocalAuthentication / CryptoKit
// 用桩模块代替。
import PackageDescription
import Foundation

let platformStub = ProcessInfo.processInfo.environment["UISTUB_PLATFORM"] ?? "UIKit"
/// UIKit 版查 iOS App 和小组件扩展；AppKit 版查 macOS App（14.5，ThinktinCore 用 `build-linux-swift.sh --desktop` 打的包）。
let withApp = platformStub == "UIKit"
let withMac = platformStub == "AppKit"

var targets: [Target] = [
    .target(name: "CoreGraphics", path: "Stubs/CoreGraphics"),
    .target(name: platformStub, dependencies: ["CoreGraphics"], path: "Stubs/\(platformStub)"),
    .target(name: "SwiftUI", dependencies: ["CoreGraphics", .target(name: platformStub)], path: "Stubs/SwiftUI"),
    // Swift Charts 的桩（12.4 的用量看板）。
    .target(name: "Charts", dependencies: ["SwiftUI"], path: "Stubs/Charts"),
    // 通知中心的桩（12.8 推送、12.12 读通知权限）。
    .target(name: "UserNotifications", path: "Stubs/UserNotifications"),
    // 本机验证的桩（12.5 批准前、12.9 签名前）。
    .target(name: "LocalAuthentication", path: "Stubs/LocalAuthentication"),
    .target(name: "ThinktinKit", path: "Gen/ThinktinKit"),
    .target(
        name: "ThinktinUI", dependencies: ["ThinktinKit", "SwiftUI", "Charts", "UserNotifications", "LocalAuthentication"],
        path: "Gen/ThinktinUI"),
    .testTarget(name: "ThinktinUITests", dependencies: ["ThinktinUI", "ThinktinKit", "SwiftUI"], path: "Gen/ThinktinUITests"),
]
// 两个 App 都要的：钥匙串、系统日志、CryptoKit（iOS 的 Secure Enclave 签名密钥、Mac 的配对密钥）、真核心的适配层。
let core: Target.Dependency = .product(name: "ThinktinCore", package: "ThinktinCore")
var dependencies: [Package.Dependency] = [
    .package(name: "ThinktinCore", path: withMac ? "../../../target/linux-desktop/ThinktinCore" : "../../../target/linux/ThinktinCore")
]
targets += [
    .target(name: "Security", dependencies: ["CoreGraphics"], path: "Stubs/Security"),
    .target(name: "OSLog", path: "Stubs/OSLog"),
    .target(name: "CryptoKit", dependencies: ["Security", "LocalAuthentication"], path: "Stubs/CryptoKit"),
    .target(name: "ThinktinCoreAdapter", dependencies: ["ThinktinKit", core], path: "Gen/ThinktinCoreAdapter"),
]
if withApp {
    targets += [
        // 主屏小组件、快捷指令的桩（12.20）。
        // 实时活动的桩（12.10）。
        .target(name: "ActivityKit", path: "Stubs/ActivityKit"),
        .target(name: "WidgetKit", dependencies: ["SwiftUI", "ActivityKit"], path: "Stubs/WidgetKit"),
        .target(name: "AppIntents", path: "Stubs/AppIntents"),
        // 扫配对二维码（12.9）。
        .target(name: "Vision", path: "Stubs/Vision"),
        .target(name: "VisionKit", dependencies: ["UIKit", "Vision"], path: "Stubs/VisionKit"),
        .executableTarget(
            name: "Thinktin",
            dependencies: [
                "ThinktinKit", "ThinktinUI", "ThinktinCoreAdapter", "SwiftUI", "UIKit", "Security", "OSLog",
                "UserNotifications", "WidgetKit", "AppIntents", "ActivityKit", "CryptoKit", "LocalAuthentication", "Vision",
                "VisionKit",
            ],
            path: "Gen/Thinktin"),
        .executableTarget(
            name: "ThinktinWidgets", dependencies: ["ThinktinKit", "SwiftUI", "WidgetKit", "ActivityKit"],
            path: "Gen/ThinktinWidgets"),
        .testTarget(name: "ThinktinTests", dependencies: ["Thinktin"], path: "Gen/ThinktinTests"),
    ]
}
if withMac {
    targets += [
        // 截图、键鼠、辅助功能权限、登录项、配对二维码（14.3–14.8）。
        .target(name: "ApplicationServices", dependencies: ["CoreGraphics"], path: "Stubs/ApplicationServices"),
        .target(name: "ScreenCaptureKit", dependencies: ["CoreGraphics"], path: "Stubs/ScreenCaptureKit"),
        .target(name: "ServiceManagement", path: "Stubs/ServiceManagement"),
        .target(name: "CoreImage", dependencies: ["CoreGraphics"], path: "Stubs/CoreImage"),
        .target(name: "ThinktinDesktopAdapter", dependencies: ["ThinktinKit", core], path: "Gen/ThinktinDesktopAdapter"),
        .executableTarget(
            name: "ThinktinMac",
            dependencies: [
                "ThinktinKit", "ThinktinUI", "ThinktinCoreAdapter", "ThinktinDesktopAdapter", "SwiftUI", "AppKit",
                "Security", "OSLog", "CryptoKit", "ApplicationServices", "ScreenCaptureKit", "ServiceManagement",
                "CoreImage",
            ],
            path: "Gen/ThinktinMac"),
    ]
}

let package = Package(name: "UICheck", dependencies: dependencies, targets: targets)
