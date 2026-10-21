// swift-tools-version: 5.9
// ThinktinKit：iOS / macOS 共享的 Swift 包（WBS 12.1，见 docs/ios.md 第 2、3 节）。
//
// - ThinktinKit：纯 Swift（只依赖 Foundation）：领域模型、客户端协议与 Mock、对话归并、格式化。
// - ThinktinCoreAdapter：用 UniFFI 生成的 ThinktinCore 包实现 ClientProtocol。
// - ThinktinUI：SwiftUI 界面（只在 Apple 平台编译；Linux 上排除）。
//
// ThinktinCore 包不提交，构建时生成：macOS 上 tools/client-core/build-apple.sh target/apple，
// Linux 上 tools/client-core/build-linux-swift.sh target/linux。两者接口一致。
import PackageDescription

#if os(Linux)
    let corePackagePath = "../../../target/linux/ThinktinCore"
#else
    let corePackagePath = "../../../target/apple/ThinktinCore"
#endif

/// 每个目标都开严格并发检查（Swift 6 语言模式下本来就是完整检查，这里显式写上，降级编译时也不放松）。
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

var products: [Product] = [
    .library(name: "ThinktinKit", targets: ["ThinktinKit"]),
    .library(name: "ThinktinCoreAdapter", targets: ["ThinktinCoreAdapter"]),
]

var targets: [Target] = [
    .target(
        name: "ThinktinKit",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "ThinktinCoreAdapter",
        dependencies: [
            "ThinktinKit",
            .product(name: "ThinktinCore", package: "ThinktinCore"),
        ],
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "ThinktinKitTests",
        dependencies: ["ThinktinKit"],
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "ThinktinCoreAdapterTests",
        // 测试里直接构造 ThinktinCore 的记录（ConversionTests 等），要显式依赖，不能只靠适配层间接带进来。
        dependencies: [
            "ThinktinCoreAdapter",
            "ThinktinKit",
            .product(name: "ThinktinCore", package: "ThinktinCore"),
        ],
        swiftSettings: strictConcurrency
    ),
]

// SwiftUI 只在 Apple 平台有：Linux 上（云端会话、CI 的 kit-linux）不编界面层。
#if !os(Linux)
    products.append(.library(name: "ThinktinUI", targets: ["ThinktinUI"]))
    targets.append(contentsOf: [
        .target(
            name: "ThinktinUI",
            dependencies: ["ThinktinKit"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ThinktinUITests",
            dependencies: ["ThinktinUI", "ThinktinKit"],
            swiftSettings: strictConcurrency
        ),
    ])
#endif

let package = Package(
    name: "ThinktinKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    dependencies: [
        .package(name: "ThinktinCore", path: corePackagePath)
    ],
    targets: targets,
    swiftLanguageVersions: [.version("6")]
)
