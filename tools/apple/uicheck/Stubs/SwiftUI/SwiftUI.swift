// 只用来在 Linux 上做类型检查的 SwiftUI 桩：签名照 iOS 17 SDK 的写，实现全是空的。
@_exported import CoreGraphics
@_exported import Foundation
import Observation

#if canImport(UIKit)
    @_exported import UIKit
#elseif canImport(AppKit)
    @_exported import AppKit
#endif

// MARK: - View 与 ViewBuilder

@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency var body: Body { get }
}

extension Never: View {
    public var body: Never { fatalError() }
}

extension Optional: View where Wrapped: View {
    public var body: Never { fatalError() }
}

public struct TupleView<T> {
    public init(_ value: T) {}
}

public struct _ConditionalContent<TrueContent: View, FalseContent: View> {
}

public struct AnyView {
    public init<V: View>(_ view: V) {}
}

@resultBuilder
public struct ViewBuilder {
    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> {
        TupleView((repeat each content))
    }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

public struct ModifiedContent<Content, Modifier> {
}

public struct EmptyModifier {}

extension View {
    nonisolated func _m() -> ModifiedContent<Self, EmptyModifier> { ModifiedContent() }
}

// MARK: - 基本类型

public struct Alignment: Equatable, Sendable {
    public static let center = Alignment()
    public static let leading = Alignment()
    public static let trailing = Alignment()
    public static let top = Alignment()
    public static let bottom = Alignment()
    public static let topLeading = Alignment()
    public static let topTrailing = Alignment()
    public static let bottomLeading = Alignment()
    public static let bottomTrailing = Alignment()
}

public struct HorizontalAlignment: Equatable, Sendable {
    public static let center = HorizontalAlignment()
    public static let leading = HorizontalAlignment()
    public static let trailing = HorizontalAlignment()
}

public struct VerticalAlignment: Equatable, Sendable {
    public static let center = VerticalAlignment()
    public static let top = VerticalAlignment()
    public static let bottom = VerticalAlignment()
    public static let firstTextBaseline = VerticalAlignment()
    public static let lastTextBaseline = VerticalAlignment()
}

public enum Edge: Int8, CaseIterable, Sendable {
    case top, leading, bottom, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1)
        public static let leading = Set(rawValue: 2)
        public static let bottom = Set(rawValue: 4)
        public static let trailing = Set(rawValue: 8)
        public static let all = Set(rawValue: 15)
        public static let horizontal = Set(rawValue: 10)
        public static let vertical = Set(rawValue: 5)
    }
}

public enum VerticalEdge: Int8, Sendable { case top, bottom }

public enum Axis: Int8, Sendable {
    case horizontal, vertical
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1)
        public static let vertical = Set(rawValue: 2)
    }
}

public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let all = SafeAreaRegions(rawValue: 3)
    public static let container = SafeAreaRegions(rawValue: 1)
    public static let keyboard = SafeAreaRegions(rawValue: 2)
}

public enum TextAlignment: Hashable, Sendable { case leading, center, trailing }

public enum ColorScheme: Hashable, Sendable, CaseIterable { case light, dark }

public struct UnitPoint: Hashable, Sendable {
    public static let center = UnitPoint()
}

public struct ProposedViewSize: Equatable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?
    public init(width: CGFloat?, height: CGFloat?) {
        self.width = width
        self.height = height
    }
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
}

// MARK: - 颜色与样式

public protocol ShapeStyle: Sendable {}

