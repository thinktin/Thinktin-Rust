// WBS 12.2（登录、账号、设备页面）用到的 SwiftUI API 的桩：签名照 Apple 文档（iOS 17 / macOS 14 SDK），实现全是空的。
import Observation

// MARK: - 焦点

@propertyWrapper
public struct FocusState<Value: Hashable>: DynamicProperty {
    /// SDK 里它也是属性包装（`@FocusState.Binding`）；这里只用它当 `focused(_:)` 的参数，不加 `@propertyWrapper`。
    public struct Binding {
        public var wrappedValue: Value {
            get { fatalError() }
            nonmutating set {}
        }
        public var projectedValue: FocusState<Value>.Binding { self }
    }

    public init() where Value == Bool {}
    public init<T: Hashable>() where Value == T? {}

    public var wrappedValue: Value {
        get { fatalError() }
        nonmutating set {}
    }
    public var projectedValue: FocusState<Value>.Binding { Binding() }
}

extension View {
    public func focused(_ condition: FocusState<Bool>.Binding) -> some View { _m() }
    public func focused<Value: Hashable>(_ binding: FocusState<Value>.Binding, equals value: Value) -> some View {
        _m()
    }
}

// MARK: - @Bindable（iOS 17）

@dynamicMemberLookup @propertyWrapper
public struct Bindable<Value> {
    public var wrappedValue: Value
    public var projectedValue: Bindable<Value> { self }

    public init(wrappedValue: Value) where Value: AnyObject, Value: Observable { self.wrappedValue = wrappedValue }
    public init(_ wrappedValue: Value) where Value: AnyObject, Value: Observable { self.wrappedValue = wrappedValue }
    public init(projectedValue: Bindable<Value>) { self = projectedValue }

    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject>
    where Value: AnyObject { fatalError() }
}

// MARK: - 文字与输入框

extension Text {
    public init(_ attributedContent: AttributedString) {}
    public func monospacedDigit() -> Text { self }
}

extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {}
}

public struct SubmitLabel: Sendable {
    let v: Int
    public static let done = SubmitLabel(v: 0)
    public static let go = SubmitLabel(v: 1)
    public static let send = SubmitLabel(v: 2)
    public static let join = SubmitLabel(v: 3)
    public static let route = SubmitLabel(v: 4)
    public static let search = SubmitLabel(v: 5)
    public static let `return` = SubmitLabel(v: 6)
    public static let next = SubmitLabel(v: 7)
    public static let `continue` = SubmitLabel(v: 8)
}

public struct SubmitTriggers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1)
    public static let search = SubmitTriggers(rawValue: 2)
}

public struct ScrollDismissesKeyboardMode: Sendable {
    let v: Int
    public static let automatic = ScrollDismissesKeyboardMode(v: 0)
    public static let immediately = ScrollDismissesKeyboardMode(v: 1)
    public static let interactively = ScrollDismissesKeyboardMode(v: 2)
    public static let never = ScrollDismissesKeyboardMode(v: 3)
}

extension View {
    public func submitLabel(_ submitLabel: SubmitLabel) -> some View { _m() }
    public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping () -> Void) -> some View { _m() }
    public func monospacedDigit() -> some View { _m() }
    public func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode) -> some View { _m() }

    #if canImport(UIKit)
        public func textContentType(_ textContentType: UITextContentType?) -> some View { _m() }
        public func keyboardType(_ type: UIKeyboardType) -> some View { _m() }
    #elseif canImport(AppKit)
        public func textContentType(_ textContentType: NSTextContentType?) -> some View { _m() }
    #endif
}

// MARK: - 按钮、开关、导航链接

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void
    ) {}
}

public struct Toggle<Label: View> {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
}

extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {}
}

public struct NavigationLink<Label: View, Destination: View> {
    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {}
    public init<P: Hashable>(value: P?, @ViewBuilder label: () -> Label) where Destination == Never {}
}

extension Toggle: View { public var body: Never { fatalError() } }
extension NavigationLink: View { public var body: Never { fatalError() } }

// MARK: - 弹窗、确认框、导航、搜索、刷新

public enum Visibility: Hashable, CaseIterable, Sendable {
    case automatic, visible, hidden
}

public struct SearchFieldPlacement: Sendable {
    let v: Int
    public static let automatic = SearchFieldPlacement(v: 0)
}

@MainActor
public struct DismissAction {
    public func callAsFunction() {}
}

extension EnvironmentValues {
    public var dismiss: DismissAction { DismissAction() }
}

extension View {
    public func alert<A: View, M: View>(
        _ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A,
        @ViewBuilder message: () -> M
    ) -> some View { _m() }
    @_disfavoredOverload public func alert<S: StringProtocol, A: View, M: View>(
        _ title: S, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M
    ) -> some View { _m() }

    public func confirmationDialog<A: View, M: View>(
        _ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M
    ) -> some View { _m() }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, M: View>(
        _ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A,
        @ViewBuilder message: () -> M
    ) -> some View { _m() }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, M: View, T>(
        _ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?,
        @ViewBuilder actions: (T) -> A, @ViewBuilder message: (T) -> M
    ) -> some View { _m() }

    public func navigationDestination<V: View>(isPresented: Binding<Bool>, @ViewBuilder destination: () -> V)
        -> some View
    { _m() }

    public func searchable(
        text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: Text? = nil
    ) -> some View { _m() }

    public func refreshable(action: @escaping @Sendable () async -> Void) -> some View { _m() }
}
