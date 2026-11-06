import SwiftUI
import ThinktinKit

/// 收件箱（`.inbox`，推送、深链、小组件进来，WBS 12.8）。参考里没有这一页，照首页的消息列表排（规范 2.5、1.3）：
///
/// - 压栈页，inline 标题“收件箱”；plain 列表、不画分隔线，一行和首页的行一样两行：44pt 的种类图标（未读的右上角一个
///   强调色圆点）、标题（未读的加粗）和右边的时间，下面一行灰色正文和 AI 生成标识。最新的在前，滚到底往下翻。
/// - 点一条标已读、去它对应的页面（和推送同一套规则），没有更具体的页面时打开这条通知自己。
/// - 左滑：删除（红）、标已读 / 未读；长按是同样的系统菜单。右上玻璃圆“全部已读”（只有图标，`envelope.open`）。
/// - 空的时候 `ContentUnavailableView`。
///
/// 离线策略是“有缓存”：标已读离线也行，标未读、删除要联网。
struct InboxScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        InboxContent(model: InboxModel(client: client))
    }
}

/// 收件箱一行的尺寸：照首页的行（`HomeLayout`：上下 18、左 22、右 24，44pt 头像，头像和文字之间 16；规范 7.3 说收件箱照首页排）。
enum InboxLayout {
    static let rowInsets = HomeLayout.rowInsets
    static let rowSpacing = HomeLayout.rowSpacing
    static let iconSize = Metrics.Avatar.list
    /// 未读圆点（图标右上角）的直径。
    static let unreadDot: CGFloat = 12
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
        List {
            if let error = visibleError(model.error) {
                ErrorBanner(error) { Task { await model.load() } }
                    .clearListRow()
                    .padding(.horizontal, Metrics.Spacing.m)
            }
            if let error = model.actionError {
                ErrorBanner(error, onDismiss: { model.clearActionError() })
                    .clearListRow()
                    .padding(.horizontal, Metrics.Spacing.m)
            }
            if model.hasLoaded, model.unread > 0 {
                Text(InboxText.unreadCount(model.unread, language: language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: Metrics.Spacing.xs, leading: 22, bottom: 0, trailing: 24))
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
            }
            ForEach(model.items) { item in
                InboxRow(
                    item: item, isBusy: model.working.contains(item.id), canWrite: !app.isOffline,
                    onOpen: { open(item) },
                    onToggleRead: { toggleRead(item) },
                    onDelete: { Task { await model.delete(item) } }
                )
                .listRowInsets(InboxLayout.rowInsets)
                .listRowSeparator(.hidden)
                .themedPlainRow()
                .onAppear {
                    if item.id == model.items.last?.id { Task { await model.loadOlder() } }
                }
            }
            if model.isLoadingOlder {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
                    .accessibilityLabel(Text(InboxText.loadingOlder(language)))
            }
        }
        .listStyle(.plain)
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(AppRoute.inbox.title(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                // 参考的导航栏只有图标的玻璃圆（文字胶囊只给表单的“完成”），所以只放图标；读屏念“全部已读”。
                Button {
                    Task { await model.markAllRead() }
                } label: {
                    Label(InboxText.markAllRead(language), systemImage: "envelope.open")
                        .labelStyle(.iconOnly)
                }
                .neutralTint()
                .disabled(model.unread == 0 && model.items.allSatisfy { $0.isRead })
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

    @ViewBuilder
    private var placeholder: some View {
        if model.items.isEmpty {
            if model.hasLoaded {
                ContentUnavailableView {
                    Label(InboxText.emptyTitle(language), systemImage: "tray")
                } description: {
                    Text(InboxText.emptyMessage(language))
                }
            } else if visibleError(model.error) == nil {
                ProgressView()
            }
        }
    }

    private func toggleRead(_ item: InboxItem) {
        Task {
            if item.isRead {
                await model.markUnread(item)
            } else {
                await model.markRead(item)
            }
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

/// 收件箱的一行（和首页的行一样两行，2026-11-05 截图审查）：44pt 种类图标，垂直居中，未读的右上角一个强调色圆点
/// （不放在标题前面，标题都从同一个 x 起）；第一行标题、右边时间；第二行灰色正文和 AI 生成标识。种类不再单写一行
/// （标题已经说了，比如“等你审批”）。按钮本身是整行，左滑和长按菜单都在这里（标已读离线也行；标未读、删除要联网）。
struct InboxRow: View {
    let item: InboxItem
    let isBusy: Bool
    let canWrite: Bool
    let onOpen: () -> Void
    let onToggleRead: () -> Void
    let onDelete: () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: InboxLayout.rowSpacing) {
                InboxKindIcon(kind: item.kind)
                    .overlay(alignment: .topTrailing) {
                        if !item.isRead {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: InboxLayout.unreadDot, height: InboxLayout.unreadDot)
                                // 和头像的角标一样一圈底色，把圆点和图标分开（plain 列表的行是透明的，底下是 `paper`）。
                                .padding(InstanceAvatar.badgeRing(size: InboxLayout.iconSize))
                                .background(Theme.paper, in: Circle())
                                .offset(x: 2, y: -2)
                                .accessibilityLabel(Text(InboxText.unread(language)))
                        }
                    }
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                        Text(verbatim: item.title)
                            .typography(item.isRead ? .body : .headline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: Metrics.Spacing.xs)
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(Formatting.relativeTime(item.createdAt, language: language))
                                .typography(.caption)
                                .foregroundStyle(Theme.inkTertiary)
                                .lineLimit(1)
                        }
                    }
                    if !item.body.isEmpty || item.isAIGenerated {
                        HStack(spacing: Metrics.Spacing.xs) {
                            if !item.body.isEmpty {
                                Text(verbatim: item.body)
                                    .typography(.subheadline)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                            }
                            if item.isAIGenerated {
                                AIGeneratedLabel()
                                    .fixedSize()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(InboxText.delete(language), systemImage: "trash")
            }
            .disabled(!canWrite || isBusy)
            toggleReadButton
                .tint(item.isRead ? StatusTone.muted.color : Theme.accent)
        }
        .contextMenu {
            Section { toggleReadButton }
            Section {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(InboxText.delete(language), systemImage: "trash")
                }
                .disabled(!canWrite || isBusy)
            }
        }
    }

    private var toggleReadButton: some View {
        Button {
            onToggleRead()
        } label: {
            if item.isRead {
                Label(InboxText.markUnread(language), systemImage: "envelope.badge")
            } else {
                Label(InboxText.markRead(language), systemImage: "envelope.open")
            }
        }
        .disabled((item.isRead && !canWrite) || isBusy)
    }
}

/// 条目种类的图标：圆底，默认 44pt（和首页的头像一样大）。
struct InboxKindIcon: View {
    let kind: InboxKind
    var size: CGFloat = InboxLayout.iconSize

