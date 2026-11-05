// Botin 附加页（第 2 轮 r2/botin：观看与接管）用到的 SwiftUI API 桩，签名照 iOS 17 / macOS 14 SDK。

extension View {
    /// 导航栏、底部工具栏按深色或浅色画（iOS 16、macOS 13）：观看与接管页的黑底上按深色画。
    public func toolbarColorScheme(_ colorScheme: ColorScheme?, for bars: ToolbarPlacement...) -> some View { _m() }
}

extension UnitPoint {
    /// 渐变的起点、终点（iOS 13）：占位画面的斜向渐变。
    public static let topLeading = UnitPoint()
    public static let bottomTrailing = UnitPoint()
}

/// 内容边距加在哪（iOS 17、macOS 14）：分组列表顶上收紧（`compactGroupedList`）。
public struct ContentMarginPlacement: Sendable {
    let v: Int
    public static let automatic = ContentMarginPlacement(v: 0)
    public static let scrollContent = ContentMarginPlacement(v: 1)
    public static let scrollIndicators = ContentMarginPlacement(v: 2)
}

extension View {
    /// 滚动内容的边距（iOS 17、macOS 14）。
    public func contentMargins(
        _ edges: Edge.Set = .all, _ length: CGFloat?, for placement: ContentMarginPlacement = .automatic
    ) -> some View { _m() }
    public func contentMargins(_ length: CGFloat, for placement: ContentMarginPlacement = .automatic) -> some View {
        _m()
    }
    /// 导航栏、底部工具栏的底色和要不要画（iOS 16、macOS 13）：观看与接管页的黑色导航栏（状态栏跟着用浅色字）。
    public func toolbarBackground<S: ShapeStyle>(_ style: S, for bars: ToolbarPlacement...) -> some View { _m() }
    public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { _m() }
}
