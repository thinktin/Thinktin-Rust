// 量视图位置（`PageHeader` 报告大标题有没有滚到导航栏下面）和滚动边缘效果（iOS 26 的玻璃导航栏）的桩。

public protocol CoordinateSpaceProtocol {}

public struct NamedCoordinateSpace: CoordinateSpaceProtocol, Equatable, Sendable {}
public struct GlobalCoordinateSpace: CoordinateSpaceProtocol, Sendable {}
public struct LocalCoordinateSpace: CoordinateSpaceProtocol, Sendable {}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// 最近一层滚动视图的坐标系（iOS 17）。
    public static var scrollView: NamedCoordinateSpace { NamedCoordinateSpace() }
    public static func named(_ name: some Hashable) -> NamedCoordinateSpace { NamedCoordinateSpace() }
}

extension CoordinateSpaceProtocol where Self == GlobalCoordinateSpace {
    public static var global: GlobalCoordinateSpace { GlobalCoordinateSpace() }
}

extension CoordinateSpaceProtocol where Self == LocalCoordinateSpace {
    public static var local: LocalCoordinateSpace { LocalCoordinateSpace() }
}

public struct GeometryProxy {
    public var size: CGSize { .zero }
    public func frame(in coordinateSpace: some CoordinateSpaceProtocol) -> CGRect { .zero }
}

/// iOS 26 / macOS 26：滚动内容在导航栏、工具栏下面的边缘效果。
public struct ScrollEdgeEffectStyle: Hashable, Sendable {
    public static let automatic = ScrollEdgeEffectStyle()
    public static let hard = ScrollEdgeEffectStyle()
    public static let soft = ScrollEdgeEffectStyle()
}

extension View {
    /// iOS 16 起（回移植），量出来的值变了时调 `action`。
    public func onGeometryChange<T: Equatable>(
        for type: T.Type, of transform: @escaping @Sendable (GeometryProxy) -> T, action: @escaping (T) -> Void
    ) -> some View { _m() }

    public func onDisappear(perform action: (() -> Void)? = nil) -> some View { _m() }

    @available(iOS 26.0, macOS 26.0, *)
    public func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View { _m() }
}
