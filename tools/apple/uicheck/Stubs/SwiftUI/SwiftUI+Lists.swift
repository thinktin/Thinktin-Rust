// iOS 界面改版（docs/ios-ui-redesign.md 第 2.10 节，第 0 轮）要用、别的桩文件里还没有的 SwiftUI API：列表、表单、分组、
// 带值的行、空状态、列表和工具栏的修饰符、系统按钮样式、搜索、左滑、长按预览、触感、网格、材质。
// 和主桩文件一样只用来在 Linux 上做类型检查：签名照 iOS 17 / macOS 14 SDK 的写，实现全是空的。
// iOS 18 / 26 才有的（玻璃、新工具栏、缩放转场）在 SwiftUI+Glass.swift。只有 iOS 有的放在 `#if canImport(UIKit)` 里。
// 加新的之前先 grep 整个 Stubs/，免得重复声明。

// MARK: - 边、内边距（iOS 13–15）

public enum HorizontalEdge: Int8, CaseIterable, Sendable {
    case leading, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let leading = Set(rawValue: 1)
        public static let trailing = Set(rawValue: 2)
        public static let all = Set(rawValue: 3)
    }
}

extension VerticalEdge {
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1)
        public static let bottom = Set(rawValue: 2)
        public static let all = Set(rawValue: 3)
    }
}

public struct EdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat
    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
    public init() { self.init(top: 0, leading: 0, bottom: 0, trailing: 0) }
}

// MARK: - 列表（iOS 13；带选择的 iOS 13 / 16）

public struct List<SelectionValue: Hashable, Content: View> {
    public init(selection: Binding<SelectionValue?>?, @ViewBuilder content: () -> Content) {}
    public init(selection: Binding<Set<SelectionValue>>?, @ViewBuilder content: () -> Content) {}
}

extension List where SelectionValue == Never {
    public init(@ViewBuilder content: () -> Content) {}
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {}
    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, ID, RowContent> {}
}

public protocol ListStyle {}

public struct DefaultListStyle: ListStyle {
    public init() {}
}

public struct PlainListStyle: ListStyle {
    public init() {}
}

public struct InsetListStyle: ListStyle {
    public init() {}
}

public struct SidebarListStyle: ListStyle {
    public init() {}
}

extension ListStyle where Self == DefaultListStyle {
    public static var automatic: DefaultListStyle { DefaultListStyle() }
}

extension ListStyle where Self == PlainListStyle {
    public static var plain: PlainListStyle { PlainListStyle() }
}

extension ListStyle where Self == InsetListStyle {
    public static var inset: InsetListStyle { InsetListStyle() }
}

extension ListStyle where Self == SidebarListStyle {
    public static var sidebar: SidebarListStyle { SidebarListStyle() }
}

#if canImport(UIKit)
    /// iOS 14；macOS 上没有（Mac 用 `Form` + `.formStyle(.grouped)`）。
    public struct InsetGroupedListStyle: ListStyle {
        public init() {}
    }

    /// iOS 13；macOS 上没有。
    public struct GroupedListStyle: ListStyle {
        public init() {}
    }

    extension ListStyle where Self == InsetGroupedListStyle {
        public static var insetGrouped: InsetGroupedListStyle { InsetGroupedListStyle() }
    }

    extension ListStyle where Self == GroupedListStyle {
        public static var grouped: GroupedListStyle { GroupedListStyle() }
    }

    /// 分组之间的距离（iOS 17，只有 iOS）。
    public struct ListSectionSpacing: Sendable {
        let v: CGFloat
        public static let `default` = ListSectionSpacing(v: -1)
        public static let compact = ListSectionSpacing(v: 0)
        public static func custom(_ spacing: CGFloat) -> ListSectionSpacing { ListSectionSpacing(v: spacing) }
    }

    extension View {
        public func listSectionSpacing(_ spacing: ListSectionSpacing) -> some View { _m() }
        public func listSectionSpacing(_ spacing: CGFloat) -> some View { _m() }
        /// iOS 15，只有 iOS。
        public func listRowSpacing(_ spacing: CGFloat?) -> some View { _m() }
    }
#endif

// MARK: - 表单（iOS 13；样式 iOS 16）

public struct Form<Content: View> {
    public init(@ViewBuilder content: () -> Content) {}
}

public protocol FormStyle {}

public struct AutomaticFormStyle: FormStyle {
    public init() {}
}

public struct GroupedFormStyle: FormStyle {
    public init() {}
}

public struct ColumnsFormStyle: FormStyle {
    public init() {}
}