    var body: some View {
        Image(systemName: Self.systemImage(kind))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Self.tint(kind))
            .frame(width: size, height: size)
            .background(Self.tint(kind).opacity(0.14), in: Circle())
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

/// 收件箱里的一条（`.inboxItem(id)`：推送、深链、收件箱里没有更具体页面的条目进来）。照 Botin 资料页排（规范 2.5）：
/// 居中的头部（56pt 种类图标、种类、时间），一组标题和全文（AI 生成标识），有对应页面时一行“查看…”；
/// 右上 `ellipsis` 菜单标回未读、删除（删了退回去）。打开就标已读。
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
        List {
            if let item = model.item, !model.isMissing {
                if let error = model.actionError {
                    Section {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                            .clearListRow()
                    }
                }
                InboxItemCard(item: item)
                if let target = item.target {
                    Section {
                        Button {
                            router.open(target)
                        } label: {
                            Label(InboxText.open(target, language: language), systemImage: "arrow.right.circle")
                        }
                    }
                    .themedRow()
                }
            } else if !model.isMissing, let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.isMissing {
                ContentUnavailableView {
                    Label(InboxText.missingTitle(language), systemImage: "questionmark.circle")
                } description: {
                    Text(InboxText.missingMessage(language))
                }
            } else if model.item == nil, visibleError(model.error) == nil {
                ProgressView()
            }
        }
        .inlineNavigationTitle(AppRoute.inboxItem(model.itemID).title(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                if let item = model.item, !model.isMissing {
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
                        Label(language == .chinese ? "更多操作" : "More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(app.isOffline || model.isWorking)
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

/// 一条通知的全文，是 `List` 里的两组：居中的头部（种类图标、种类、时间）和一组标题 + 全文。
struct InboxItemCard: View {
    let item: InboxItem

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Section {
            VStack(spacing: Metrics.Spacing.xs) {
                InboxKindIcon(kind: item.kind, size: 56)
                Text(InboxText.kind(item.kind, language: language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                Text(Formatting.dateTime(item.createdAt, language: language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.Spacing.s)
            .clearListRow()
            .accessibilityElement(children: .combine)
        }
        Section {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
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
            .padding(.vertical, Metrics.Spacing.xxs)
        }
        .themedRow()
    }
}