public struct Color: ShapeStyle, Hashable, Sendable {
    public enum RGBColorSpace: Sendable { case sRGB, sRGBLinear, displayP3 }
    let id = UUID()
    public init(_ colorSpace: RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    #if canImport(UIKit)
        public init(uiColor: UIColor) {}
    #elseif canImport(AppKit)
        public init(nsColor: NSColor) {}
    #endif
    public static let white = Color(red: 1, green: 1, blue: 1)
    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    public func opacity(_ opacity: Double) -> Color { self }
}

public struct FillStyle: Equatable, Sendable {
    public init(eoFill: Bool = false, antialiased: Bool = true) {}
}

public struct Font: Hashable, Sendable {
    public enum TextStyle: CaseIterable, Hashable, Sendable {
        case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2
    }
    public enum Design: Hashable, Sendable { case `default`, serif, rounded, monospaced }
    public struct Weight: Hashable, Sendable {
        let v: Int
        public static let regular = Weight(v: 400)
        public static let medium = Weight(v: 500)
        public static let semibold = Weight(v: 600)
        public static let bold = Weight(v: 700)
    }
    let tag: Int
    public static func system(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font { Font(tag: 0) }
    public static func system(size: CGFloat, weight: Weight? = nil, design: Design? = nil) -> Font { Font(tag: 0) }
    public func weight(_ weight: Weight) -> Font { self }
    public func monospacedDigit() -> Font { self }
    public static let body = Font(tag: 1)
    public static let footnote = Font(tag: 2)
    public static let largeTitle = Font(tag: 3)
}

// MARK: - 环境与状态

public protocol DynamicProperty {}

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues {
    public init() {}
    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { K.defaultValue }
        set {}
    }
    public var displayScale: CGFloat {
        get { 3 }
        set {}
    }
    public var accessibilityReduceMotion: Bool { false }
    public var isEnabled: Bool {
        get { true }
        set {}
    }
    public var colorScheme: ColorScheme {
        get { .light }
        set {}
    }
    public var scenePhase: ScenePhase {
        get { .active }
        set {}
    }
}

public enum ScenePhase: Comparable, Hashable, Sendable {
    case background, inactive, active
}

@propertyWrapper
public struct Environment<Value>: DynamicProperty {
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    public var wrappedValue: Value { fatalError() }
}

extension Environment where Value: AnyObject & Observable {
    /// iOS 17：从环境里取 `@Observable` 的对象（没注入时崩溃）。
    public init(_ objectType: Value.Type) {}
}

@propertyWrapper
public struct State<Value>: DynamicProperty {
    var value: Value
    public init(wrappedValue value: Value) { self.value = value }
    public init(initialValue value: Value) { self.value = value }
    public var wrappedValue: Value {
        get { value }
        nonmutating set {}
    }
    public var projectedValue: Binding<Value> { fatalError() }
}

extension State where Value: ExpressibleByNilLiteral {
    public init() { self.value = nil }
}

@propertyWrapper @dynamicMemberLookup
public struct Binding<Value> {
    let get: () -> Value
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) { self.get = get }
    public init(projectedValue: Binding<Value>) { self = projectedValue }
    public static func constant(_ value: Value) -> Binding<Value> { Binding(get: { value }, set: { _ in }) }
    public var wrappedValue: Value {
        get { get() }
        nonmutating set {}
    }
    public var projectedValue: Binding<Value> { self }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> { fatalError() }
}

// MARK: - 动画与过渡

public struct Animation: Equatable, Sendable {
    let tag: Int
    public static let `default` = Animation(tag: 0)
    public static let snappy = Animation(tag: 1)
    public static func easeOut(duration: Double) -> Animation { Animation(tag: 2) }
    public static func easeInOut(duration: Double) -> Animation { Animation(tag: 3) }
    public func repeatForever(autoreverses: Bool = true) -> Animation { self }
}

public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try body()
}

public struct AnyTransition: Sendable {
    public static let opacity = AnyTransition()
    public static func move(edge: Edge) -> AnyTransition { AnyTransition() }
    public func combined(with other: AnyTransition) -> AnyTransition { self }
}

// MARK: - 无障碍