extension FormStyle where Self == AutomaticFormStyle {
    public static var automatic: AutomaticFormStyle { AutomaticFormStyle() }
}

extension FormStyle where Self == GroupedFormStyle {
    public static var grouped: GroupedFormStyle { GroupedFormStyle() }
}

extension FormStyle where Self == ColumnsFormStyle {
    public static var columns: ColumnsFormStyle { ColumnsFormStyle() }
}

// MARK: - 分组（iOS 13；标题、脚注 iOS 15；可折叠 iOS 17）

public struct Section<Parent, Content, Footer> {
}

extension Section where Parent: View, Content: View, Footer: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer)
    {}
}

extension Section where Parent: View, Content: View, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
}

extension Section where Parent == EmptyView, Content: View, Footer: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {}
}

extension Section where Parent == EmptyView, Content: View, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {}
}

extension Section where Parent == Text, Content: View, Footer == EmptyView {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
    public init(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content
    ) {}
}

// MARK: - 带值的行（iOS 16）

public struct LabeledContent<Label, Content> {
}

extension LabeledContent where Label: View, Content: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
}

extension LabeledContent where Label == Text, Content: View {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}

extension LabeledContent where Label == Text, Content == Text {
    public init<S: StringProtocol>(_ titleKey: LocalizedStringKey, value: S) {}
    @_disfavoredOverload public init<S1: StringProtocol, S2: StringProtocol>(_ title: S1, value: S2) {}
}

// MARK: - 空状态（iOS 17）

public struct ContentUnavailableView<Label: View, Description: View, Actions: View> {
    /// 只给下面的 `.search` 用（测试在 Linux 上真的会跑这些桩）。
    init(stub: Void) {}
    public init(
        @ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {}
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    public init(_ title: LocalizedStringKey, systemImage name: String, description: Text? = nil) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String, description: Text? = nil)
    {}
}

/// `ContentUnavailableView.search` 的内容（系统的放大镜、“没有……的结果”、“检查拼写或换个关键词”）。
public struct SearchUnavailableContent {
    public struct Label {}
    public struct Description {}
    public struct Actions {}
}

extension ContentUnavailableView
where
    Label == SearchUnavailableContent.Label, Description == SearchUnavailableContent.Description,
    Actions == SearchUnavailableContent.Actions
{
    public static var search: Self { Self(stub: ()) }
    public static func search(text: String) -> Self { Self(stub: ()) }
}

// MARK: - 列表、分组的修饰符

extension Text {
    /// 分组标题的大小写（iOS 14）：分组标题加 `.textCase(nil)` 不转大写。
    public enum Case: Hashable, Sendable { case uppercase, lowercase }
}

extension View {
    public func listStyle<S: ListStyle>(_ style: S) -> some View { _m() }
    public func formStyle<S: FormStyle>(_ style: S) -> some View { _m() }
    /// iOS 15、macOS 13。
    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { _m() }
    public func listSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { _m() }
    /// iOS 13。只对行生效：加在 `Section` 的内容或 `ForEach` 上，加在 `List` 本身上没用。
    public func listRowBackground<V: View>(_ view: V?) -> some View { _m() }
    public func listRowInsets(_ insets: EdgeInsets?) -> some View { _m() }
    /// iOS 16、macOS 13：藏起 `List` / `Form` 自带的底色，换成自己的。
    public func scrollContentBackground(_ visibility: Visibility) -> some View { _m() }
    public func textCase(_ textCase: Text.Case?) -> some View { _m() }
    /// iOS 15、macOS 12。只在 `List` 里有效。
    public func swipeActions<T: View>(
        edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true, @ViewBuilder content: () -> T
    ) -> some View { _m() }
    /// iOS 16、macOS 13：长按菜单带自己画的预览。
    public func contextMenu<M: View, P: View>(@ViewBuilder menuItems: () -> M, @ViewBuilder preview: () -> P)
        -> some View
    { _m() }
    /// iOS 17、macOS 14：滚动内容不裁到滚动视图的边框（横排的胶囊按钮的阴影、玻璃不被切掉）。
    public func scrollClipDisabled(_ disabled: Bool = true) -> some View { _m() }
    /// iOS 15、macOS 12：列表行、标签页、iOS 26 的工具栏按钮上的角标。
    public func badge(_ count: Int) -> some View { _m() }
    public func badge(_ label: Text?) -> some View { _m() }
    public func badge(_ key: LocalizedStringKey?) -> some View { _m() }
    @_disfavoredOverload public func badge<S: StringProtocol>(_ label: S?) -> some View { _m() }
}

