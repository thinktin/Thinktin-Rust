// Logo（ThinktinUI 的 `BrandLogo`）用到、别的桩文件里还没有的 SwiftUI / CoreGraphics 接口：路径、描边样式、线性渐变、
// GeometryReader、宽高比。签名照 iOS 17 / macOS 14 SDK，只为类型检查，实现全是空的。

// MARK: - 路径与描边（iOS 13）

public enum CGLineCap: Int32, Sendable { case butt, round, square }
public enum CGLineJoin: Int32, Sendable { case miter, round, bevel }

public struct Path: Sendable {
  public init() {}
  public mutating func move(to point: CGPoint) {}
  public mutating func addLine(to point: CGPoint) {}
  public mutating func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {}
  public mutating func closeSubpath() {}
  public var boundingRect: CGRect { .zero }
}

public struct StrokeStyle: Equatable, Sendable {
  public init(
    lineWidth: CGFloat = 1, lineCap: CGLineCap = .butt, lineJoin: CGLineJoin = .miter,
    miterLimit: CGFloat = 10,
    dash: [CGFloat] = [], dashPhase: CGFloat = 0
  ) {}
}

extension Shape {
  /// 自定义形状只写 `path(in:)`，`body` 由 SwiftUI 提供。
  public var body: Never { fatalError() }
  public func stroke<S: ShapeStyle>(_ content: S, style: StrokeStyle, antialiased: Bool = true)
    -> some View
  { _m() }
}

// MARK: - 渐变（iOS 13）

public struct Gradient: Hashable, Sendable {
  public struct Stop: Hashable, Sendable {
    public init(color: Color, location: CGFloat) {}
  }
  public init(stops: [Stop]) {}
}

public struct LinearGradient: ShapeStyle, View {
  public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {}
  public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {}
  public var body: Never { fatalError() }
}

extension UnitPoint {
  public init(x: CGFloat, y: CGFloat) { self.init() }
}

// MARK: - 布局（iOS 13）

public enum ContentMode: Hashable, Sendable, CaseIterable { case fit, fill }

public struct GeometryReader<Content: View>: View {
  public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {}
  public var body: Never { fatalError() }
}

extension View {
  public func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> some View {
    _m()
  }
}

extension AccessibilityTraits {
  public static let isImage = AccessibilityTraits(5)
}
