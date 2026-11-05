// iOS 18 / 26 才有的 SwiftUI API（docs/ios-ui-redesign.md 第 2.10 节的表）：Liquid Glass、新的工具栏项、底部条、
// 关闭和确认按钮、缩放转场。界面里只经过 ThinktinUI 的 Design/Glass.swift 用它们（那里每个都带旧系统的退路）。
// 签名照 iOS 26 / macOS 26 SDK 的文档，`@available` 照抄：Linux 上不检查 iOS / macOS 的版本，漏写 `if #available`
// 这里查不出来，以 macOS CI 为准。缩放转场 macOS 上没有，放在 `#if canImport(UIKit)` 里。

// MARK: - 命名空间（iOS 14）

@propertyWrapper
public struct Namespace: DynamicProperty, Sendable {
    public struct ID: Hashable, Sendable {}
    public init() {}
    public var wrappedValue: Namespace.ID { ID() }
}

// MARK: - Liquid Glass（iOS 26、macOS 26）

@available(iOS 26.0, macOS 26.0, *)
public struct Glass: Equatable, Sendable {
    let v: Int
    public static var regular: Glass { Glass(v: 0) }
    public static var clear: Glass { Glass(v: 1) }
    public static var identity: Glass { Glass(v: 2) }
    public func tint(_ color: Color?) -> Glass { self }
    public func interactive(_ isEnabled: Bool = true) -> Glass { self }
}

/// `glassEffect` 默认的形状（胶囊）。
@available(iOS 26.0, macOS 26.0, *)
public struct DefaultGlassEffectShape: Shape {
    public init() {}
}

@available(iOS 26.0, macOS 26.0, *)
public struct GlassEffectContainer<Content: View>: View {
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

@available(iOS 26.0, macOS 26.0, *)
extension View {
    public func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View {
        _m()
    }
    public func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View { _m() }
}

@available(iOS 26.0, macOS 26.0, *)
public struct GlassButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public init(_ glass: Glass) {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

@available(iOS 26.0, macOS 26.0, *)
public struct GlassProminentButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

@available(iOS 26.0, macOS 26.0, *)
extension PrimitiveButtonStyle where Self == GlassButtonStyle {
    public static var glass: GlassButtonStyle { GlassButtonStyle() }
}

@available(iOS 26.0, macOS 26.0, *)
extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle {
    public static var glassProminent: GlassProminentButtonStyle { GlassProminentButtonStyle() }
}

// MARK: - 关闭、确认按钮（iOS 26、macOS 26）：系统按角色画图标（玻璃圆 ×、对勾）和读屏标签

extension ButtonRole {
    @available(iOS 26.0, macOS 26.0, *)
    public static var close: ButtonRole { ButtonRole() }
    @available(iOS 26.0, macOS 26.0, *)
    public static var confirm: ButtonRole { ButtonRole() }
}

/// 按角色生成的按钮标签。
@available(iOS 26.0, macOS 26.0, *)
public struct DefaultButtonLabel: View {
    public var body: Never { fatalError() }
}

@available(iOS 26.0, macOS 26.0, *)
extension Button where Label == DefaultButtonLabel {
    public init(role: ButtonRole, action: @escaping @MainActor () -> Void) {}
}

// MARK: - 工具栏（iOS 26、macOS 26）：间隔、系统项的位置、共享的玻璃底

@available(iOS 26.0, macOS 26.0, *)
public struct SpacerSizing: Sendable {
    let v: Int
    public static var fixed: SpacerSizing { SpacerSizing(v: 0) }
    public static var flexible: SpacerSizing { SpacerSizing(v: 1) }
}

@available(iOS 26.0, macOS 26.0, *)
public struct ToolbarSpacer: ToolbarContent {
    public init(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic) {}
    public var body: Never { fatalError() }
}

/// 把系统加的项（`searchable` 的搜索栏）放到指定位置，比如首页底部（`placement: .bottomBar`）。
@available(iOS 26.0, macOS 26.0, *)
public struct DefaultToolbarItem: ToolbarContent {
    public init(kind: ToolbarDefaultItemKind, placement: ToolbarItemPlacement) {}
    public var body: Never { fatalError() }
}

@available(iOS 26.0, macOS 26.0, *)
extension ToolbarContent {
    public func sharedBackgroundVisibility(_ visibility: Visibility) -> some ToolbarContent { self }
    /// 工具栏项上的角标（View 的 `.badge(_:)` 在 iOS 26 的工具栏里不画）。
    public func badge(_ count: Int) -> some ToolbarContent { self }
    public func badge(_ label: Text?) -> some ToolbarContent { self }
}

// MARK: - 底部条（iOS 26、macOS 26）：和 safeAreaInset 一样占安全区，还会延伸滚动边缘效果

@available(iOS 26.0, macOS 26.0, *)
extension View {
    public func safeAreaBar(
        edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View { _m() }
    public func safeAreaBar(
        edge: HorizontalEdge, alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View { _m() }
}

// MARK: - 工具栏显隐（iOS 18、macOS 15）

@available(iOS 18.0, macOS 15.0, *)
extension View {
    public func toolbarVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { _m() }
}

// MARK: - 缩放转场（iOS 18；macOS 上没有 `.zoom`）

#if canImport(UIKit)
    @available(iOS 18.0, *)
    public protocol NavigationTransition {}

    @available(iOS 18.0, *)
    public struct ZoomNavigationTransition: NavigationTransition {}

    @available(iOS 18.0, *)
    public struct AutomaticNavigationTransition: NavigationTransition {}

    @available(iOS 18.0, *)
    extension NavigationTransition where Self == ZoomNavigationTransition {
        public static func zoom(sourceID: some Hashable, in namespace: Namespace.ID) -> ZoomNavigationTransition {
            ZoomNavigationTransition()
        }
    }

    @available(iOS 18.0, *)
    extension NavigationTransition where Self == AutomaticNavigationTransition {
        public static var automatic: AutomaticNavigationTransition { AutomaticNavigationTransition() }
    }

    @available(iOS 18.0, *)
    extension View {
        public func navigationTransition(_ style: some NavigationTransition) -> some View { _m() }
        public func matchedTransitionSource(id: some Hashable, in namespace: Namespace.ID) -> some View { _m() }
    }
#endif
