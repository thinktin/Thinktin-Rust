// 主屏小组件（WBS 12.20）用到的 SwiftUI 接口：系统字号、语义颜色、分层样式。签名照 iOS 17 SDK。

extension Font {
    public static let title = Font(tag: 10)
    public static let title3 = Font(tag: 11)
    public static let headline = Font(tag: 12)
    public static let caption = Font(tag: 13)
    public static let caption2 = Font(tag: 14)
    public func bold() -> Font { self }
}

extension Color {
    public static let primary = Color(red: 0, green: 0, blue: 0)
    public static let secondary = Color(red: 0.5, green: 0.5, blue: 0.5)
    public static let accentColor = Color(red: 0, green: 0.5, blue: 1)
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
