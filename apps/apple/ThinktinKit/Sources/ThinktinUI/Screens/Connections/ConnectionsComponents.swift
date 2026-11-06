import SwiftUI
import ThinktinKit

// 连接目录几页共用的：行、图标、组标题、点行弹详情 sheet、“即将推出”的弹窗（规范 4.8，参考 36–52、101–107）。

/// 应用的图标：圆角方块 + SF Symbol（规范 2.4：应用图标方块 40，详情 56）。参考的图标是各家的 Logo，ThinkTin 不用别家的
/// Logo；没有颜色的（参考里灰底的拼图）是灰底、正文色的符号。
struct ConnectionIcon: View {
    static let rowSize: CGFloat = 40
    static let detailSize: CGFloat = 56

    let systemImage: String
    let tint: ConnectionIconTint
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(tint == .neutral ? Theme.ink : Color.white)
            }
            .accessibilityHidden(true)
    }

    private var background: Color {
        switch tint {
        case .neutral: Theme.userBubble
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }
}

/// 一行（参考 36、37、40–51、101–104）：40pt 图标、名字、两行灰字（`.footnote`），右边的小胶囊。点行（胶囊以外）看详情。
/// 行的上下留白交给列表行的边距（`ConnectionsLayout`），这里不再加。
struct ConnectionRowView: View {
    let row: ConnectionRow
    let actions: ConnectionsActions

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            Button {
                actions.showDetail(row.id)
            } label: {
                HStack(spacing: Metrics.Spacing.s) {
                    ConnectionIcon(systemImage: row.systemImage, tint: row.tint, size: ConnectionIcon.rowSize)
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                        Text(row.title)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(row.subtitle)
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.accessibilityLabel))
            .accessibilityHint(Text(ConnectionsText.rowHint(language)))
            .accessibilityAddTraits(.isButton)
            if let button = row.button {
                ConnectionButtonView(button: button, actions: actions, size: .small)
            }
        }
    }
}

/// 行上的小胶囊和详情底部的大胶囊（参考的“连接”“授权”“允许”“已连接”）。
///
/// - 能点的：系统按钮 + `glassButtonStyle`。“连接”是中性色的 `.regular`，只有“允许”“添加”“配对”是强调色的 `.prominent`
///   （参考里也只有“授权”是蓝的）。小胶囊是常规大小（参考约 33pt 高）、半粗的 `.footnote`。
/// - 连上了、不能点的“已连接”：灰底胶囊、次要灰字（参考 36、37、38），不用灰掉的玻璃：浅色外观下白玻璃上的浅灰字几乎看不见，
///   深色外观下只剩一圈边（2026-11-05 截图 19、36、37）。读屏念“已连接 X”，不当按钮念。
struct ConnectionButtonView: View {
    enum Size {
        case small
        case large
    }

    let button: ConnectionButton
    let actions: ConnectionsActions
    let size: Size

    var body: some View {
        if button.isEnabled {
            Button {
                if let action = button.action { actions.perform(action) }
            } label: {
                switch size {
                case .small:
                    Text(button.title)
                        .font(Self.smallFont)
                case .large:
                    Text(button.title)
                        .font(Font.headline)
                        .padding(.horizontal, Metrics.Spacing.m)
                }
            }
            .glassButtonStyle(button.style == .prominent ? .prominent : .regular)
            .buttonBorderShape(.capsule)
            .controlSize(size == .small ? .regular : .large)
            .accessibilityLabel(Text(button.accessibilityLabel))
        } else {
            ConnectedCapsule(title: button.title, size: size)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(button.accessibilityLabel))
        }
    }

    /// 小胶囊的字（参考约 13pt 半粗）。
    static let smallFont = Typography.footnote.font.weight(.semibold)
}

/// 灰掉的“已连接”：灰底胶囊、次要灰字，大小和能点的胶囊一样（小的约 33pt 高，详情底部的约 46pt，参考 36、38）。
private struct ConnectedCapsule: View {
    let title: String
    let size: ConnectionButtonView.Size

    var body: some View {
        Text(title)
            .font(size == .small ? ConnectionButtonView.smallFont : Font.headline)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .padding(.horizontal, size == .small ? Metrics.Spacing.s : Metrics.Spacing.xxl + Metrics.Spacing.xs)
            .frame(minHeight: size == .small ? ConnectionsLayout.smallPillHeight : ConnectionsLayout.largePillHeight)
            .background(Theme.userBubble, in: Capsule())
    }
}