public struct AccessibilityTraits: SetAlgebra, Sendable {
    var raw: Set<Int>
    public init() { raw = [] }
    init(_ v: Int) { raw = [v] }
    public static let isHeader = AccessibilityTraits(1)
    public static let isModal = AccessibilityTraits(2)
    public static let isButton = AccessibilityTraits(3)
    public static let isSelected = AccessibilityTraits(4)
    public func union(_ other: Self) -> Self { Self() }
    public func intersection(_ other: Self) -> Self { Self() }
    public func symmetricDifference(_ other: Self) -> Self { Self() }
    public func contains(_ member: Self) -> Bool { false }
    public mutating func insert(_ newMember: Self) -> (inserted: Bool, memberAfterInsert: Self) { (true, newMember) }
    public mutating func remove(_ member: Self) -> Self? { nil }
    public mutating func update(with newMember: Self) -> Self? { nil }
    public mutating func formUnion(_ other: Self) {}
    public mutating func formIntersection(_ other: Self) {}
    public mutating func formSymmetricDifference(_ other: Self) {}
}

public struct AccessibilityChildBehavior: Hashable, Sendable {
    let v: Int
    public static let ignore = AccessibilityChildBehavior(v: 0)
    public static let contain = AccessibilityChildBehavior(v: 1)
    public static let combine = AccessibilityChildBehavior(v: 2)
}

public struct AccessibilityActionKind: Equatable, Sendable {
    let v: Int
    public static let `default` = AccessibilityActionKind(v: 0)
    public static let escape = AccessibilityActionKind(v: 1)
    public static let magicTap = AccessibilityActionKind(v: 2)
}

// MARK: - 文字与图片

public struct LocalizedStringKey: ExpressibleByStringInterpolation, Equatable, Sendable {
    public init(_ value: String) {}
    public init(stringLiteral value: String) {}
}

public struct Text: Equatable, Sendable {
    public init(_ key: LocalizedStringKey, tableName: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) {}
    public init(verbatim content: String) {}
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Text { self }
    public func font(_ font: Font?) -> Text { self }
}

public struct Image: Equatable, Sendable {
    public enum Scale: Hashable, Sendable { case small, medium, large }
    public init(systemName: String) {}
}

public struct Label<Title: View, Icon: View> {
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {}
}

extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, systemImage name: String) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String) {}
}

// MARK: - 布局容器

public struct HStack<Content: View> {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}

public struct VStack<Content: View> {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}

public struct ZStack<Content: View> {
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {}
}

public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public struct LazyVStack<Content: View> {
    public init(
        alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = .init(),
        @ViewBuilder content: () -> Content
    ) {}
}

public struct ScrollView<Content: View> {
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {}
}

public struct Spacer {
    public init(minLength: CGFloat? = nil) {}
}

public struct EmptyView {
    public init() {}
}

public struct ProgressView {
    public init() {}
}

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View> {
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
}

public struct NavigationStack<Root: View> {
    public init(@ViewBuilder root: () -> Root) {}
    public init<Data>(path: Binding<Data>, @ViewBuilder root: () -> Root)
    where Data: MutableCollection, Data: RandomAccessCollection, Data: RangeReplaceableCollection, Data.Element: Hashable {}
}

// MARK: - 时间线

public protocol TimelineSchedule {}
public struct EveryMinuteTimelineSchedule: TimelineSchedule {}
extension TimelineSchedule where Self == EveryMinuteTimelineSchedule {
    public static var everyMinute: EveryMinuteTimelineSchedule { EveryMinuteTimelineSchedule() }
}

public struct PeriodicTimelineSchedule: TimelineSchedule {
    public init(from startDate: Date, by interval: TimeInterval) {}
}
extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    public static func periodic(from startDate: Date, by interval: TimeInterval) -> PeriodicTimelineSchedule {
        PeriodicTimelineSchedule(from: startDate, by: interval)
    }
}

public struct TimelineViewDefaultContext {
    public let date: Date
}

public struct TimelineView<Schedule: TimelineSchedule, Content: View> {
    public typealias Context = TimelineViewDefaultContext
    public init(_ schedule: Schedule, @ViewBuilder content: @escaping (Context) -> Content) {}
}

// MARK: - 控件

public struct ButtonRole: Equatable, Sendable {
    public static let destructive = ButtonRole()
    public static let cancel = ButtonRole()
}

public struct Button<Label: View> {
    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
    public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {}
}

