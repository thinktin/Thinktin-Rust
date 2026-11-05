import SwiftUI
import ThinktinKit

/// 应用详情（规范 4.8.3，参考 38、39、52、105、106、107）：目录、列表里点行弹的 medium / large sheet；`.connection(id)` 路由
/// （压栈）也是这个页面。
///
/// - 左上 ×（sheet 时）；已连接时右上“…”菜单（参考 39：红色“断开连接”；ThinkTin 自带的接入多一项“管理”，进现有的管理页）。
/// - 居中 56pt 图标、名字（`.title2.bold()`），下面一段灰字说明（参考 105、106 的长说明；左对齐）；演示数据再加一句“即将推出”。
/// - “账户”组（已连接时，参考 38、107）：群、key、电脑、保险箱条目，停用的、离线的灰字；点了进各自的页面；最后一行强调色的
///   “添加账户”。带技能的（参考 105）再列一组“技能”。
/// - 底部居中的胶囊（参考的“连接”/“已连接”）：没连时突出的“连接”“允许”“添加 …”，连上了灰掉的“已连接”，medium 档也看得到。
/// - 断开连接：ThinkTin 自带的接入弹窗说清楚去哪删、带一个去管理页的按钮（这一页不替用户一次删光）；演示数据弹“即将推出”。
struct ConnectionDetailView: View {
    let model: ConnectionsModel
    let connectionID: ConnectionID
    /// sheet 时给：左上加 ×；要打开别的页面时交给弹它的页面（先关 sheet，nil 是只关掉）。nil 是压栈的页面，直接走路由。
    var onDismiss: (@MainActor (AppRoute?) -> Void)?

