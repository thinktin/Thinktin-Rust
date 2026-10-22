// 对话与运行过程（WBS 12.5）的界面用到、别的桩文件里还没有的 SwiftUI API。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// 单独放一个文件，免得和别的功能同时往 SwiftUI.swift 里加东西时合并冲突。合并时如果别的功能也加了同名的
// （SecureField、ViewModifier 这些通用的），留一份就行。

// MARK: - 自定义修饰符（iOS 13）

@MainActor @preconcurrency
public protocol ViewModifier {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency func body(content: Content) -> Body
    typealias Content = _ViewModifier_Content<Self>
}

public struct _ViewModifier_Content<Modifier: ViewModifier> {}

extension _ViewModifier_Content: View { public var body: Never { fatalError() } }

extension View {
    public func modifier<T>(_ modifier: T) -> ModifiedContent<Self, T> { ModifiedContent() }
}

// MARK: - 只在输入变了时重画（iOS 13）

public struct EquatableView<Content: View & Equatable> {
    public var content: Content
    public init(content: Content) { self.content = content }
}

extension EquatableView: View { public var body: Never { fatalError() } }

extension View where Self: Equatable {
    public func equatable() -> EquatableView<Self> { EquatableView(content: self) }
}

// MARK: - 长按菜单（iOS 13）、分享（iOS 16）、读屏的自定义操作（iOS 15）

extension View {
    public func contextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View { _m() }

    public func accessibilityAction(named name: Text, _ handler: @escaping () -> Void) -> some View { _m() }
}

/// SDK 里是 `ShareLink<Data, PreviewImage, PreviewIcon, Label>`；这里只认分享一段文字的写法。
public struct ShareLink<Label: View> {
    public init(item: String, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {}
}

extension ShareLink: View { public var body: Never { fatalError() } }

// MARK: - 滚动：滚到某一项（iOS 14）、默认停在底部（iOS 17）

public struct ScrollViewProxy {
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {}
}

public struct ScrollViewReader<Content: View> {
    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {}
}

extension ScrollViewReader: View { public var body: Never { fatalError() } }

extension UnitPoint {
    public static let top = UnitPoint()
    public static let bottom = UnitPoint()
    public static let leading = UnitPoint()
    public static let trailing = UnitPoint()
}

extension View {
    public func defaultScrollAnchor(_ anchor: UnitPoint?) -> some View { _m() }
}

// MARK: - 网格（iOS 16，Markdown 的表格）

public struct Grid<Content: View> {
    public init(
        alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {}
}

public struct GridRow<Content: View> {
    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {}
}

extension Grid: View { public var body: Never { fatalError() } }
extension GridRow: View { public var body: Never { fatalError() } }

// MARK: - 输入框（iOS 16 的多行、iOS 13 的密码框）

extension TextField where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis) {}
}

public struct SecureField<Label: View> {}

extension SecureField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {}
}

extension SecureField: View { public var body: Never { fatalError() } }

// MARK: - Markdown（Foundation 的 API，iOS 15）

// Linux 的 Foundation 没有 `AttributedString(markdown:)`：照 Apple Foundation 的签名补在这里（界面层 import SwiftUI 就能用），
// 只为类型检查，不解析。
extension AttributedString {
    public struct MarkdownParsingOptions: Hashable, Sendable {
        public enum InterpretedSyntax: Hashable, Sendable {
            case full, inlineOnly, inlineOnlyPreservingWhitespace
        }

        public enum FailurePolicy: Hashable, Sendable {
            case throwError, returnPartiallyParsedIfPossible
        }

        public var allowsExtendedAttributes: Bool
        public var interpretedSyntax: InterpretedSyntax
        public var failurePolicy: FailurePolicy
        public var languageCode: String?

        public init(
            allowsExtendedAttributes: Bool = false, interpretedSyntax: InterpretedSyntax = .full,
            failurePolicy: FailurePolicy = .throwError, languageCode: String? = nil
        ) {
            self.allowsExtendedAttributes = allowsExtendedAttributes
            self.interpretedSyntax = interpretedSyntax
            self.failurePolicy = failurePolicy
            self.languageCode = languageCode
        }
    }

    public init(markdown: String, options: MarkdownParsingOptions = .init(), baseURL: URL? = nil) throws {
        self.init(markdown)
    }
}