public struct ButtonStyleConfiguration {
    public struct Label {}
    public let label: ButtonStyleConfiguration.Label
    public let isPressed: Bool
    public let role: ButtonRole?
}

@MainActor @preconcurrency
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Self.Configuration) -> Self.Body
    typealias Configuration = ButtonStyleConfiguration
}

public struct PlainButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension ButtonStyle where Self == PlainButtonStyle {
    public static var plain: PlainButtonStyle { PlainButtonStyle() }
}

public struct TextField<Label: View> {
}

extension TextField where Label == Text {
    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?, axis: Axis) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil, axis: Axis) {}
}

@MainActor @preconcurrency
public protocol TextFieldStyle {}
public struct PlainTextFieldStyle: TextFieldStyle {
    public init() {}
}
extension TextFieldStyle where Self == PlainTextFieldStyle {
    public static var plain: PlainTextFieldStyle { PlainTextFieldStyle() }
}

// MARK: - 形状

public protocol Shape: View, Sendable {}
public protocol InsettableShape: Shape {}

public enum RoundedCornerStyle: Hashable, Sendable { case circular, continuous }

public struct Circle {
    public init() {}
}

public struct Capsule {
    public init(style: RoundedCornerStyle = .continuous) {}
}

public struct Rectangle {
    public init() {}
}

public struct RoundedRectangle {
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {}
}

extension Shape {
    public func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> some View { _m() }
    public func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1) -> some View { _m() }
}

extension InsettableShape {
    public func strokeBorder<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View {
        _m()
    }
}

// MARK: - 工具栏

public protocol ToolbarContent {}

public struct ToolbarItemPlacement: Sendable {
    public static let automatic = ToolbarItemPlacement()
    public static let navigation = ToolbarItemPlacement()
    public static let primaryAction = ToolbarItemPlacement()
    public static let principal = ToolbarItemPlacement()
    public static let cancellationAction = ToolbarItemPlacement()
    public static let confirmationAction = ToolbarItemPlacement()
    public static let destructiveAction = ToolbarItemPlacement()
    #if os(iOS)
        public static let topBarLeading = ToolbarItemPlacement()
    #endif
}

public struct ToolbarItem<ID, Content: View>: ToolbarContent {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == () {}
}

public struct TupleToolbarContent<T>: ToolbarContent {
    public init(_ value: T) {}
}

@resultBuilder
public struct ToolbarContentBuilder {
    public static func buildBlock<C: ToolbarContent>(_ content: C) -> C { content }
    public static func buildBlock<each C: ToolbarContent>(_ content: repeat each C) -> TupleToolbarContent<(repeat each C)> {
        TupleToolbarContent((repeat each content))
    }
}

// MARK: - 修饰符

extension View {
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View { _m() }
    public func padding(_ length: CGFloat) -> some View { _m() }

    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View { _m() }
    public func frame(
        minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center
    ) -> some View { _m() }
    public func fixedSize() -> some View { _m() }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View { _m() }
    public func containerRelativeFrame(
        _ axes: Axis.Set, alignment: Alignment = .center, _ length: @escaping (CGFloat, Axis) -> CGFloat
    ) -> some View { _m() }

