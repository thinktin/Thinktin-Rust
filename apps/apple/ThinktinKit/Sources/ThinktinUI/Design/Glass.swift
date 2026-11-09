import SwiftUI

// iOS 26 的 Liquid Glass 和新工具栏的兼容层（docs/ios-ui-redesign.md 2.6、2.7、2.10；用户定了 6.3 A：最低版本保持 iOS 17）。
//
// 要显式调用的 iOS 26 / 18 接口都在这个文件里，每个带 iOS 17 / 18、macOS 14 的退路；页面里用这里的帮手，不散写
// `if #available`。外观以 iOS 26 为准，旧系统只要求能用、不乱。工具栏、菜单、sheet、搜索栏、alert 这些系统控件
// 用 26 SDK 编出来在 iOS 26 上自动是玻璃，不用经过这里。
//
// 写法上的两条规矩：
// - 帮手的分支用显式 `return`（opaque 返回类型按系统版本取不同的底层类型），不用 `@ViewBuilder` 的 `if #available`：
//   那样会包一层 `AnyView`，工具栏认不出里面的按钮，视图的身份也会变。
// - `.toolbar { }` 里不能写 `if #available`：`ToolbarContentBuilder.buildLimitedAvailability` 要 iOS 17.5 / macOS 14.5，
//   比最低版本高，真实 SDK 上编不过。按系统版本放的工具栏项用下面的 `ToolbarContent` 帮手（`GlassToolbarSpacer` 这些）。
//
// iOS 17 就有、不用包的：`ContentUnavailableView`、`.searchable(text:isPresented:)`、`.sensoryFeedback`、`Section(isExpanded:)`、
// `.toolbarTitleDisplayMode`、`.topBarLeading` / `.topBarTrailing`、`.buttonBorderShape(.circle)`；藏导航栏用
// `.toolbar(.hidden, for: .navigationBar)`（iOS 16 起，iOS 18 的 `toolbarVisibility` 是它的新名字）。

// MARK: - 关闭、确认按钮（2.6）

