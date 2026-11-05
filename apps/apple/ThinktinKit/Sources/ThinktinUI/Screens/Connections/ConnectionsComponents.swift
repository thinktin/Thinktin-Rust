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

/// 一行（参考 36、37、40–51、101–104）：40pt 图标、名字、两行灰字，右边的小胶囊。点行（胶囊以外）看详情。
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
                            .typography(.subheadline)
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
        .padding(.vertical, Metrics.Spacing.xxs)
    }
}

/// 行上的小胶囊和详情底部的大胶囊（参考的“连接”“授权”“允许”“已连接”）。
struct ConnectionButtonView: View {
    enum Size {
        case small
        case large
    }

    let button: ConnectionButton
    let actions: ConnectionsActions
    let size: Size

    var body: some View {
        Button {
            if let action = button.action { actions.perform(action) }
        } label: {
            switch size {
            case .small:
                Text(button.title)
            case .large:
                Text(button.title)
                    .font(Font.headline)
                    .padding(.horizontal, Metrics.Spacing.m)
            }
        }
        .glassButtonStyle(button.style == .prominent ? .prominent : .regular)
        .buttonBorderShape(.capsule)
        .controlSize(size == .small ? .small : .large)
        .disabled(!button.isEnabled)
        .accessibilityLabel(Text(button.accessibilityLabel))
    }
}

/// 一组的标题（参考 36 的“为你推荐 >”：`.title3.bold()`，能点开完整列表的后面带一个小箭头；参考 40 的说明在标题下面）。
/// 放在行的位置（不用 `Section` 的 header：plain 列表的 header 会吸顶、带底色，参考没有）。
struct ConnectionSectionHeading: View {
    let title: String
    var explanation: String?
    var onMore: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let onMore {
                Button(action: onMore) {
                    HStack(spacing: Metrics.Spacing.xxs) {
                        Text(title)
                            .font(Font.title3.bold())
                            .foregroundStyle(Theme.ink)
                        Image(systemName: "chevron.right")
                            .font(Typography.subheadline.font.weight(.semibold))
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
                    .font(Font.title3.bold())
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let explanation {
                Text(explanation)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Metrics.Spacing.s)
    }
}

/// 列表行的公共修饰：plain 列表、不画分隔线、透明底。
extension View {
    func connectionListRow() -> some View {
        listRowSeparator(.hidden)
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

/// 目录、完整列表、已连接列表共用的外壳：点行弹详情（medium / large 两档的本地 sheet，参考 38、52、105–107，
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
