import SwiftUI
import ThinktinKit

/// 收件箱（`.inbox`，抽屉里的“收件箱”，WBS 12.8）：最新的在前，未读的带小圆点、标题加粗；agent 写的正文带 AI 生成标识。
/// 点一条标已读、去它对应的页面（和推送同一套规则），没有更具体的页面时打开这条通知自己。每行的“更多”和长按菜单里
/// 标已读 / 未读、删除；右上角“全部已读”。滚到底往下翻。离线策略是“有缓存”：标已读离线也行，标未读、删除要联网。
struct InboxScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        InboxContent(model: InboxModel(client: client))
    }
}

private struct InboxContent: View {
    @State private var model: InboxModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: InboxModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                AgentsPageHeader(
                    title: AppRoute.inbox.title(language),
                    message: model.hasLoaded ? InboxText.unreadCount(model.unread, language: language) : nil)
                if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let error = model.actionError {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                }
                if model.items.isEmpty {
                    if model.hasLoaded {
                        EmptyStateView(
                            systemImage: "tray", title: InboxText.emptyTitle(language),
                            message: InboxText.emptyMessage(language))
                    } else {
                        AgentsLoadingView()
                    }
                } else {
                    AgentsGroup {
                        ForEach(model.items) { item in
                            if item.id != model.items.first?.id { Divider() }
                            InboxRow(
                                item: item, isBusy: model.working.contains(item.id), canWrite: !app.isOffline,
                                onOpen: { open(item) },
                                onToggleRead: {
                                    Task {
                                        if item.isRead {
                                            await model.markUnread(item)
                                        } else {
                                            await model.markRead(item)
                                        }
                                    }
                                },
                                onDelete: { Task { await model.delete(item) } }
                            )
                            .onAppear {
                                if item.id == model.items.last?.id { Task { await model.loadOlder() } }
                            }
                        }
                    }
                    if model.isLoadingOlder {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Text(InboxText.loadingOlder(language)))
                    }
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.inbox.title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.markAllRead() }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(model.unread == 0 && model.items.allSatisfy { $0.isRead })
                .accessibilityLabel(Text(InboxText.markAllRead(language)))
            }
        }
        .refreshable { await model.load() }
        // 每次回到这一页都重新同步（看过的那一条、别的设备上读过的）。
        .task { await model.load() }
        .onChange(of: model.unread) { app.inboxUnreadChanged(model.unread) }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }

    /// 点一条：标已读，去对应的页面；没有就打开这条通知自己。
    private func open(_ item: InboxItem) {
        if let target = item.target {
            Task { await model.markRead(item) }
            router.open(target)
        } else {
            router.open(.inboxItem(item.id))
        }
    }
}

/// 收件箱的一行：种类图标、未读圆点、标题、正文前两行（AI 生成标识）、种类和时间；右边“更多”。
struct InboxRow: View {
    let item: InboxItem
    let isBusy: Bool
    let canWrite: Bool
    let onOpen: () -> Void
    let onToggleRead: () -> Void
    let onDelete: () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Spacing.xs) {
            Button {
                onOpen()
            } label: {
                HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                    InboxKindIcon(kind: item.kind)
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                            if !item.isRead {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel(Text(InboxText.unread(language)))
                            }
                            Text(verbatim: item.title)
                                .typography(item.isRead ? .body : .headline)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                        }
                        if !item.body.isEmpty {
                            Text(verbatim: item.body)
                                .typography(.subheadline)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(2)
                        }
                        HStack(spacing: Metrics.Spacing.xs) {
                            Text(InboxText.kind(item.kind, language: language))
                            Text(Formatting.relativeTime(item.createdAt, language: language))
                            if item.isAIGenerated { AIGeneratedLabel() }
                        }
                        .typography(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .contextMenu { menuItems }
            if isBusy {
                ProgressView()
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            } else {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(
                    Text(language == .chinese ? "“\(item.title)”的更多操作" : "More for “\(item.title)”"))
            }
        }
        .padding(.leading, Metrics.Spacing.m)
        .padding(.trailing, Metrics.Spacing.xxs)
        .padding(.vertical, Metrics.Spacing.s)
    }

    /// 标已读离线也行；标未读、删除要联网。
    @ViewBuilder
    private var menuItems: some View {
        Button {
            onToggleRead()
        } label: {
            if item.isRead {
                Label(InboxText.markUnread(language), systemImage: "envelope.badge")
            } else {
                Label(InboxText.markRead(language), systemImage: "envelope.open")
            }
        }
        .disabled(item.isRead && !canWrite)
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label(InboxText.delete(language), systemImage: "trash")
        }
        .disabled(!canWrite)
    }
}

