// 主屏小组件（WBS 12.20）用到的 SwiftUI 接口：系统字号、语义颜色、分层样式。签名照 iOS 17 SDK。

extension Font {
    public static let title = Font(tag: 10)
    public static let title3 = Font(tag: 11)
    public static let headline = Font(tag: 12)
    public static let caption = Font(tag: 13)
    public static let caption2 = Font(tag: 14)
    public static let title2 = Font(tag: 15)
    public static let subheadline = Font(tag: 16)
    public func bold() -> Font { self }
}

extension Color {
    public static let primary = Color(red: 0, green: 0, blue: 0)
    public static let secondary = Color(red: 0.5, green: 0.5, blue: 0.5)
    public static let accentColor = Color(red: 0, green: 0.5, blue: 1)
    public static let orange = Color(red: 1, green: 0.6, blue: 0)
}

extension Text {
    /// 系统计时器（实时活动的耗时，12.10）。
    public init(
        timerInterval: ClosedRange<Date>, pauseTime: Date? = nil, countsDown: Bool = true, showsHours: Bool = true
    ) {
        self.init(verbatim: "")
    }
}

public struct HierarchicalShapeStyle: ShapeStyle {
    public static let primary = HierarchicalShapeStyle()
    public static let secondary = HierarchicalShapeStyle()
    public static let tertiary = HierarchicalShapeStyle()
}

extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
    public static var secondary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
    public static var tertiary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
}

public struct FillShapeStyle: ShapeStyle {
    public init() {}
}

extension ShapeStyle where Self == FillShapeStyle {
    public static var fill: FillShapeStyle { FillShapeStyle() }
}

extension ShapeStyle {
    public var secondary: some ShapeStyle { self }
    public var tertiary: some ShapeStyle { self }
}

// 12.9 的扫码框用到的。
extension View {
    public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View { _m() }
}