/// 一组的标题（参考 36、40 的组标题：和导航标题一样大的 `.headline`，能点开完整列表的后面带一个小的灰箭头；参考 40 的
/// 说明在标题下面，`.footnote` 灰字）。放在行的位置（不用 `Section` 的 header：plain 列表的 header 会吸顶、带底色，参考没有），
/// 上下留白交给 `ConnectionsLayout.headingInsets`。
struct ConnectionSectionHeading: View {
    let title: String
    var explanation: String?
    var onMore: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let onMore {
                Button(action: onMore) {
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(title)
                            .typography(.headline)
                            .foregroundStyle(Theme.ink)
                        Image(systemName: "chevron.right")
                            .font(Typography.footnote.font.weight(.semibold))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(ConnectionsText.seeAllHint(language)))
                .accessibilityAddTraits([.isHeader, .isButton])
            } else {
                Text(title)
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let explanation {
                Text(explanation)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 连接这几页的列表版式（照参考 36、37、40、101 量的，2026-11-05 截图对照）：
/// - 左右都是 22pt（参考的图标、胶囊、组标题离屏幕边约 22pt；系统 plain 列表默认 16pt）。
/// - 行里的字（名字 `.body` 约 22pt + 4 + 一行 `.footnote` 约 18pt）约 44pt 高，比 40pt 的图标高，行距按字算：
///   目录、完整列表的行上下各 13pt，一行的行距约 70pt（参考 36、101 约 69.5pt；两行灰字的约 88pt，参考约 88pt）；
///   已连接列表的行上下各 17pt，约 78pt（参考 37 约 78.5pt，比目录松）。
///   名字和灰字中间照旧 4pt（参考两行字的中心差约 23pt，2pt 就太挤了）。
/// - 组标题上 16、下 9：分类胶囊下沿到标题的字约 22pt（参考约 21pt）；标题中心到第一行的图标上沿约 35pt（参考约 35pt）；
///   上一组最后一个图标下沿到下一个标题中心约 42pt（参考 36 的“精选”约 43pt）。
enum ConnectionsLayout {
    static let horizontal: CGFloat = 22
    static let rowInsets = EdgeInsets(top: 13, leading: horizontal, bottom: 13, trailing: horizontal)
    static let installedRowInsets = EdgeInsets(top: 17, leading: horizontal, bottom: 17, trailing: horizontal)
    static let headingInsets = EdgeInsets(top: 16, leading: horizontal, bottom: 9, trailing: horizontal)
    /// 已连接列表的灰色小标题“ThinkTin 自带”：上面留得和以前一样（离导航栏和参考 37 一样远），下面贴着第一行。
    static let installedHeaderInsets = EdgeInsets(top: 27, leading: horizontal, bottom: 10, trailing: horizontal)
    /// 末尾的灰字说明。
    static let footnoteInsets = EdgeInsets(top: 20, leading: horizontal, bottom: 15, trailing: horizontal)
    /// 分类胶囊这一行顶上的留白：参考 36 的胶囊比列表的第一个内容低（导航按钮中心到胶囊中心约 76pt，以前是 61pt）。
    static let chipBarTop: CGFloat = 22
    /// 行上小胶囊的高（参考约 33pt；灰掉的“已连接”自己画，和能点的一样高）。
    static let smallPillHeight: CGFloat = 33
    /// 详情底部大胶囊的高（参考 38 约 46pt）。
    static let largePillHeight: CGFloat = 46
}

/// 列表行的公共修饰：plain 列表、不画分隔线、透明底；`insets` 给了就用它（nil 是系统默认的边距）。
extension View {
    func connectionListRow(insets: EdgeInsets? = nil) -> some View {
        listRowSeparator(.hidden)
            .listRowInsets(insets)
            .themedPlainRow()
    }
}

/// 页面交给行、详情的操作。
struct ConnectionsActions {
    /// 点行：弹详情。
    let showDetail: @MainActor (ConnectionID) -> Void
    /// 按钮：打开现有页面、弹“即将推出”。
    let perform: @MainActor (ConnectionAction) -> Void
}

/// sheet 用的包装（`ConnectionID` 不是 `Identifiable`）。
private struct SelectedConnection: Identifiable, Hashable {
    let id: ConnectionID
}

/// 目录、完整列表、已连接列表共用的外壳：点行弹详情（medium / large 两档的本地 sheet，没有拖动条，参考 38、52、105–107，
/// 和引擎详情一样）；按钮打开现有页面（`router.open`）或者弹“即将推出”。详情里点了要去别的页面时先关 sheet 再走路由
/// （sheet 还在时压栈、再弹 sheet 会被系统丢掉）。
struct ConnectionsHost<Content: View>: View {
    let model: ConnectionsModel
    @ViewBuilder let content: (ConnectionsActions) -> Content

    @State private var selected: SelectedConnection?
    @State private var comingSoon: ConnectionID?
    @State private var pendingRoute: AppRoute?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        content(ConnectionsActions(showDetail: { selected = SelectedConnection(id: $0) }, perform: perform))
            .sheet(item: $selected, onDismiss: performPending) { selection in
                NavigationStack {
                    ConnectionDetailView(model: model, connectionID: selection.id) { route in
                        pendingRoute = route
                        selected = nil
                    }
                }
                .shellEnvironment(app)
                .environment(\.displayLanguage, language)
                .tint(Theme.accent)
                .presentationDetents([.medium, .large])
                // 参考 38、52 的详情 sheet 没有拖动条（头部的图标和 ×、… 在同一行）。
                .presentationDragIndicator(.hidden)
            }
            .onSubpageRequest({ $0.connectionID }) { selected = SelectedConnection(id: $0) }
            .comingSoonAlert($comingSoon, model: model)
    }

    private func perform(_ action: ConnectionAction) {
        switch action {
        case .open(let route): router.open(route)
        case .comingSoon(let id): comingSoon = id
        }
    }

    private func performPending() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        router.open(route)
    }
}

extension View {
    /// “即将推出”（ThinkTin 还不能连的应用）：系统 alert，一个“好”。
    func comingSoonAlert(_ item: Binding<ConnectionID?>, model: ConnectionsModel) -> some View {
        modifier(ComingSoonAlert(item: item, model: model))
    }
}

private struct ComingSoonAlert: ViewModifier {
    @Binding var item: ConnectionID?
    let model: ConnectionsModel

    @Environment(\.displayLanguage) private var language

    func body(content: Content) -> some View {
        let zh = language == .chinese
        content.alert(
            ConnectionsText.comingSoonTitle(language),
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            presenting: item
        ) { _ in
            Button(zh ? "好" : "OK", role: .cancel) {}
        } message: { id in
            Text(model.comingSoonMessage(id, language: language))
        }
    }
}
