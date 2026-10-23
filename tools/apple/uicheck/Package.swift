// swift-tools-version: 6.0
// Linux 上给 ThinktinUI 和 App target 做类型检查的包（tools/apple/uicheck/run.sh）：SwiftUI / UIKit / AppKit / Security / OSLog / Charts 用桩模块代替。
import PackageDescription
import Foundation

let platformStub = ProcessInfo.processInfo.environment["UISTUB_PLATFORM"] ?? "UIKit"
let withApp = platformStub == "UIKit"

var targets: [Target] = [
    .target(name: "CoreGraphics", path: "Stubs/CoreGraphics"),
    .target(name: platformStub, dependencies: ["CoreGraphics"], path: "Stubs/\(platformStub)"),
    .target(name: "SwiftUI", dependencies: ["CoreGraphics", .target(name: platformStub)], path: "Stubs/SwiftUI"),
    // Swift Charts 的桩（12.4 的用量看板）。
    .target(name: "Charts", dependencies: ["SwiftUI"], path: "Stubs/Charts"),
    .target(name: "ThinktinKit", path: "Gen/ThinktinKit"),
    .target(name: "ThinktinUI", dependencies: ["ThinktinKit", "SwiftUI", "Charts"], path: "Gen/ThinktinUI"),
    .testTarget(name: "ThinktinUITests", dependencies: ["ThinktinUI", "ThinktinKit", "SwiftUI"], path: "Gen/ThinktinUITests"),
]
var dependencies: [Package.Dependency] = []
if withApp {
    dependencies.append(.package(name: "ThinktinCore", path: "../../../target/linux/ThinktinCore"))
    targets += [
        .target(name: "Security", path: "Stubs/Security"),
        .target(name: "OSLog", path: "Stubs/OSLog"),
        .target(
            name: "ThinktinCoreAdapter",
            dependencies: ["ThinktinKit", .product(name: "ThinktinCore", package: "ThinktinCore")],
            path: "Gen/ThinktinCoreAdapter"),
        .executableTarget(
            name: "Thinktin",
            dependencies: ["ThinktinKit", "ThinktinUI", "ThinktinCoreAdapter", "SwiftUI", "UIKit", "Security", "OSLog"],
            path: "Gen/Thinktin"),
        .testTarget(name: "ThinktinTests", dependencies: ["Thinktin"], path: "Gen/ThinktinTests"),
    ]
}

let package = Package(name: "UICheck", dependencies: dependencies, targets: targets)
