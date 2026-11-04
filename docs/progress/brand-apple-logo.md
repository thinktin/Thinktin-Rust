# brand/apple-logo

目标：用 Logo G1.0（`docs/brand/logo`）换掉 Apple 端的临时图标和 App 里的占位标志（用户 2026-11-04 要求）。

已完成：
- `tools/apple/brand_assets.py`：从几何参数生成原生矢量 Logo 的 Swift 代码（`BrandLogoGeometry`，圆弧转贝塞尔，`--check` 和原稿逐像素比较为 0 差），渲染 iPhone 图标（浅色 / 深色 / 着色）和 Mac 图标（16～1024）。
- `BrandLogo` 视图（`ThinktinUI/Design`）：欢迎页换掉原来的 “T” 方块，侧边栏顶上 ThinkTin 字样前加 Logo。几何放在非视图的 `BrandLogoGeometry` 里（视图是主线程隔离的，`Shape.path(in:)` 不是）。
- uicheck 桩补了 Path、StrokeStyle、LinearGradient、GeometryReader、aspectRatio 等（`Stubs/SwiftUI/SwiftUI+Brand.swift`）。
- `docs/ios.md` 第 1 节第 5 条：按钮这类控件能用系统原生的一律用原生的（用户定的）；4.1 节写 Logo 和图标怎么生成。
- 验证：uicheck（UIKit、AppKit）、`run.sh test` 111 个（含 Logo 3 个）、严格格式检查 0 条。

进行中：PR，macOS CI 编真实 SwiftUI。

下一步：
- 合并后发一个演示版 TestFlight，用户在手机上看新图标。
- 安卓、Windows 的图标是别的会话的线，要换的话用同一份 `docs/brand/logo`。
- 用户会发 UI 设计稿，按它改版（第 1 节第 5 条：控件用原生的）。

坑和决定：
- macOS 的图标要自己画外形（系统不加圆角），iPhone 的不用（系统加），所以两套分开生成。
- iPhone 的浅色图标不能有透明通道（App Store 会拒），深色和着色可以透明。
