// 第 1 轮收尾线（参考里没有的页面换原生控件）用到、别的桩文件里还没有的 SwiftUI API。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// 加之前先 grep 整个 Stubs/，免得和别的线重复声明。

// MARK: - 可展开的一组（iOS 14、macOS 11）

public struct DisclosureGroup<Label: View, Content: View> {
    public init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {}
    public init(
        isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label
    ) {}
}

extension DisclosureGroup where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {}
    public init(
        _ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ label: S, @ViewBuilder content: @escaping () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ label: S, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) {}
}

extension DisclosureGroup: View { public var body: Never { fatalError() } }
