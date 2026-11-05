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
