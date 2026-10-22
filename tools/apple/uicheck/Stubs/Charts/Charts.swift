// Swift Charts（iOS 16 / macOS 13）的桩：只用来在 Linux 上做类型检查，签名照 Apple 文档（iOS 17 / macOS 14 SDK），
// 实现全是空的。现在只有 12.4 的用量看板（按天的柱状图）用到的部分；别的功能用到新的 API 时照文档往这里补。
import SwiftUI

// MARK: - 能画的值

public protocol Plottable {}

extension String: Plottable {}
extension Int: Plottable {}
extension Double: Plottable {}
extension Float: Plottable {}
extension CGFloat: Plottable {}
extension Date: Plottable {}

/// 一个带名字的值（`.value("日期", date, unit: .day)`）。
public struct PlottableValue<Value: Plottable> {
    public static func value(_ label: Text, _ value: Value) -> PlottableValue<Value> { PlottableValue() }
    public static func value(_ label: LocalizedStringKey, _ value: Value) -> PlottableValue<Value> {
        PlottableValue()
    }
    @_disfavoredOverload public static func value<S: StringProtocol>(_ label: S, _ value: Value)
        -> PlottableValue<Value>
    { PlottableValue() }
}

extension PlottableValue where Value == Date {
    public static func value(_ label: Text, _ value: Date, unit: Calendar.Component) -> PlottableValue<Date> {
        PlottableValue()
    }
    public static func value(_ label: LocalizedStringKey, _ value: Date, unit: Calendar.Component)
        -> PlottableValue<Date>
    { PlottableValue() }
    @_disfavoredOverload public static func value<S: StringProtocol>(
        _ label: S, _ value: Date, unit: Calendar.Component
    ) -> PlottableValue<Date> { PlottableValue() }
}

// MARK: - 图里的内容

// 桩里不标 @MainActor：图的内容闭包按不隔离处理（比真 SDK 严），闭包里只用捕获的值、不碰主线程的状态，两边都能编。
public protocol ChartContent {
    associatedtype Body: ChartContent
    @ChartContentBuilder var body: Body { get }
}

/// 桩里的“叶子”内容（代替真 SDK 里各种 mark 的 body）。
public struct _ChartLeaf: ChartContent {
    public init() {}
    public var body: _ChartLeaf { self }
}

public struct TupleChartContent<T>: ChartContent {
    public init(_ value: T) {}
    public var body: _ChartLeaf { _ChartLeaf() }
}

public struct _ConditionalChartContent<TrueContent: ChartContent, FalseContent: ChartContent>: ChartContent {
    public var body: _ChartLeaf { _ChartLeaf() }
}

public struct _OptionalChartContent<Wrapped: ChartContent>: ChartContent {
    public var body: _ChartLeaf { _ChartLeaf() }
}

public struct _EmptyChartContent: ChartContent {
    public var body: _ChartLeaf { _ChartLeaf() }
}

@resultBuilder
public struct ChartContentBuilder {
    public static func buildExpression<C: ChartContent>(_ content: C) -> C { content }
    public static func buildBlock() -> _EmptyChartContent { _EmptyChartContent() }
    public static func buildBlock<C: ChartContent>(_ content: C) -> C { content }
    public static func buildBlock<each C: ChartContent>(_ content: repeat each C) -> TupleChartContent<(repeat each C)> {
        TupleChartContent((repeat each content))
    }
    public static func buildIf<C: ChartContent>(_ content: C?) -> _OptionalChartContent<C> { _OptionalChartContent() }
    public static func buildEither<T: ChartContent, F: ChartContent>(first: T) -> _ConditionalChartContent<T, F> {
        _ConditionalChartContent()
    }
    public static func buildEither<T: ChartContent, F: ChartContent>(second: F) -> _ConditionalChartContent<T, F> {
        _ConditionalChartContent()
    }
}

/// 柱子。
public struct BarMark: ChartContent {
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>) {}
    public var body: _ChartLeaf { _ChartLeaf() }
}

/// 横线、竖线（平均值、上限）。
public struct RuleMark: ChartContent {
    public init<Y: Plottable>(y: PlottableValue<Y>) {}
    public init<X: Plottable>(x: PlottableValue<X>) {}
    public var body: _ChartLeaf { _ChartLeaf() }
}

public struct _ModifiedChartContent<Content: ChartContent>: ChartContent {
    public var body: _ChartLeaf { _ChartLeaf() }
}

extension ChartContent {
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some ChartContent { _ModifiedChartContent<Self>() }
    public func opacity(_ value: Double) -> some ChartContent { _ModifiedChartContent<Self>() }
    public func cornerRadius(_ radius: CGFloat, style: RoundedCornerStyle = .continuous) -> some ChartContent {
        _ModifiedChartContent<Self>()
    }
    public func accessibilityLabel(_ label: Text) -> some ChartContent { _ModifiedChartContent<Self>() }
    public func accessibilityValue(_ value: Text) -> some ChartContent { _ModifiedChartContent<Self>() }
    public func accessibilityHidden(_ hidden: Bool) -> some ChartContent { _ModifiedChartContent<Self>() }
}

// MARK: - 图

public struct Chart<Content: View> {
    public init<C: ChartContent>(@ChartContentBuilder content: () -> C) where Content == EmptyView {}
    public init<Data: RandomAccessCollection, C: ChartContent>(
        _ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> C
    ) where Data.Element: Identifiable, Content == EmptyView {}
    public init<Data: RandomAccessCollection, ID: Hashable, C: ChartContent>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ChartContentBuilder content: @escaping (Data.Element) -> C
    ) where Content == EmptyView {}
}