    public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View { _m() }
    public func background<S: ShapeStyle, T: Shape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle())
        -> some View
    { _m() }
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _m() }
    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _m() }

    public func font(_ font: Font?) -> some View { _m() }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { _m() }
    public func tint(_ tint: Color?) -> some View { _m() }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View { _m() }
    public func lineLimit(_ number: Int?) -> some View { _m() }
    public func lineLimit(_ limit: ClosedRange<Int>) -> some View { _m() }
    public func imageScale(_ scale: Image.Scale) -> some View { _m() }
    public func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View { _m() }
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View { _m() }
    public func disabled(_ disabled: Bool) -> some View { _m() }

    public func opacity(_ opacity: Double) -> some View { _m() }
    public func scaleEffect(_ s: CGFloat, anchor: UnitPoint = .center) -> some View { _m() }
    public func contentShape<S: Shape>(_ shape: S, eoFill: Bool = false) -> some View { _m() }
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { _m() }
    public func transition(_ t: AnyTransition) -> some View { _m() }
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View { _m() }
    public func safeAreaInset<V: View>(
        edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
        @ViewBuilder content: () -> V
    ) -> some View { _m() }

    public func onAppear(perform action: (() -> Void)? = nil) -> some View { _m() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        _m()
    }
    public func task(
        priority: TaskPriority = .userInitiated, @_inheritActorContext _ action: @escaping @isolated(any) @Sendable () async -> Void
    )
        -> some View
    { _m() }
    public func task<T: Equatable>(
        id value: T, priority: TaskPriority = .userInitiated,
        @_inheritActorContext _ action: @escaping @isolated(any) @Sendable () async -> Void
    ) -> some View { _m() }
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View { _m() }

    public func toolbar<Content: ToolbarContent>(@ToolbarContentBuilder content: () -> Content) -> some View { _m() }
    #if os(iOS)
        public func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { _m() }
    #endif

    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View { _m() }
    public func preferredColorScheme(_ colorScheme: ColorScheme?) -> some View { _m() }

    public func accessibilityHidden(_ hidden: Bool) -> some View { _m() }
    public func accessibilityLabel(_ label: Text) -> some View { _m() }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { _m() }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { _m() }
    public func accessibilityAction(_ actionKind: AccessibilityActionKind = .default, _ handler: @escaping () -> Void)
        -> some View
    { _m() }
}

// MARK: - 导航、菜单、链接、手势、sheet（WBS 12.16 起用到的）

public struct Menu<Label: View, Content: View> {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
}

extension Menu where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}

public struct Divider {
    public init() {}
}

public struct Link<Label: View> {
    public init(destination: URL, @ViewBuilder label: () -> Label) {}
}

extension Link where Label == Text {
    public init(_ titleKey: LocalizedStringKey, destination: URL) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, destination: URL) {}
}

public enum ControlSize: CaseIterable, Hashable, Sendable {
    case mini, small, regular, large, extraLarge
}

public struct PresentationDetent: Hashable, Sendable {
    let v: Double
    public static let medium = PresentationDetent(v: 0.5)
    public static let large = PresentationDetent(v: 1)
    public static func fraction(_ fraction: CGFloat) -> PresentationDetent { PresentationDetent(v: Double(fraction)) }
    public static func height(_ height: CGFloat) -> PresentationDetent { PresentationDetent(v: Double(height)) }
}

public struct GestureMask: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let none = GestureMask([])
    public static let gesture = GestureMask(rawValue: 1)
    public static let subviews = GestureMask(rawValue: 2)
    public static let all = GestureMask(rawValue: 3)
}

@MainActor @preconcurrency
public protocol Gesture {
    associatedtype Value
}

public struct DragGesture: Gesture {
    public struct Value: Equatable, Sendable {
        public var time: Date
        public var location: CGPoint
        public var startLocation: CGPoint
        public var translation: CGSize
        public var velocity: CGSize
        public var predictedEndLocation: CGPoint
        public var predictedEndTranslation: CGSize
    }
    public var minimumDistance: CGFloat
    public init(minimumDistance: CGFloat = 10) { self.minimumDistance = minimumDistance }
}

public struct _EndedGesture<Content: Gesture>: Gesture {
    public typealias Value = Content.Value
}

public struct _ChangedGesture<Content: Gesture>: Gesture {
    public typealias Value = Content.Value
}

extension Gesture {
    public func onEnded(_ action: @escaping (Value) -> Void) -> _EndedGesture<Self> { _EndedGesture() }
}

extension Gesture where Value: Equatable {
    public func onChanged(_ action: @escaping (Value) -> Void) -> _ChangedGesture<Self> { _ChangedGesture() }
}

extension View {
    public func navigationTitle(_ title: Text) -> some View { _m() }
    public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { _m() }
    @_disfavoredOverload public func navigationTitle<S: StringProtocol>(_ title: S) -> some View { _m() }
    public func navigationDestination<D: Hashable, C: View>(
        for data: D.Type, @ViewBuilder destination: @escaping (D) -> C
    ) -> some View { _m() }