// MARK: - 系统按钮样式（iOS 15）、按钮的外形（iOS 15；圆形 iOS 17）、带图标的按钮（iOS 17）

public struct PrimitiveButtonStyleConfiguration {
    public struct Label {}
    public let role: ButtonRole?
    public let label: PrimitiveButtonStyleConfiguration.Label
    public func trigger() {}
}

extension PrimitiveButtonStyleConfiguration.Label: View { public var body: Never { fatalError() } }

@MainActor @preconcurrency
public protocol PrimitiveButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Self.Configuration) -> Self.Body
    typealias Configuration = PrimitiveButtonStyleConfiguration
}

public struct PlainButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct DefaultButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct BorderlessButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct BorderedButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct BorderedProminentButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    public static var plain: PlainButtonStyle { PlainButtonStyle() }
}

extension PrimitiveButtonStyle where Self == DefaultButtonStyle {
    public static var automatic: DefaultButtonStyle { DefaultButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderlessButtonStyle {
    public static var borderless: BorderlessButtonStyle { BorderlessButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedButtonStyle {
    public static var bordered: BorderedButtonStyle { BorderedButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle {
    public static var borderedProminent: BorderedProminentButtonStyle { BorderedProminentButtonStyle() }
}

public struct ButtonBorderShape: Equatable, Sendable {
    let v: CGFloat
    public static let automatic = ButtonBorderShape(v: -1)
    public static let capsule = ButtonBorderShape(v: -2)
    public static let roundedRectangle = ButtonBorderShape(v: -3)
    /// iOS 17、macOS 14。
    public static let circle = ButtonBorderShape(v: -4)
    public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape { ButtonBorderShape(v: radius) }
}

extension View {
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View { _m() }
    public func buttonBorderShape(_ shape: ButtonBorderShape) -> some View { _m() }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, systemImage: String, action: @escaping @MainActor () -> Void
    ) {}
    public init(
        _ titleKey: LocalizedStringKey, systemImage: String, role: ButtonRole?,
        action: @escaping @MainActor () -> Void
    ) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, systemImage: String, role: ButtonRole?, action: @escaping @MainActor () -> Void
    ) {}
}

// MARK: - 标签的样式（iOS 14）

public protocol LabelStyle {}

public struct DefaultLabelStyle: LabelStyle {
    public init() {}
}

public struct IconOnlyLabelStyle: LabelStyle {
    public init() {}
}

public struct TitleOnlyLabelStyle: LabelStyle {
    public init() {}
}

public struct TitleAndIconLabelStyle: LabelStyle {
    public init() {}
}

extension LabelStyle where Self == DefaultLabelStyle {
    public static var automatic: DefaultLabelStyle { DefaultLabelStyle() }
}

extension LabelStyle where Self == IconOnlyLabelStyle {
    public static var iconOnly: IconOnlyLabelStyle { IconOnlyLabelStyle() }
}

extension LabelStyle where Self == TitleOnlyLabelStyle {
    public static var titleOnly: TitleOnlyLabelStyle { TitleOnlyLabelStyle() }
}

extension LabelStyle where Self == TitleAndIconLabelStyle {
    public static var titleAndIcon: TitleAndIconLabelStyle { TitleAndIconLabelStyle() }
}

extension View {
    public func labelStyle<S: LabelStyle>(_ style: S) -> some View { _m() }
}

// MARK: - 菜单（带图标 iOS 17、主操作 iOS 15）、导航链接（带标题 iOS 16）

extension Menu where Label == SwiftUI.Label<Text, Image> {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(
        _ title: S, systemImage: String, @ViewBuilder content: () -> Content
    ) {}
}

extension Menu {
    public init(
        @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label,
        primaryAction: @escaping @MainActor () -> Void
    ) {}
}

extension NavigationLink where Label == Text, Destination == Never {
    public init<P: Hashable>(_ titleKey: LocalizedStringKey, value: P?) {}
    @_disfavoredOverload public init<S: StringProtocol, P: Hashable>(_ title: S, value: P?) {}
}

extension NavigationLink where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder destination: () -> Destination) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> Destination) {}
}

// MARK: - 选择器的样式（行内 iOS 14、压栈 iOS 16、滚轮只有 iOS）

public struct InlinePickerStyle: PickerStyle {
    public init() {}
}

public struct NavigationLinkPickerStyle: PickerStyle {
    public init() {}
}

extension PickerStyle where Self == InlinePickerStyle {
    public static var inline: InlinePickerStyle { InlinePickerStyle() }
}

extension PickerStyle where Self == NavigationLinkPickerStyle {
    public static var navigationLink: NavigationLinkPickerStyle { NavigationLinkPickerStyle() }
}

#if canImport(UIKit)
    public struct WheelPickerStyle: PickerStyle {
        public init() {}
    }