/// sheet 左上的关闭按钮，放在 `ToolbarItem(placement: .cancellationAction)` 里：iOS 26 带系统的关闭角色
/// （`ButtonRole.close`，画成玻璃圆 ×），旧系统是 × 图标按钮。读屏按界面语言念“关闭”。× 是中性色（`neutralTint()`，
/// 参考 11、34、52 和系统的返回箭头一样），不用强调色。
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
/// }
/// ```
public struct CloseButton: View {
    private let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    public init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    public var body: some View {
        // 标签自己给（系统按角色生成的标签跟着系统语言，不跟 App 里选的界面语言），iOS 26 照样按角色画成玻璃圆。
        Button(role: GlassRoles.close, action: action) {
            Label(language == .chinese ? "关闭" : "Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .neutralTint()
    }
}

/// 编辑表单、sheet 右上的主操作（完成、保存、确认），放在 `ToolbarItem(placement: .confirmationAction)` 里：iOS 26 带
/// `ButtonRole.confirm`，画成突出的玻璃胶囊；旧系统是加粗的文字按钮。保存中换成转圈；不合法时调用方加 `.disabled`。
public struct ConfirmButton: View {
    private let title: String?
    private let isWorking: Bool
    private let workingLabel: String?
    private let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    /// - Parameters:
    ///   - title: 按钮上的字；nil 用“完成”。
    ///   - isWorking: 正在保存：显示转圈，不能再点。
    ///   - workingLabel: 转圈的读屏文字；nil 用“正在保存”（新建这类不是保存的操作自己给，比如“正在新建”）。
    public init(
        _ title: String? = nil, isWorking: Bool = false, workingLabel: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.isWorking = isWorking
        self.workingLabel = workingLabel
        self.action = action
    }

    public var body: some View {
        if isWorking {
            ProgressView()
                .accessibilityLabel(Text(workingLabel ?? (language == .chinese ? "正在保存" : "Saving")))
        } else {
            Button(title ?? (language == .chinese ? "完成" : "Done"), role: GlassRoles.confirm, action: action)
        }
    }
}

/// iOS 26 新加的按钮角色；旧系统没有，退回不带角色。
enum GlassRoles {
    static var close: ButtonRole? {
        if #available(iOS 26.0, macOS 26.0, *) { return .close }
        return nil
    }

    static var confirm: ButtonRole? {
        if #available(iOS 26.0, macOS 26.0, *) { return .confirm }
        return nil
    }
}

// MARK: - 按钮的玻璃样式（2.6）

/// 系统按钮的分量：主按钮用 `.prominent`（强调色填充），次按钮用 `.regular`（中性色的字，规范 2.2：强调色只给主按钮、
/// 发送、开关、链接、选中；参考里“编辑”“接管控制”“连接”这些次按钮都是白字灰底）。
public enum GlassButtonProminence: Hashable, Sendable {
    case regular
    case prominent
}

extension View {
    /// 系统按钮的玻璃样式：iOS 26 `.glass` / `.glassProminent`，旧系统 `.bordered` / `.borderedProminent`。
    /// 小胶囊再加 `.buttonBorderShape(.capsule)` + `.controlSize(.small)`；底部全宽的主按钮加 `.controlSize(.large)` 和
    /// `.frame(maxWidth: .infinity)`（放进 `floatingBar`）。工具栏里的按钮不用加，系统自己画。
    ///
    /// `.regular` 的字是中性色（`neutralTint()`）。次按钮要别的颜色（删除、停止这种破坏性的用失败色）时把 `.tint(_:)`
    /// 写在这个修饰符**前面**（离按钮近的 `tint` 生效，写在后面会被这里的中性色盖住）。
    public func glassButtonStyle(_ prominence: GlassButtonProminence = .regular) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            return modifier(GlassButtonStyleModifier(prominence: prominence))
        } else {
            return modifier(BorderedButtonStyleModifier(prominence: prominence))
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct GlassButtonStyleModifier: ViewModifier {
    let prominence: GlassButtonProminence

    func body(content: Content) -> some View {
        switch prominence {
        case .regular: content.neutralTint().buttonStyle(.glass)
        case .prominent: content.buttonStyle(.glassProminent)
        }
    }
}

private struct BorderedButtonStyleModifier: ViewModifier {
    let prominence: GlassButtonProminence

    func body(content: Content) -> some View {
        switch prominence {
        case .regular: content.neutralTint().buttonStyle(.bordered)
        case .prominent: content.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 次要控件的中性色（2.2）

extension View {
    /// 次要控件用中性色（规范 2.2：强调色只给主按钮、发送、开关、链接、选中）：工具栏里只有图标的按钮和菜单（“…”“?”×）、
    /// 次按钮的字。参考里这些都是白字（深色）/ 黑字（浅色），和系统的返回箭头一致。
    public func neutralTint() -> some View {
        tint(Theme.ink)
    }

    /// 表单里 `Picker(.menu)` 的值和上下箭头（参考 12 的语音、速度、语言，65 的值）：次要文字的灰，不用强调色。
    public func menuPickerTint() -> some View {
        tint(Theme.inkSecondary)
    }
}

// MARK: - 自己画的玻璃底、挨着的一组玻璃（2.7）

extension View {
    /// 自己画的东西的玻璃底（对话的胶囊输入框、浮动条）：iOS 26 `.glassEffect(_:in:)`，旧系统 `.regularMaterial`。
    ///
    /// - Parameters:
    ///   - shape: 玻璃的形状，默认胶囊；带引用的输入卡片用 `RoundedRectangle(cornerRadius: Metrics.Radius.composerCard)`。
    ///   - interactive: 点按时有玻璃的按压反馈（iOS 26 的 `.interactive()`），可点的东西才开。
    public func glassBackground<S: Shape>(in shape: S = Capsule(), interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            return glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            return background(.regularMaterial, in: shape)
        }
    }
}

/// 挨着的一组玻璃（筛选胶囊、输入框和旁边的圆按钮）：iOS 26 放进 `GlassEffectContainer`，挨近时融在一起、
/// 一起取样背景；旧系统原样排（材质各画各的）。
public struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    /// - Parameter spacing: 玻璃之间隔多远开始融合；nil 用系统的默认值。
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            return GlassEffectContainer(spacing: spacing) { content }
        } else {
            return content
        }
    }
}

// MARK: - 滚动边缘效果（2.10）

extension View {
    /// 不画 `edges` 上的滚动边缘效果（iOS 26 / macOS 26 内容在工具栏底下时的渐隐模糊，`scrollEdgeEffectHidden(_:for:)`）；
    /// 旧系统没有这个效果，原样返回。只给故意把内容放到工具栏那一行的页面用（连接详情的头部和 ×、… 在同一行，参考 38、52），
    /// 不然那一行的图标在工具栏底下被糊掉。
    public func hidesScrollEdgeEffect(for edges: Edge.Set) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            return scrollEdgeEffectHidden(true, for: edges)
        } else {
            return self
        }
    }
}

// MARK: - 浮动的底部条（2.7）

extension View {
    /// 浮在页面边上的条（对话的输入框、“只做一件事”的页的全宽主按钮）：iOS 26 `.safeAreaBar(edge:)`，占安全区，
    /// 滚动内容的边缘效果一起延伸到条下面；旧系统 `.safeAreaInset(edge:)`。
    public func floatingBar<Content: View>(
        edge: VerticalEdge = .bottom, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            return safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        } else {
            return safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
        }
    }
}

// MARK: - 工具栏（2.6、2.7）

/// 工具栏里的间隔：iOS 26 `ToolbarSpacer`。并排的两个圆按钮（分享和更多）中间放一个 `.fixed`，不然 iOS 26 会把它们
/// 并成一个胶囊；底部条里把两边推开用 `.flexible`。旧系统：固定的不放（工具栏项本来就分开），弹性的放一个 `Spacer()`。
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .topBarTrailing) { shareButton }
///     GlassToolbarSpacer(.fixed, placement: .topBarTrailing)
///     ToolbarItem(placement: .topBarTrailing) { moreMenu }
/// }
/// ```
public struct GlassToolbarSpacer: ToolbarContent {
    public enum Sizing: Hashable, Sendable {
        case fixed
        case flexible
    }

