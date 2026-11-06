// 设置、多语言与开源许可（WBS 12.12）的界面用到、别的桩文件里还没有的 SwiftUI API。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// 单独放一个文件，免得和别的功能同时往 SwiftUI.swift 里加东西时合并冲突。合并时如果别的功能也加了同名的
// （textSelection 这种通用的），留一份就行。

// MARK: - 文字可以选中、复制（iOS 15、macOS 12）

public protocol TextSelectability {
    static var allowsSelection: Bool { get }
}

public struct EnabledTextSelectability: TextSelectability {
    public static var allowsSelection: Bool { true }
}

public struct DisabledTextSelectability: TextSelectability {
    public static var allowsSelection: Bool { false }
}

extension TextSelectability where Self == EnabledTextSelectability {
    public static var enabled: EnabledTextSelectability { EnabledTextSelectability() }
}

extension TextSelectability where Self == DisabledTextSelectability {
    public static var disabled: DisabledTextSelectability { DisabledTextSelectability() }
}

extension View {
    public func textSelection<S: TextSelectability>(_ selectability: S) -> some View { _m() }
}

// MARK: - 第 1 轮 E 线（设置一带改版）用到的

/// 把几个视图当一个（iOS 13、macOS 10.15）：修饰符分给里面每一个（保险箱表单里密码的明文 / 密文两个输入框共用一套修饰符）。
public struct Group<Content> {}

extension Group: View where Content: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

extension View {
    /// 字体的设计（iOS 16.1、macOS 13）：保险箱的引用、条目名用等宽。
    public func fontDesign(_ design: Font.Design?) -> some View { _m() }
    /// 字重（iOS 16、macOS 13）。
    public func fontWeight(_ weight: Font.Weight?) -> some View { _m() }
}

// MARK: - 设置一带的截图审查（2026-11-06）用到的

/// 对齐参考线时拿到的视图尺寸（iOS 13、macOS 10.15）。
public struct ViewDimensions {
    public var width: CGFloat { 0 }
    public var height: CGFloat { 0 }
    public subscript(guide: HorizontalAlignment) -> CGFloat { 0 }
    public subscript(guide: VerticalAlignment) -> CGFloat { 0 }
    public subscript(explicit guide: HorizontalAlignment) -> CGFloat? { nil }
    public subscript(explicit guide: VerticalAlignment) -> CGFloat? { nil }
}

extension HorizontalAlignment {
    /// 列表行分隔线的起点（iOS 16、macOS 13）：账号行、状态点那一行的分隔线从行首画起。
    public static let listRowSeparatorLeading = HorizontalAlignment()
    /// 列表行分隔线的终点（iOS 16、macOS 13）。
    public static let listRowSeparatorTrailing = HorizontalAlignment()
}

extension View {
    /// 改一条对齐参考线的位置（iOS 13、macOS 10.15）。
    public func alignmentGuide(
        _ g: HorizontalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat
    ) -> some View { _m() }
    public func alignmentGuide(
        _ g: VerticalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat
    ) -> some View { _m() }
}

// MARK: - 有进度值的进度条（iOS 14、macOS 11）：用量页“今天”的细进度条

extension ProgressView {
    /// SDK 里是 `Label == EmptyView, CurrentValueLabel == EmptyView` 的那个初始化方法；桩的 `ProgressView` 不带泛型参数。
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) { self.init() }
}

public protocol ProgressViewStyle {}

public struct LinearProgressViewStyle: ProgressViewStyle {
    public init() {}
}

public struct CircularProgressViewStyle: ProgressViewStyle {
    public init() {}
}

extension ProgressViewStyle where Self == LinearProgressViewStyle {
    public static var linear: LinearProgressViewStyle { LinearProgressViewStyle() }
}

extension ProgressViewStyle where Self == CircularProgressViewStyle {
    public static var circular: CircularProgressViewStyle { CircularProgressViewStyle() }
}

extension View {
    public func progressViewStyle<S: ProgressViewStyle>(_ style: S) -> some View { _m() }
}
