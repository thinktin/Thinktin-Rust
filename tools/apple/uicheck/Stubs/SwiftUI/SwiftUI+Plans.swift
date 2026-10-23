// 计划管理（WBS 12.6）的界面用到、别的桩文件里还没有的 SwiftUI API。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// 单独放一个文件，免得和别的功能同时往 SwiftUI.swift 里加东西时合并冲突。

// MARK: - 日期选择（iOS 13）

public struct DatePickerComponents: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let hourAndMinute = DatePickerComponents(rawValue: 1 << 0)
    public static let date = DatePickerComponents(rawValue: 1 << 1)
}

public struct DatePicker<Label: View> {
    public init(
        selection: Binding<Date>, displayedComponents: DatePickerComponents = [.hourAndMinute, .date],
        @ViewBuilder label: () -> Label
    ) {}
    public init(
        selection: Binding<Date>, in range: PartialRangeFrom<Date>,
        displayedComponents: DatePickerComponents = [.hourAndMinute, .date], @ViewBuilder label: () -> Label
    ) {}
}

extension DatePicker where Label == Text {
    public init(
        _ titleKey: LocalizedStringKey, selection: Binding<Date>,
        displayedComponents: DatePickerComponents = [.hourAndMinute, .date]
    ) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, selection: Binding<Date>, displayedComponents: DatePickerComponents = [.hourAndMinute, .date]
    ) {}
    public init(
        _ titleKey: LocalizedStringKey, selection: Binding<Date>, in range: PartialRangeFrom<Date>,
        displayedComponents: DatePickerComponents = [.hourAndMinute, .date]
    ) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, selection: Binding<Date>, in range: PartialRangeFrom<Date>,
        displayedComponents: DatePickerComponents = [.hourAndMinute, .date]
    ) {}
}

extension DatePicker: View { public var body: Never { fatalError() } }

// MARK: - 隐藏控件自带的标签（iOS 13）

extension View {
    public func labelsHidden() -> some View { _m() }
}
