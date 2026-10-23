import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// 界面测试共用的工具（各功能的 Tests/ThinktinUITests/<功能>/ 都可以用）。

/// 测试用的屏幕尺寸（iPhone 的竖屏）。
let uiTestScreenSize = CGSize(width: 390, height: 844)

/// 浅色中文、深色英文各渲染一次，确认能出图（`ImageRenderer` 画得了的简单视图用它）。
@MainActor
func renderInBothAppearances(_ view: some View, sourceLocation: SourceLocation = #_sourceLocation) {
    for (scheme, language) in [(ColorScheme.light, DisplayLanguage.chinese), (.dark, .english)] {
        let content =
            view
            .padding()
            .background(Theme.paper)
            .environment(\.colorScheme, scheme)
            .environment(\.displayLanguage, language)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: uiTestScreenSize.width, height: nil)
        #expect(renderer.cgImage != nil, sourceLocation: sourceLocation)
    }
}

/// 放进平台的宿主控制器并布局（带导航栈、输入框、sheet 这类 `ImageRenderer` 画不了的视图用它），返回理想尺寸。
/// `expectContent` 为真时要求宽度大于 0；本来就可能什么都不画的视图（关着的抽屉）传 false，由调用方自己断言。
@MainActor
@discardableResult
func hostAndLayout(
    _ view: some View, expectContent: Bool = true, sourceLocation: SourceLocation = #_sourceLocation
) -> CGSize {
    #if canImport(UIKit)
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(origin: .zero, size: uiTestScreenSize)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let size = controller.sizeThatFits(in: uiTestScreenSize)
    #elseif canImport(AppKit)
        let controller = NSHostingController(rootView: view)
        controller.view.frame = CGRect(origin: .zero, size: uiTestScreenSize)
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.sizeThatFits(in: uiTestScreenSize)
    #endif
    if expectContent {
        #expect(size.width > 0, sourceLocation: sourceLocation)
    }
    return size
}