    public func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View { _m() }
    public func sheet<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) -> some View { _m() }
    public func presentationDetents(_ detents: Set<PresentationDetent>) -> some View { _m() }

    public func id<ID: Hashable>(_ id: ID) -> some View { _m() }
    public func controlSize(_ controlSize: ControlSize) -> some View { _m() }
    public func onOpenURL(perform action: @escaping (URL) -> ()) -> some View { _m() }
    public func environment<T: AnyObject & Observable>(_ object: T?) -> some View { _m() }

    public func gesture<T: Gesture>(_ gesture: T, including mask: GestureMask = .all) -> some View { _m() }
    public func simultaneousGesture<T: Gesture>(_ gesture: T, including mask: GestureMask = .all) -> some View { _m() }

    public func accessibilityValue(_ valueDescription: Text) -> some View { _m() }
    public func accessibilityHint(_ hint: Text) -> some View { _m() }
}

// MARK: - 渲染与宿主

@MainActor
public final class ImageRenderer<Content: View> {
    public init(content view: Content) {}
    public var proposedSize: ProposedViewSize = .unspecified
    public var cgImage: CGImage? { CGImage() }
}

#if canImport(UIKit)
    @MainActor
    open class UIHostingController<Content: View>: UIViewController {
        public init(rootView: Content) { super.init() }
        public func sizeThatFits(in size: CGSize) -> CGSize { size }
    }
#elseif canImport(AppKit)
    @MainActor
    open class NSHostingController<Content: View>: NSViewController {
        public init(rootView: Content) { super.init() }
        public func sizeThatFits(in size: CGSize) -> CGSize { size }
    }
#endif

// MARK: - App

@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
}

@resultBuilder
public struct SceneBuilder {
    public static func buildBlock<C: Scene>(_ content: C) -> C { content }
}

extension Never: Scene {}

public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

@MainActor @preconcurrency
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}


// 视图、形状的协议一致性放在扩展里：主声明里的成员不继承 View 的 @MainActor（和 SDK 的行为一致）。
extension TupleView: View { public var body: Never { fatalError() } }
extension _ConditionalContent: View { public var body: Never { fatalError() } }
extension AnyView: View { public var body: Never { fatalError() } }
extension ModifiedContent: View { public var body: Never { fatalError() } }
extension Color: View { public var body: Never { fatalError() } }
extension Text: View { public var body: Never { fatalError() } }
extension Image: View { public var body: Never { fatalError() } }
extension Label: View { public var body: Never { fatalError() } }
extension HStack: View { public var body: Never { fatalError() } }
extension VStack: View { public var body: Never { fatalError() } }
extension ZStack: View { public var body: Never { fatalError() } }
extension LazyVStack: View { public var body: Never { fatalError() } }
extension ScrollView: View { public var body: Never { fatalError() } }
extension Spacer: View { public var body: Never { fatalError() } }
extension EmptyView: View { public var body: Never { fatalError() } }
extension ProgressView: View { public var body: Never { fatalError() } }
extension ForEach: View { public var body: Never { fatalError() } }
extension NavigationStack: View { public var body: Never { fatalError() } }
extension Menu: View { public var body: Never { fatalError() } }
extension Divider: View { public var body: Never { fatalError() } }
extension Link: View { public var body: Never { fatalError() } }
extension TimelineView: View { public var body: Never { fatalError() } }
extension Button: View { public var body: Never { fatalError() } }
extension TextField: View { public var body: Never { fatalError() } }
extension Circle: InsettableShape { public var body: Never { fatalError() } }
extension Capsule: InsettableShape { public var body: Never { fatalError() } }
extension Rectangle: InsettableShape { public var body: Never { fatalError() } }
extension RoundedRectangle: InsettableShape { public var body: Never { fatalError() } }
extension ButtonStyleConfiguration.Label: View { public var body: Never { fatalError() } }

extension App {
    @MainActor public static func main() {}
}
