// 设置的补充页（改版第 2 轮 r2/settings：权限与规则、订阅、导入记忆、发送反馈、保险箱的卡片和联系信息）用到的 SwiftUI 接口。
// 签名照 iOS 17 / macOS 14 SDK。

extension Font {
    /// iOS 13、macOS 11。
    public static let callout = Font(tag: 17)
}

extension OpenURLAction {
    /// iOS 14、macOS 11：`accepted` 是系统有没有打开它（比如没有处理 `mailto:` 的 App 时为 false）。
    public func callAsFunction(_ url: URL, completion: @escaping (_ accepted: Bool) -> Void) {}
}

/// iOS 15、macOS 12：SF Symbols 的画法（单色、分层、调色板、多色）。
public struct SymbolRenderingMode: Sendable {
    let v: Int
    public static let monochrome = SymbolRenderingMode(v: 0)
    public static let multicolor = SymbolRenderingMode(v: 1)
    public static let hierarchical = SymbolRenderingMode(v: 2)
    public static let palette = SymbolRenderingMode(v: 3)
}

extension View {
    /// iOS 15、macOS 12。
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> some View { _m() }
}

/// iOS 13、macOS 10.15：视图往上报的值（偏好）。
public protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}

/// iOS 13、macOS 11：`preferredColorScheme(_:)` 报上去的那个偏好。
public struct PreferredColorSchemeKey: PreferenceKey {
    public typealias Value = ColorScheme?
    public static var defaultValue: ColorScheme? { nil }
    public static func reduce(value: inout ColorScheme?, nextValue: () -> ColorScheme?) {}
}

extension View {
    /// iOS 13、macOS 10.15（iOS 18 / macOS 15 SDK 起回调是 `@Sendable`）。
    public func onPreferenceChange<K: PreferenceKey>(
        _ key: K.Type = K.self, perform action: @escaping @Sendable (K.Value) -> Void
    ) -> some View where K.Value: Equatable { _m() }
}
