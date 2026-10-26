// macOS App（14.5）用到的 SwiftUI 类型的桩：菜单栏、单个窗口、打开窗口、App 代理。签名照 macOS 14 SDK。

extension SceneBuilder {
    public static func buildBlock<C0: Scene, C1: Scene>(_ c0: C0, _ c1: C1) -> _TupleScene<C0, C1> { _TupleScene() }
}

public struct _TupleScene<C0: Scene, C1: Scene>: Scene {
    public var body: Never { fatalError() }
}

extension Image {
    public enum Orientation: Hashable, Sendable { case up, down, left, right }
    public init(decorative cgImage: CGImage, scale: CGFloat, orientation: Orientation = .up) {
        self.init(systemName: "")
    }
}

#if canImport(AppKit)
    @MainActor @preconcurrency @propertyWrapper
    public struct NSApplicationDelegateAdaptor<DelegateType: NSObject & NSApplicationDelegate>: DynamicProperty {
        public init(_ delegateType: DelegateType.Type = DelegateType.self) {}
        public var wrappedValue: DelegateType { fatalError() }
    }

    public struct MenuBarExtra<Label: View, Content: View>: Scene {
        public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
        public var body: Never { fatalError() }
    }

    public protocol MenuBarExtraStyle {}
    public struct WindowMenuBarExtraStyle: MenuBarExtraStyle {}
    public struct PullDownMenuBarExtraStyle: MenuBarExtraStyle {}
    extension MenuBarExtraStyle where Self == WindowMenuBarExtraStyle {
        public static var window: WindowMenuBarExtraStyle { WindowMenuBarExtraStyle() }
    }

    public struct Window<Content: View>: Scene {
        public init(_ title: LocalizedStringKey, id: String, @ViewBuilder content: () -> Content) {}
        public var body: Never { fatalError() }
    }

    extension Scene {
        public func menuBarExtraStyle<S: MenuBarExtraStyle>(_ style: S) -> some Scene { self }
        public func defaultSize(width: CGFloat, height: CGFloat) -> some Scene { self }
    }

    @MainActor @preconcurrency
    public struct OpenWindowAction {
        public func callAsFunction(id: String) {}
    }

    extension EnvironmentValues {
        public var openWindow: OpenWindowAction { OpenWindowAction() }
    }
#endif