    @State private var comingSoon: ConnectionID?
    @State private var confirmsDisconnect = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let detail = model.detail(connectionID, language: language)
        List {
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let detail {
                header(detail)
                if !detail.accounts.isEmpty {
                    accountsSection(detail)
                }
                if !detail.skills.isEmpty {
                    Section {
                        ForEach(detail.skills, id: \.self) { skill in
                            Label(skill, systemImage: "sparkles")
                                .foregroundStyle(Theme.ink)
                        }
                    } header: {
                        Text(ConnectionsText.skillsHeader(language)).textCase(nil)
                    }
                    .themedRow()
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if detail == nil {
                ContentUnavailableView(
                    language == .chinese ? "找不到这个应用" : "App not found", systemImage: "puzzlepiece.extension")
            }
        }
        .floatingBar(edge: .bottom) {
            if let primary = detail?.primary {
                ConnectionButtonView(button: primary, actions: actions, size: .large)
                    .disabled(primary.isEnabled && isOpenAction(primary.action) && app.isOffline)
                    .padding(.vertical, Metrics.Spacing.s)
                    .frame(maxWidth: .infinity)
            }
        }
        // 参考的详情 sheet 没有标题（头部已经有名字）。
        .hiddenInlineNavigationTitle(detail?.title ?? AppRoute.connection(connectionID).title(language))
        .toolbar {
            if onDismiss != nil {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { onDismiss?(nil) }
                }
            }
            if let detail, detail.showsMenu {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    menu(detail)
                }
            }
        }
        .alert(
            disconnectTitle(detail), isPresented: $confirmsDisconnect, presenting: detail
        ) { detail in
            if let route = detail.manageRoute, let builtIn = model.catalog.app(detail.id)?.builtIn {
                Button(ConnectionsText.goManage(builtIn, language: language)) { open(route) }
            }
            Button(language == .chinese ? "取消" : "Cancel", role: .cancel) {}
        } message: { detail in
            Text(detail.disconnectNote ?? "")
        }
        .comingSoonAlert($comingSoon, model: model)
        .refreshable { await model.load() }
        .task {
            if !model.hasLoaded { await model.load() }
        }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }

    /// 头部（参考 38、52）：图标、名字、说明。
    private func header(_ detail: ConnectionDetail) -> some View {
        Section {
            VStack(spacing: Metrics.Spacing.s) {
                ConnectionIcon(systemImage: detail.systemImage, tint: detail.tint, size: ConnectionIcon.detailSize)
                Text(detail.title)
                    .font(Font.title2.bold())
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(detail.description)
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote = detail.footnote {
                    Label(footnote, systemImage: "clock")
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.Spacing.xs)
            .clearListRow()
        }
    }

    /// “账户”组（参考 38、107）。
    private func accountsSection(_ detail: ConnectionDetail) -> some View {
        Section {
            ForEach(detail.accounts) { account in
                Button {
                    if let route = account.route { open(route) }
                } label: {
                    HStack(spacing: Metrics.Spacing.s) {
                        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                            Text(account.title)
                                .foregroundStyle(account.isDimmed ? Theme.inkSecondary : Theme.ink)
                                .lineLimit(1)
                            if let subtitle = account.subtitle {
                                Text(subtitle)
                                    .typography(.subheadline)
                                    .foregroundStyle(account.isDimmed ? Theme.inkTertiary : Theme.inkSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: Metrics.Spacing.s)
                        if account.route != nil {
                            Image(systemName: "chevron.right")
                                .font(Typography.footnote.font.weight(.semibold))
                                .foregroundStyle(Theme.inkTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(account.route == nil)
                .accessibilityElement(children: .combine)
            }
            if let add = detail.addAccount {
                Button(ConnectionsText.addAccount(language)) { actions.perform(add) }
                    .disabled(isOpenAction(add) && app.isOffline)
            }
        } header: {
            Text(ConnectionsText.accountsHeader(language)).textCase(nil)
        }
        .themedRow()
    }

    /// 右上“…”（参考 39）：管理（自带的接入）、断开连接（红字）。
    private func menu(_ detail: ConnectionDetail) -> some View {
        Menu {
            if let route = detail.manageRoute {
                Section {
                    Button(ConnectionsText.manage(language), systemImage: "gearshape") { open(route) }
                }
            }
            Button(ConnectionsText.disconnect(language), systemImage: "trash", role: .destructive) {
                if detail.disconnectNote != nil {
                    confirmsDisconnect = true
                } else {
                    comingSoon = detail.id
                }
            }
        } label: {
            Label(language == .chinese ? "更多" : "More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
    }

    private func disconnectTitle(_ detail: ConnectionDetail?) -> String {
        let name = detail?.title ?? ""
        return language == .chinese ? "断开\(name)" : "Disconnect \(name)"
    }

    private var actions: ConnectionsActions {
        ConnectionsActions(showDetail: { _ in }, perform: perform)
    }

    private func perform(_ action: ConnectionAction) {
        switch action {
        case .open(let route): open(route)
        case .comingSoon(let id): comingSoon = id
        }
    }

    /// 打开现有页面：sheet 时交给弹它的页面（先关 sheet）；压栈的页面直接走路由。
    private func open(_ route: AppRoute) {
        if let onDismiss {
            onDismiss(route)
        } else {
            router.open(route)
        }
    }

    private func isOpenAction(_ action: ConnectionAction?) -> Bool {
        if case .open = action { return true }
        return false
    }
}

/// `.connection(id)` 路由（压栈）：自己建视图模型、拉数据。
struct ConnectionDetailScreen: View {
    let connectionID: ConnectionID

    @Environment(\.client) private var client

    var body: some View {
        ConnectionDetailHolder(client: client, connectionID: connectionID)
    }
}

private struct ConnectionDetailHolder: View {
    @State private var model: ConnectionsModel
    let connectionID: ConnectionID

    init(client: any ClientProtocol, connectionID: ConnectionID) {
        _model = State(initialValue: ConnectionsModel(client: client, onPhone: ConnectionsPlatform.isPhone))
        self.connectionID = connectionID
    }

    var body: some View {
        ConnectionDetailView(model: model, connectionID: connectionID)
    }
}

/// 在不在 iPhone 上（“此 iPhone”那一类只在 iOS 上有）。
enum ConnectionsPlatform {
    static var isPhone: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }
}

#Preview("应用详情 · 已连接 · 浅色中文") {
    NavigationStack {
        ConnectionDetailScreen(connectionID: ConnectionsDemoData.modelKeysID)
    }
    .previewShell()
}

#Preview("应用详情 · 带技能 · 深色英文") {
    ConnectionDetailScreen(connectionID: ConnectionsDemoData.codeHostingID)
        .previewShell(.english, scheme: .dark)
}

#Preview("应用详情 · 没连") {
    ConnectionDetailScreen(connectionID: "help-desk").previewShell()
}