    extension PickerStyle where Self == WheelPickerStyle {
        public static var wheel: WheelPickerStyle { WheelPickerStyle() }
    }
#endif

// MARK: - 工具栏：位置、成组、显隐、标题样式（iOS 14–17）

extension ToolbarItemPlacement {
    /// iOS 15、macOS 12：键盘上方。
    public static let keyboard = ToolbarItemPlacement()
    /// iOS 16、macOS 13。
    public static let secondaryAction = ToolbarItemPlacement()
    public static let status = ToolbarItemPlacement()
    #if canImport(UIKit)
        /// iOS 17。
        public static let topBarTrailing = ToolbarItemPlacement()
        /// iOS 14；macOS 上没有。
        public static let bottomBar = ToolbarItemPlacement()
    #endif
}

public struct ToolbarItemGroup<Content: View> {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {}
}

extension ToolbarItemGroup: ToolbarContent { public var body: Never { fatalError() } }

extension ToolbarContentBuilder {
    public static func buildExpression<C: ToolbarContent>(_ content: C) -> C { content }
    /// iOS 16、macOS 13。
    public static func buildIf<C: ToolbarContent>(_ content: C?) -> C? { content }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(first: T) -> _ConditionalContent<T, F> {
        _ConditionalContent()
    }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(second: F) -> _ConditionalContent<T, F> {
        _ConditionalContent()
    }
    // `buildLimitedAvailability` 在 SDK 里是 iOS 17.5 / macOS 14.5 才有，比我们的最低版本（iOS 17、macOS 14）高：
    // `.toolbar { if #available(...) { … } }` 在真实 SDK 上编不过，所以这里故意不给。要按系统版本放的工具栏项
    // （iOS 26 的 ToolbarSpacer）用 Design/Glass.swift 里的 `GlassToolbarSpacer`。
}

extension Optional: ToolbarContent where Wrapped: ToolbarContent {
    public var body: Never { fatalError() }
}

extension _ConditionalContent: ToolbarContent where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
    public var body: Never { fatalError() }
}

/// 工具栏所在的栏（iOS 16）。
public struct ToolbarPlacement: Sendable {
    let v: Int
    public static let automatic = ToolbarPlacement(v: 0)
    #if canImport(UIKit)
        public static let navigationBar = ToolbarPlacement(v: 1)
        public static let bottomBar = ToolbarPlacement(v: 2)
        public static let tabBar = ToolbarPlacement(v: 3)
    #elseif canImport(AppKit)
        public static let windowToolbar = ToolbarPlacement(v: 4)
    #endif
}

/// 导航标题的样式（iOS 17、macOS 14）。
public struct ToolbarTitleDisplayMode: Sendable {
    let v: Int
    public static let automatic = ToolbarTitleDisplayMode(v: 0)
    public static let inline = ToolbarTitleDisplayMode(v: 1)
    #if canImport(UIKit)
        public static let inlineLarge = ToolbarTitleDisplayMode(v: 2)
        public static let large = ToolbarTitleDisplayMode(v: 3)
    #endif
}

/// 系统自己加的工具栏项（iOS 17、macOS 14）：`toolbar(removing:)`、iOS 26 的 `DefaultToolbarItem(kind:placement:)`。
public struct ToolbarDefaultItemKind: Sendable {
    let v: Int
    public static let sidebarToggle = ToolbarDefaultItemKind(v: 0)
    /// `searchable` 加的搜索项。
    @available(iOS 26.0, macOS 26.0, *)
    public static var search: ToolbarDefaultItemKind { ToolbarDefaultItemKind(v: 1) }
    @available(iOS 26.0, macOS 26.0, *)
    public static var title: ToolbarDefaultItemKind { ToolbarDefaultItemKind(v: 2) }
}

extension View {
    /// iOS 16、macOS 13。iOS 18 起有同义的 `toolbarVisibility(_:for:)`（SwiftUI+Glass.swift）。
    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { _m() }
    public func toolbarTitleDisplayMode(_ mode: ToolbarTitleDisplayMode) -> some View { _m() }
    public func toolbar(removing defaultItemKind: ToolbarDefaultItemKind?) -> some View { _m() }
}