/// 条目种类的图标（圆底）。
struct InboxKindIcon: View {
    let kind: InboxKind

    var body: some View {
        Image(systemName: Self.systemImage(kind))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Self.tint(kind))
            .frame(width: 32, height: 32)
            .background(Self.tint(kind).opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    static func systemImage(_ kind: InboxKind) -> String {
        switch kind {
        case .runFinished: "checkmark.circle"
        case .runFailed: "exclamationmark.triangle"
        case .approval: "hand.raised"
        case .computerApproval: "desktopcomputer"
        case .vaultRequest: "key"
        case .planConfirm: "calendar.badge.exclamationmark"
        case .info, .unknown: "bell"
        }
    }

    static func tint(_ kind: InboxKind) -> Color {
        switch kind {
        case .runFinished: Theme.success
        case .runFailed: Theme.danger
        case .approval, .computerApproval, .vaultRequest, .planConfirm: Theme.warning
        case .info, .unknown: Theme.inkSecondary
        }
    }
}

/// 收件箱里的一条（`.inboxItem(id)`：推送、深链、收件箱里没有更具体页面的条目进来）：标题、全文、时间，打开就标已读；
/// 有对应的页面时给“查看”按钮；右上角标回未读、删除（删了退回去）。
struct InboxItemScreen: View {
    let itemID: InboxItemID

    @Environment(\.client) private var client

    var body: some View {
        InboxItemContent(model: InboxItemModel(client: client, itemID: itemID))
    }
}

private struct InboxItemContent: View {
    @State private var model: InboxItemModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: InboxItemModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.circle", title: InboxText.missingTitle(language),
                        message: InboxText.missingMessage(language))
                } else if let item = model.item {
                    if let error = model.actionError {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                    }
                    InboxItemCard(item: item)
                    if let target = item.target {
                        PillButton(InboxText.open(target, language: language), systemImage: "arrow.right") {
                            router.open(target)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                } else {
                    AgentsLoadingView()
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.inboxItem(model.itemID).title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let item = model.item {
                    Menu {
                        if item.isRead {
                            Button {
                                Task { await model.markUnread() }
                            } label: {
                                Label(InboxText.markUnread(language), systemImage: "envelope.badge")
                            }
                        }
                        Button(role: .destructive) {
                            Task { await model.delete() }
                        } label: {
                            Label(InboxText.delete(language), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(app.isOffline || model.isWorking)
                    .accessibilityLabel(Text(language == .chinese ? "更多操作" : "More"))
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: model.unread) {
            if let unread = model.unread { app.inboxUnreadChanged(unread) }
        }
        .onChange(of: model.isDeleted) {
            if model.isDeleted {
                Task { await app.refreshBadges() }
                router.pop()
            }
        }
    }
}

/// 一条通知的全文。
struct InboxItemCard: View {
    let item: InboxItem

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Card {
            HStack(spacing: Metrics.Spacing.s) {
                InboxKindIcon(kind: item.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(InboxText.kind(item.kind, language: language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                    Text(Formatting.dateTime(item.createdAt, language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Text(verbatim: item.title)
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !item.body.isEmpty {
                Text(verbatim: item.body)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.isAIGenerated { AIGeneratedLabel() }
        }
    }
}