extension Chart: View {
    public var body: Never { fatalError() }
}

// MARK: - 坐标轴

public protocol AxisContent {}

public struct _TupleAxisContent<T>: AxisContent {
    public init(_ value: T) {}
}

@resultBuilder
public struct AxisContentBuilder {
    public static func buildExpression<C: AxisContent>(_ content: C) -> C { content }
    public static func buildBlock<C: AxisContent>(_ content: C) -> C { content }
    public static func buildBlock<each C: AxisContent>(_ content: repeat each C) -> _TupleAxisContent<(repeat each C)> {
        _TupleAxisContent((repeat each content))
    }
}

public protocol AxisMark {}

public struct _TupleAxisMark<T>: AxisMark {
    public init(_ value: T) {}
}

public struct _ConditionalAxisMark<TrueContent: AxisMark, FalseContent: AxisMark>: AxisMark {}
public struct _OptionalAxisMark<Wrapped: AxisMark>: AxisMark {}
public struct _EmptyAxisMark: AxisMark {}
public struct _ModifiedAxisMark<Content: AxisMark>: AxisMark {}

@resultBuilder
public struct AxisMarkBuilder {
    public static func buildExpression<C: AxisMark>(_ content: C) -> C { content }
    public static func buildBlock() -> _EmptyAxisMark { _EmptyAxisMark() }
    public static func buildBlock<C: AxisMark>(_ content: C) -> C { content }
    public static func buildBlock<each C: AxisMark>(_ content: repeat each C) -> _TupleAxisMark<(repeat each C)> {
        _TupleAxisMark((repeat each content))
    }
    public static func buildIf<C: AxisMark>(_ content: C?) -> _OptionalAxisMark<C> { _OptionalAxisMark() }
    public static func buildEither<T: AxisMark, F: AxisMark>(first: T) -> _ConditionalAxisMark<T, F> {
        _ConditionalAxisMark()
    }
    public static func buildEither<T: AxisMark, F: AxisMark>(second: F) -> _ConditionalAxisMark<T, F> {
        _ConditionalAxisMark()
    }
}

extension AxisMark {
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some AxisMark { _ModifiedAxisMark<Self>() }
}

/// 坐标轴上的一个刻度值。
public struct AxisValue {
    public var index: Int { 0 }
    public var count: Int { 0 }
    public func `as`<P: Plottable>(_ type: P.Type) -> P? { nil }
}

public struct AxisMarkValues {
    public static var automatic: AxisMarkValues { AxisMarkValues() }
    public static func automatic(desiredCount: Int? = nil, roundLowerBound: Bool? = nil, roundUpperBound: Bool? = nil)
        -> AxisMarkValues
    { AxisMarkValues() }
    public static func stride(
        by component: Calendar.Component, count: Int = 1, roundLowerBound: Bool? = nil, roundUpperBound: Bool? = nil,
        calendar: Calendar? = nil
    ) -> AxisMarkValues { AxisMarkValues() }
}

public struct AxisMarkPosition: Equatable, Sendable {
    let v: Int
    public static let automatic = AxisMarkPosition(v: 0)
    public static let leading = AxisMarkPosition(v: 1)
    public static let trailing = AxisMarkPosition(v: 2)
    public static let top = AxisMarkPosition(v: 3)
    public static let bottom = AxisMarkPosition(v: 4)
}

public struct AxisMarkPreset: Equatable, Sendable {
    let v: Int
    public static let automatic = AxisMarkPreset(v: 0)
    public static let extended = AxisMarkPreset(v: 1)
    public static let aligned = AxisMarkPreset(v: 2)
    public static let inset = AxisMarkPreset(v: 3)
}

public struct AxisMarks<Content>: AxisContent {
    public init(
        preset: AxisMarkPreset = .automatic, position: AxisMarkPosition = .automatic,
        values: AxisMarkValues = .automatic
    ) where Content == Never {}
}

extension AxisMarks where Content: AxisMark {
    public init(
        preset: AxisMarkPreset = .automatic, position: AxisMarkPosition = .automatic,
        values: AxisMarkValues = .automatic, @AxisMarkBuilder content: @escaping (AxisValue) -> Content
    ) {}
}

public struct AxisGridLine: AxisMark {
    public init(centered: Bool? = nil) {}
}

public struct AxisTick: AxisMark {
    public init(centered: Bool? = nil, length: CGFloat? = nil) {}
}

public struct AxisValueLabel: AxisMark {
    public init(centered: Bool? = nil, anchor: UnitPoint? = nil) {}
    public init<C: View>(centered: Bool? = nil, anchor: UnitPoint? = nil, @ViewBuilder content: () -> C) {}
}

extension View {
    public func chartXAxis<C: AxisContent>(@AxisContentBuilder content: () -> C) -> some View { _chartStub() }
    public func chartYAxis<C: AxisContent>(@AxisContentBuilder content: () -> C) -> some View { _chartStub() }
    public func chartXAxis(_ visibility: Visibility) -> some View { _chartStub() }
    public func chartYAxis(_ visibility: Visibility) -> some View { _chartStub() }
    public func chartLegend(_ visibility: Visibility) -> some View { _chartStub() }

    /// 桩里没法用 SwiftUI 桩模块里的内部方法（`_m()`），这里自己包一层。
    fileprivate func _chartStub() -> some View { self }
}
