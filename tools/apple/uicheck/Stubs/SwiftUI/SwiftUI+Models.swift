// 模型 key、模型路由、用量（WBS 12.4）的界面用到、别的桩文件里还没有的 SwiftUI API。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// 单独放一个文件，免得和别的功能同时往 SwiftUI.swift 里加东西时合并冲突。合并时如果别的功能也加了同名的
// （SecureField、Picker、tag 这些通用的），留一份就行。

// MARK: - 密码输入框（iOS 13）

public struct SecureField<Label: View> {}

extension SecureField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {}
}

extension SecureField: View { public var body: Never { fatalError() } }

// MARK: - 选择器（iOS 13）与分段样式

public struct Picker<Label: View, SelectionValue: Hashable, Content: View> {
    public init(
        selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label
    ) {}
}

extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content
    ) {}
}

extension Picker: View { public var body: Never { fatalError() } }

public protocol PickerStyle {}

public struct SegmentedPickerStyle: PickerStyle {
    public init() {}
}

public struct MenuPickerStyle: PickerStyle {
    public init() {}
}

extension PickerStyle where Self == SegmentedPickerStyle {
    public static var segmented: SegmentedPickerStyle { SegmentedPickerStyle() }
}

extension PickerStyle where Self == MenuPickerStyle {
    public static var menu: MenuPickerStyle { MenuPickerStyle() }
}

// MARK: - 输入框的键盘行为（iOS 15 的 TextInputAutocapitalization、iOS 13 的 autocorrectionDisabled）

#if canImport(UIKit)
    public struct TextInputAutocapitalization: Sendable {
        let v: Int
        public static let never = TextInputAutocapitalization(v: 0)
        public static let words = TextInputAutocapitalization(v: 1)
        public static let sentences = TextInputAutocapitalization(v: 2)
        public static let characters = TextInputAutocapitalization(v: 3)
    }

    extension View {
        public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
            _m()
        }
    }
#endif

extension View {
    public func autocorrectionDisabled(_ disable: Bool = true) -> some View { _m() }

    /// 选择器、`ForEach` 里每一项的值（iOS 13）。
    public func tag<V: Hashable>(_ tag: V) -> some View { _m() }

    public func pickerStyle<S: PickerStyle>(_ style: S) -> some View { _m() }

    /// 有没保存的改动时藏起返回按钮，换成自己的“放弃修改”（iOS 13、macOS 13）。
    public func navigationBarBackButtonHidden(_ hidesBackButton: Bool = true) -> some View { _m() }
}