// MARK: - 搜索（iOS 15；`isPresented:` iOS 17）

extension SearchFieldPlacement {
    /// iOS 17、macOS 14。
    public static let toolbar = SearchFieldPlacement(v: 1)
    public static let sidebar = SearchFieldPlacement(v: 2)
    #if canImport(UIKit)
        public enum NavigationBarDrawerDisplayMode: Sendable { case automatic, always }
        public static let navigationBarDrawer = SearchFieldPlacement(v: 3)
        public static func navigationBarDrawer(displayMode: NavigationBarDrawerDisplayMode) -> SearchFieldPlacement {
            SearchFieldPlacement(v: 4)
        }
    #endif
}

extension View {
    public func searchable(
        text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringKey
    ) -> some View { _m() }
    @_disfavoredOverload public func searchable<S: StringProtocol>(
        text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: S
    ) -> some View { _m() }
    public func searchable(
        text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic,
        prompt: Text? = nil
    ) -> some View { _m() }
    public func searchable(
        text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic,
        prompt: LocalizedStringKey
    ) -> some View { _m() }
    @_disfavoredOverload public func searchable<S: StringProtocol>(
        text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic, prompt: S
    ) -> some View { _m() }
}

// MARK: - 弹窗、确认框的其余重载（iOS 15）

extension View {
    public func alert<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A)
        -> some View
    { _m() }
    @_disfavoredOverload public func alert<S: StringProtocol, A: View>(
        _ title: S, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A
    ) -> some View { _m() }
    @_disfavoredOverload public func alert<S: StringProtocol, A: View, M: View, T>(
        _ title: S, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: (T) -> A,
        @ViewBuilder message: (T) -> M
    ) -> some View { _m() }

    public func confirmationDialog<A: View>(
        _ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> A
    ) -> some View { _m() }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, T>(
        _ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?,
        @ViewBuilder actions: (T) -> A
    ) -> some View { _m() }
}

// MARK: - sheet、全屏（iOS 14，只有 iOS）、sheet 的高度和样式（iOS 16 / 16.4）

extension View {
    public func presentationDetents(_ detents: Set<PresentationDetent>, selection: Binding<PresentationDetent>)
        -> some View
    { _m() }
    public func presentationDragIndicator(_ visibility: Visibility) -> some View { _m() }
    /// iOS 16.4、macOS 13.3。
    public func presentationBackground<S: ShapeStyle>(_ style: S) -> some View { _m() }
    /// iOS 17、macOS 14：压栈到某个值（`nil` 时出栈）。
    public func navigationDestination<D: Hashable, C: View>(
        item: Binding<D?>, @ViewBuilder destination: @escaping (D) -> C
    ) -> some View { _m() }
}

#if canImport(UIKit)
    extension View {
        public func fullScreenCover<Content: View>(
            isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
        ) -> some View { _m() }
        public func fullScreenCover<Item: Identifiable, Content: View>(
            item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content
        ) -> some View { _m() }
    }
#endif

// MARK: - 触感（iOS 17、macOS 14）

public struct SensoryFeedback: Equatable, Sendable {
    let v: Int
    public enum Weight: Equatable, Sendable { case light, medium, heavy }
    public enum Flexibility: Equatable, Sendable { case rigid, solid, soft }
    public static let success = SensoryFeedback(v: 0)
    public static let warning = SensoryFeedback(v: 1)
    public static let error = SensoryFeedback(v: 2)
    public static let selection = SensoryFeedback(v: 3)
    public static let increase = SensoryFeedback(v: 4)
    public static let decrease = SensoryFeedback(v: 5)
    public static let start = SensoryFeedback(v: 6)
    public static let stop = SensoryFeedback(v: 7)
    public static let alignment = SensoryFeedback(v: 8)
    public static let levelChange = SensoryFeedback(v: 9)
    public static let impact = SensoryFeedback(v: 10)
    public static func impact(weight: Weight = .medium, intensity: Double = 1.0) -> SensoryFeedback {
        SensoryFeedback(v: 11)
    }
    public static func impact(flexibility: Flexibility, intensity: Double = 1.0) -> SensoryFeedback {
        SensoryFeedback(v: 12)
    }
}

extension View {
    public func sensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View { _m() }
    public func sensoryFeedback<T: Equatable>(
        _ feedback: SensoryFeedback, trigger: T, condition: @escaping (_ oldValue: T, _ newValue: T) -> Bool
    ) -> some View { _m() }
    public func sensoryFeedback<T: Equatable>(
        trigger: T, _ feedback: @escaping (_ oldValue: T, _ newValue: T) -> SensoryFeedback?
    ) -> some View { _m() }
}

