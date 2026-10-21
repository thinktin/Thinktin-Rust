# Apple 客户端

iOS（和以后的 macOS）App，Swift + SwiftUI 原生开发，界面参考 Claude iOS App 的信息架构和视觉。iOS / macOS 共享
`ThinktinKit`；网络、续传、缓存、密码识别、配对验签都在 Rust 的 `crates/client-core` 里，经 UniFFI 生成的
`ThinktinCore` 包调用。工程上的决定（目录、分层、设计令牌、事件归并、错误处理）见 [docs/ios.md](../../docs/ios.md)，
进度见 [docs/progress/ios-app.md](../../docs/progress/ios-app.md)，整体架构见 [架构方案 v3 第 8 节](../../docs/architecture-v3.md)。

```
apps/apple/
  project.yml        XcodeGen 工程定义（不提交 .xcodeproj、Info.plist、.entitlements，都由它生成）
  Thinktin/          iOS App target：App/（入口、依赖装配）、Platform/（Keychain、推送、生物识别…）、Resources/
  Tests/ThinktinTests/  App 的单元测试（跑在模拟器上，宿主是 App）
  ThinktinKit/       Swift Package：ThinktinKit（纯 Swift）、ThinktinUI（SwiftUI）、ThinktinCoreAdapter
```

## 本机构建（macOS，Xcode 26）

```sh
brew install cmake xcodegen                      # cmake：aws-lc-rs 交叉编译要；XcodeGen 2.46 以上
tools/client-core/build-apple.sh target/apple    # 打 ThinktinCore（xcframework + Swift 包），在仓库根目录跑
cd apps/apple && xcodegen generate               # 生成 Thinktin.xcodeproj
open Thinktin.xcodeproj
```

- 改了 `project.yml`、加删了文件都要重新 `xcodegen generate`；Info.plist 和权限（entitlements）也在 `project.yml` 里改，
  生成的文件会被覆盖。
- 签名：`DEVELOPMENT_TEAM` 留空，在 Xcode 的 Signing & Capabilities 里选自己的团队（或
  `xcodebuild DEVELOPMENT_TEAM=XXXXXXXXXX`）。只在模拟器上跑可以不签：`CODE_SIGNING_ALLOWED=NO`，但不签名时
  Keychain 可能报 `errSecMissingEntitlement`（-34018），登录态存不住；要测 Keychain 就签名跑。
- 客户端：Debug 默认用 `MockClient`（演示数据，不连网），Release 默认连真接口。环境变量 `THINKTIN_MOCK=1` / `0`
  强制选一边（scheme 的 Run 里已经放了一项，勾上就行）。接口地址默认 `https://api.thinktin.cn`，连测试环境时
  `xcodebuild THINKTIN_API_BASE_URL=https://...`（写进 Info.plist 的 `ThinktinAPIBaseURL`）。
- 只想快点编模拟器：`tools/client-core/build-apple.sh target/apple --ci` 只打模拟器和 macOS 的 arm64 两个切片，
  打出来的包不能装真机。

命令行跑测试（和 CI 一样）：

```sh
cd apps/apple
xcodebuild -project Thinktin.xcodeproj -scheme Thinktin \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build test
```

## Linux 上（云端会话，没有 Xcode）

SwiftUI 和 App target 编不了，`ThinktinKit` 的纯 Swift 部分和 ThinktinCore 适配层可以（`Package.swift` 在 Linux 上
排除 `ThinktinUI`）。要 Swift 6.2 工具链（云端会话在 `/opt/swift/usr/bin`）：

```sh
export PATH=/opt/swift/usr/bin:$PATH
tools/client-core/build-linux-swift.sh target/linux   # 本机的 libclient_core.so + 同一份 UniFFI 绑定
cd apps/apple/ThinktinKit && swift build && swift test
```

App target 里不依赖 UIKit / Security 的文件可以 `swiftc -typecheck` 查语法；其余的靠 CI 的 macOS 任务编译。

## CI（`.github/workflows/ios.yml`）

推到 `ios-app`、`main` 和 PR 时，改了 `apps/apple/**`、`crates/client-core/**`、`crates/proto/**`、
`tools/client-core/**`（以及 Cargo 依赖、许可证工具、这个 workflow 本身）就跑，按 docs/ios.md 第 7 节：

1. **kit-linux**（ubuntu-24.04）：装 swift.org 的 Swift 6.2（验签），`build-linux-swift.sh`，`swift build && swift test`。
2. **app-macos**（macos-26，有 Xcode 26.6 就用它）：`build-apple.sh target/apple --ci`；`ThinktinKit` 上 `swift build`
   （macOS 原生，编 ThinktinUI）；`xcodegen generate`；挑最新 iOS 运行时里第一个可用的 iPhone 模拟器，
   `xcodebuild build test`（App 的 `ThinktinTests` 和 ThinktinKit 的 `ThinktinUITests`），不签名。

两个任务的构建日志、`xcodebuild` 的日志和 `.xcresult` 结果包都传成 artifact（失败了也传），在 Actions 页面下载看。
