// WBS 12.8（App 代理接推送）用到的 SwiftUI 类型的桩：签名照 Apple 文档（iOS 17 SDK）。

#if canImport(UIKit)
    /// SwiftUI App 用的 UIKit App 代理：SwiftUI 建好代理对象，`wrappedValue` 就是它。
    @MainActor @preconcurrency @propertyWrapper
    public struct UIApplicationDelegateAdaptor<DelegateType: NSObject & UIApplicationDelegate>: DynamicProperty {
        public init(_ delegateType: DelegateType.Type = DelegateType.self) {}
        public var wrappedValue: DelegateType { fatalError() }
    }
#endif