// MARK: - 网格（iOS 14）

public struct GridItem: Sendable {
    public enum Size: Sendable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
    public var size: GridItem.Size
    public var spacing: CGFloat?
    public var alignment: Alignment?
    public init(_ size: GridItem.Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

public struct LazyVGrid<Content: View> {
    public init(
        columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
        pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content
    ) {}
}

// MARK: - 仪表（iOS 16、macOS 13）

public struct Gauge<Label: View, CurrentValueLabel: View, BoundsLabel: View, MarkedValueLabels: View> {
}

extension Gauge where CurrentValueLabel == EmptyView, BoundsLabel == EmptyView, MarkedValueLabels == EmptyView {
    public init<V: BinaryFloatingPoint>(value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label) {}
}

extension Gauge where BoundsLabel == EmptyView, MarkedValueLabels == EmptyView {
    public init<V: BinaryFloatingPoint>(
        value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label,
        @ViewBuilder currentValueLabel: () -> CurrentValueLabel
    ) {}
}

public protocol GaugeStyle {}

public struct LinearCapacityGaugeStyle: GaugeStyle {
    public init() {}
}

public struct DefaultGaugeStyle: GaugeStyle {
    public init() {}
}

extension GaugeStyle where Self == LinearCapacityGaugeStyle {
    public static var linearCapacity: LinearCapacityGaugeStyle { LinearCapacityGaugeStyle() }
}

extension GaugeStyle where Self == DefaultGaugeStyle {
    public static var automatic: DefaultGaugeStyle { DefaultGaugeStyle() }
}

extension View {
    public func gaugeStyle<S: GaugeStyle>(_ style: S) -> some View { _m() }
}

// MARK: - 粘贴按钮（iOS 16、macOS 13）

/// SDK 里是 CoreTransferable 的协议（SwiftUI 重新导出）；这里只为 `PasteButton` 的类型检查。
public protocol Transferable {}
extension String: Transferable {}
extension URL: Transferable {}

public struct PasteButton {
    public init<T: Transferable>(payloadType: T.Type, onPaste: @escaping ([T]) -> Void) {}
}

// MARK: - 材质（iOS 15）、形状的简写（iOS 17）

public struct Material: ShapeStyle {
    let v: Int
    public static let regular = Material(v: 0)
    public static let thick = Material(v: 1)
    public static let thin = Material(v: 2)
    public static let ultraThin = Material(v: 3)
    public static let ultraThick = Material(v: 4)
    /// 系统栏的材质（iOS 15）。
    public static let bar = Material(v: 5)
}

extension ShapeStyle where Self == Material {
    public static var regularMaterial: Material { .regular }
    public static var thickMaterial: Material { .thick }
    public static var thinMaterial: Material { .thin }
    public static var ultraThinMaterial: Material { .ultraThin }
    public static var ultraThickMaterial: Material { .ultraThick }
}

extension Shape where Self == Capsule {
    public static var capsule: Capsule { Capsule() }
}

extension Shape where Self == Circle {
    public static var circle: Circle { Circle() }
}

extension Shape where Self == Rectangle {
    public static var rect: Rectangle { Rectangle() }
}

extension Shape where Self == RoundedRectangle {
    public static func rect(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: style)
    }
}

// MARK: - 偏移、文字缩小（iOS 13）

extension View {
    public func minimumScaleFactor(_ factor: CGFloat) -> some View { _m() }
    public func offset(_ offset: CGSize) -> some View { _m() }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View { _m() }
}

// MARK: - 视图一致性

extension List: View { public var body: Never { fatalError() } }
extension Form: View { public var body: Never { fatalError() } }
extension Section: View where Parent: View, Content: View, Footer: View { public var body: Never { fatalError() } }
extension LabeledContent: View where Label: View, Content: View { public var body: Never { fatalError() } }
extension ContentUnavailableView: View { public var body: Never { fatalError() } }
extension SearchUnavailableContent.Label: View { public var body: Never { fatalError() } }
extension SearchUnavailableContent.Description: View { public var body: Never { fatalError() } }
extension SearchUnavailableContent.Actions: View { public var body: Never { fatalError() } }
extension LazyVGrid: View { public var body: Never { fatalError() } }
extension Gauge: View { public var body: Never { fatalError() } }
extension PasteButton: View { public var body: Never { fatalError() } }