    private let sizing: Sizing
    private let placement: ToolbarItemPlacement

    public init(_ sizing: Sizing = .fixed, placement: ToolbarItemPlacement = .automatic) {
        self.sizing = sizing
        self.placement = placement
    }

    public var body: some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            return ToolbarSpacer(sizing == .fixed ? .fixed : .flexible, placement: placement)
        } else {
            let spacer: ToolbarItem<(), Spacer>? =
                sizing == .flexible ? ToolbarItem(placement: placement) { Spacer() } : nil
            return spacer
        }
    }
}

#if os(iOS)
    /// 把 `.searchable` 的搜索栏放到底部条里（首页底部的玻璃搜索栏，iOS 26 的 `DefaultToolbarItem(kind: .search)`）。
    /// 旧系统不放：搜索栏照旧落在导航栏下面，照样能用。和 `.searchable(text:isPresented:)` 一起用。
    public struct BottomBarSearchItem: ToolbarContent {
        public init() {}

        public var body: some ToolbarContent {
            if #available(iOS 26.0, *) {
                return DefaultToolbarItem(kind: .search, placement: .bottomBar)
            } else {
                let none: ToolbarItem<(), EmptyView>? = nil
                return none
            }
        }
    }
#endif

extension ToolbarContent {
    /// 不要 iOS 26 工具栏项共用的玻璃底（自己画了完整的底、不要外面再套一圈玻璃的东西）；旧系统本来就没有，原样。
    /// 标题胶囊（`capsuleNavigationTitle`、对话页的头像 + 名字）和首页左上的账号按钮用它：iOS 26 给非符号的标签（头像）套的是
    /// 加了内边距的胶囊（约 56×44pt），和旁边的玻璃圆对不上，所以账号按钮去掉共用的底，自己画 44pt 的玻璃圆
    /// （`glassBackground(in: Circle())`）。
    ///
    /// - Parameter hidden: false 时原样（系统决定画不画），给“有时自己画底”的帮手用（`inlineNavigationTitle(_:ownsGlass:principal:)`）。
    public func hidesSharedGlassBackground(_ hidden: Bool = true) -> some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            return sharedBackgroundVisibility(hidden ? .hidden : .automatic)
        } else {
            return self
        }
    }
}

// MARK: - 搜索时藏导航栏（规范 4.2.4）

extension View {
    /// 首页原地搜索时藏起导航栏（参考 78：顶上只有筛选胶囊）：只在 iOS 26 藏，那里搜索栏在底部条里
    /// （`BottomBarSearchItem`）；iOS 17 / 18 的搜索栏挂在导航栏下面，藏了导航栏搜索栏也没了，不藏。macOS 不藏。
    public func hidesNavigationBarWhileSearching(_ isSearching: Bool) -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                return toolbarVisibility(isSearching ? .hidden : .automatic, for: .navigationBar)
            } else {
                return self
            }
        #else
            return self
        #endif
    }
}

// MARK: - 缩放转场（iOS 18；macOS 上没有）

extension View {
    /// 缩放转场的起点（产出物里的图片缩略图、首页的头像），和目标页的 `zoomNavigationTransition` 用同一个 id、命名空间：
    /// iOS 18 `.matchedTransitionSource(id:in:)`；旧系统、macOS 不做，普通压栈。
    public func zoomTransitionSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
            if #available(iOS 18.0, *) {
                return matchedTransitionSource(id: id, in: namespace)
            } else {
                return self
            }
        #else
            return self
        #endif
    }

    /// 压栈进来的页面从起点放大（加在目标页上）：iOS 18 `.navigationTransition(.zoom(sourceID:in:))`；
    /// 旧系统、macOS 普通压栈。
    public func zoomNavigationTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
            if #available(iOS 18.0, *) {
                return navigationTransition(.zoom(sourceID: sourceID, in: namespace))
            } else {
                return self
            }
        #else
            return self
        #endif
    }
}

// MARK: - 预览

#Preview("玻璃兼容层") {
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                Button("主按钮") {}.glassButtonStyle(.prominent)
                Button("次按钮") {}.glassButtonStyle()
                Button("小胶囊") {}
                    .glassButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                GlassGroup {
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(verbatim: "给 Botin 布置一个任务")
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, Metrics.Spacing.m)
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                            .glassBackground(interactive: true)
                        Image(systemName: "arrow.up")
                            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                            .glassBackground(in: Circle(), interactive: true)
                    }
                }
            }
            .padding(Metrics.Spacing.m)
        }
        .background(Theme.paper)
        .floatingBar {
            Button("新建 Botin") {}
                .glassButtonStyle(.prominent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.Spacing.m)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { CloseButton {} }
            ToolbarItem(placement: .confirmationAction) { ConfirmButton {} }
            ToolbarItem(placement: .primaryAction) {
                Button {
                } label: {
                    Label("连接", systemImage: "square.grid.2x2")
                }
            }
            GlassToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("复制 ID", systemImage: "doc.on.doc") {}
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }
}
