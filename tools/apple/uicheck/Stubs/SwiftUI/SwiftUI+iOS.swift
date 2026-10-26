// 只有 iOS 有的 SwiftUI 接口（UIKit 版的桩里才有，和真实 SDK 一样 macOS 上没有）。prep.py 把 ThinktinUI 里的
// `#if os(iOS)` 换成了 `#if canImport(UIKit)`，这些分支在 UIKit 版里会被类型检查。

#if canImport(UIKit)
    /// 把 UIKit 的视图控制器放进 SwiftUI（12.9 的扫码框）。
    @MainActor @preconcurrency
    public protocol UIViewControllerRepresentable: View where Body == Never {
        associatedtype UIViewControllerType: UIViewController
        associatedtype Coordinator = Void
        typealias Context = UIViewControllerRepresentableContext<Self>
        func makeUIViewController(context: Context) -> UIViewControllerType
        func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context)
        func makeCoordinator() -> Coordinator
    }

    extension UIViewControllerRepresentable where Coordinator == Void {
        public func makeCoordinator() {}
    }

    extension UIViewControllerRepresentable {
        public var body: Never { fatalError() }
    }

    @MainActor
    public struct UIViewControllerRepresentableContext<Representable: UIViewControllerRepresentable> {
        public var coordinator: Representable.Coordinator { fatalError() }
    }

    public struct NavigationBarItem: Sendable {
        public enum TitleDisplayMode: Hashable, Sendable {
            case automatic, inline, large
        }
    }
#endif
