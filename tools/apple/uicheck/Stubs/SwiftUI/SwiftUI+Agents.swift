// Agent 目录与领养（WBS 12.3）的界面用到、主桩文件（SwiftUI.swift）里还没有的 SwiftUI API。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// 单独放一个文件，免得和别的功能同时往 SwiftUI.swift 里加东西时合并冲突。

// MARK: - 文字输入（iOS 13）

extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
}

// MARK: - 确认框（iOS 15）

public enum Visibility: Hashable, CaseIterable, Sendable {
    case automatic, visible, hidden
}

extension View {
    public func confirmationDialog<S: StringProtocol, A: View, M: View>(
        _ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M
    ) -> some View { _m() }

    public func confirmationDialog<S: StringProtocol, A: View>(
        _ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> A
    ) -> some View { _m() }
}

// MARK: - 下拉刷新（iOS 15）、sheet 不让划走（iOS 15）

extension View {
    public func refreshable(action: @escaping @Sendable () async -> Void) -> some View { _m() }
    public func interactiveDismissDisabled(_ isDisabled: Bool = true) -> some View { _m() }
}

// MARK: - 动态字体（iOS 15 的 DynamicTypeSize、iOS 14 的 ScaledMetric）

public enum DynamicTypeSize: Hashable, Comparable, CaseIterable, Sendable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

    public var isAccessibilitySize: Bool { self >= .accessibility1 }
}

extension EnvironmentValues {
    public var dynamicTypeSize: DynamicTypeSize {
        get { .large }
        set {}
    }
}

extension View {
    public func dynamicTypeSize(_ size: DynamicTypeSize) -> some View { _m() }
}

@propertyWrapper
public struct ScaledMetric<Value: BinaryFloatingPoint>: DynamicProperty {
    let value: Value
    public init(wrappedValue: Value) { value = wrappedValue }
    public init(wrappedValue: Value, relativeTo textStyle: Font.TextStyle) { value = wrappedValue }
    public var wrappedValue: Value { value }
}
