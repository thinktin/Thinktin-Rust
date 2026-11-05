import SwiftUI
import ThinktinKit

/// 首页（`.home`，主导航栈永远的根，WBS 12.16；规范 docs/ios-ui-redesign.md 4.2.1、6.1 A + A1，参考 01、119、120）：
///
/// - 没有标题。plain 列表，置顶的大头像在最上面，下面每行一个 Botin（`HomeInstanceRow`），最后活动新的在前
///   （`AppModel.homeContent`）；点一行压栈进它的对话（`Router.open(.conversation(id))`，顺带记成当前实例）。
/// - 左上账号头像 → 设置（sheet，`router.open(.settings)`）；右上“+” → 新建 Botin（sheet，`.adopt(agentID: nil)`）。
///   账号里还没有 Botin（第一次登录）时列表是“还没有 Botin”的空状态，按钮也打开新建表单。
///   两个都是系统工具栏的玻璃圆按钮（规范 4.2.1），头像放在玻璃圆里面。
/// - 底部：左边工作台菜单（`WorkbenchMenu`），右边搜索栏（iOS 26 在底部条里，旧系统在导航栈的导航栏下面）。
///   搜索栏激活时列表换成 Search 目录的 `SearchResultsView`（参考 78–80：顶上筛选胶囊，没输入时列出 Botin，结果是
///   “谁发给谁”的行），iOS 26 上同时藏起导航栏；`router.searchRequest` 变了（`open(.search)`、深链）就激活它。
///   macOS 没有底部条：工作台和“+”在工具栏右边，搜索栏是工具栏里的那个。
/// - 下拉刷新；回到首页时角标太久没刷新就刷新。离线、连接横幅由 `AppDestination` 放在顶部。
///
/// 列表本身（置顶的大头像、普通行、长按菜单、左滑、已隐藏的入口和空状态）在 `HomeInstanceList`（第 1 轮 A 线，参考 01、
/// 32、33、110–116、119、120）。“等你处理”提示行还没做。
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.client) private var client

    var body: some View {
        HomeContent(model: model, search: SearchModel(client: client))
    }
}

private struct HomeContent: View {
    let model: AppModel
    @State private var search: SearchModel
    @State private var isSearchPresented = false

    @Environment(\.displayLanguage) private var language

    init(model: AppModel, search: SearchModel) {
        self.model = model
        _search = State(initialValue: search)
    }

    var body: some View {
        @Bindable var search = search
        let router = model.router
        // 外面是 ZStack 不是 Group：搜索栏挂在一个不变的视图上，输入第一个字换成结果时不会丢焦点。
        ZStack {
            if isSearchPresented || search.isSearching {
                SearchResultsView(search: search)
            } else {
                HomeInstanceList(model: model)
            }
        }
        .themedGroupedBackground()
        .searchable(text: $search.query, isPresented: $isSearchPresented, prompt: Text(SearchText.prompt(language)))
        .hidesNavigationBarWhileSearching(isSearchPresented)
        .toolbar { HomeToolbar(model: model, language: language) }
        #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
        #else
            .navigationTitle(AppRoute.home.title(language))
        #endif
        .onAppear(perform: activatePendingSearch)
        .onChange(of: router.searchRequest, activatePendingSearch)
        .onChange(of: isSearchPresented) {
            // 点 × 回到首页：下次打开从“全部”开始。
            guard isSearchPresented else {
                search.filter = nil
                return
            }
            // 每次打开搜索都重读缓存（刚跑完的运行也搜得到），联网时再拉计划和产出物。
            search.loadCache()
            if !model.isOffline { Task { [search] in await search.loadOnline() } }
        }
        .task { await model.refreshBadgesIfStale() }
        .onChange(of: router.visibleRoute) {
            guard router.visibleRoute == .home else { return }
            // 从对话页回来：刚收完的回复已经进了缓存，行的预览换成它。
            model.reloadLastMessages()
            Task { await model.refreshBadgesIfStale() }
        }
    }

    /// 有没处理的搜索请求（首页出现之前来的也算）就激活搜索栏。
    ///
    /// 推迟一拍再设：iOS 26 的搜索栏在底部条里（`BottomBarSearchItem`），冷启动时首页的 `onAppear` 比底部条装好早，
    /// 从代码激活底部条里的搜索栏在同一拍里可能不生效（Apple 论坛 798018 / FB20068224 说的是 `searchFocused`，
    /// `isPresented` 有没有这个问题还没在模拟器上验，见进度文件）。绑定还是 true 时（系统没写回 false）先放下再拉起，
    /// 每次请求都是一次真的变化。
    private func activatePendingSearch() {
        let router = model.router
        guard router.hasPendingSearchRequest else { return }
        router.searchRequestHandled()
        let wasPresented = isSearchPresented
        Task { @MainActor in
            if wasPresented {
                isSearchPresented = false
                await Task.yield()
            }
            await Task.yield()
            isSearchPresented = true
        }
    }
}

/// 首页的工具栏：iOS 左上账号、右上“+”、底部工作台和搜索栏；macOS 左边账号、右边工作台和“+”。
private struct HomeToolbar: ToolbarContent {
    let model: AppModel
    let language: DisplayLanguage

    var body: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                AccountButton(model: model)
            }
            ToolbarItem(placement: .topBarTrailing) {
                adoptButton
            }
            ToolbarItem(placement: .bottomBar) {
                WorkbenchMenu(model: model)
            }
            GlassToolbarSpacer(.fixed, placement: .bottomBar)
            BottomBarSearchItem()
        #else
            ToolbarItem(placement: .navigation) {
                AccountButton(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                WorkbenchMenu(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                adoptButton
            }
        #endif
    }

    private var adoptButton: some View {
        Button {
            model.router.open(.adopt(agentID: nil))
        } label: {
            Label(AppRoute.adopt(agentID: nil).title(language), systemImage: "plus")
                .labelStyle(.iconOnly)
        }
    }
}

/// 左上的账号头像（昵称的第一个字），点了弹出设置。账号还没拉到时是系统的人像图标。iOS 26 外面是工具栏的玻璃圆
/// （和右上的“+”一样），头像用导航栏里的尺寸（`Metrics.Avatar.title`）放在里面。
private struct AccountButton: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let name = model.user?.nameForDisplay ?? ""
        Button {
            model.router.open(.settings)
        } label: {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "person.crop.circle")
                    .accessibilityHidden(true)
            } else {
                InstanceAvatar(name, size: Metrics.Avatar.title)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(AppRoute.settings.title(language)))
        .accessibilityValue(Text(verbatim: name))
    }
}

/// 首页的实例列表和它的几种状态（加载中、离线没缓存、没有实例、都隐藏了、拉取失败）。
///
/// - 最上面是置顶的大头像（`PinnedInstancesGrid`，参考 111、120），下面是普通行（参考 01、119），中间没有分区标题。
/// - 每一行（和每个置顶的头像）长按是系统菜单（`HomeInstanceMenuContent`，预览卡 `HomeInstancePreviewCard`）；
///   普通行左滑是“置顶”“隐藏”（参考 110）。
/// - 改名是系统弹窗（`HomeRenameAlert`），删除先弹列出影响的确认页（`InstanceDeleteSheet`），复制 ID 有成功的触感。
/// - 有隐藏的 Botin 时列表最底下一行灰字“已隐藏 N 个 Botin”，都隐藏了是参考 113 的空状态；两个都进“已隐藏的 Botin”页。
struct HomeInstanceList: View {
    let model: AppModel

    @State private var renaming: Instance?
    @State private var deleting: HomeDeletion?
    /// 最近一次打开删除确认页的（sheet 关掉时 `deleting` 已经是 nil，删没删成看它）。
    @State private var lastDeletion: HomeDeletion?
    @State private var isShowingHidden = false
    @State private var copies = 0

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let content = model.homeContent
        let router = model.router
        List {
            if let error = model.refreshError {
                ErrorBanner(error, onRetry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
            }
            if !content.pinned.isEmpty {
                PinnedInstancesGrid(
                    rows: content.pinned, appearances: model.appearances,
                    open: { router.open(.conversation($0)) },
                    menu: { row in menu(for: row, isPinned: true) }
                )
                .listRowInsets(HomeLayout.pinnedInsets)
                .listRowSeparator(.hidden)
                .themedPlainRow()
            }
            ForEach(content.rows) { row in
                let appearance = model.appearances.resolved(for: row.id)
                // 按钮不是 `NavigationLink`：plain 列表里的 `NavigationLink` 会画右边的 chevron，参考的行没有。
                // 进对话照样是“首页 → 对话”（`Router.open` 记成当前实例）。
                Button {
                    router.open(.conversation(row.id))
                } label: {
                    HomeInstanceRow(row: row, appearance: appearance)
                }
                .contextMenu {
                    menu(for: row, isPinned: false)
                } preview: {
                    HomeInstancePreviewCard(row: row, appearance: appearance)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    HomeInstanceSwipeButtons(isPinned: false) { perform($0, on: row) }
                }
            }
            .listRowInsets(HomeLayout.rowInsets)
            .listRowSeparator(.hidden)
            .themedPlainRow()
            if !content.hidden.isEmpty, !content.isAllHidden {
                Button {
                    isShowingHidden = true
                } label: {
                    Text(verbatim: HomeText.hiddenCount(content.hidden.count, language: language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .themedPlainRow()
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .overlay {
            if let placeholder = model.homePlaceholder { emptyState(placeholder) }
        }
        .navigationDestination(isPresented: $isShowingHidden) {
            HiddenInstancesScreen(model: model)
        }
        .modifier(HomeRenameAlert(model: model, target: $renaming))
        .sheet(
            item: $deleting, onDismiss: finishDeletion,
            content: { deletion in
                NavigationStack {
                    InstanceDeleteSheet(model: deletion.model) { deleting = nil }
                }
                .shellEnvironment(model)
                .tint(Theme.accent)
            }
        )
        .appFeedback(.success, trigger: copies)
    }

    private func menu(for row: HomeRow, isPinned: Bool) -> HomeInstanceMenuContent {
        HomeInstanceMenuContent(isPinned: isPinned, isOffline: model.isOffline) { perform($0, on: row) }
    }

    /// 长按菜单、左滑的一项。
    private func perform(_ item: HomeInstanceMenuItem, on row: HomeRow) {
        let id = row.id
        let preferences = model.instancePreferences
        switch item {
        case .profile, .newPlan:
            if let route = item.route(for: id) { model.router.open(route) }
        case .pin, .unpin:
            withAnimation { preferences.setPinned(item == .pin, for: id) }
        case .hide:
            withAnimation { preferences.setHidden(true, for: id) }
        case .rename:
            renaming = row.instance
        case .copyID:
            Pasteboard.copy(id.rawValue)
            copies += 1
        case .delete:
            let deletion = HomeDeletion(
                id: id,
                model: InstanceDetailModel(
                    client: model.client, instanceID: id, instance: row.instance, appearances: model.appearances))
            lastDeletion = deletion
            deleting = deletion
        }
    }

    /// 删除的确认页关掉了：删成了就和资料页删除一样，拿掉它的页面、刷新列表（置顶、隐藏的记录也删）。
    private func finishDeletion() {
        guard let deleted = lastDeletion, deleted.model.isDeleted else { return }
        lastDeletion = nil
        let app = model
        Task { await InstanceDetailScreen.leaveDeletedInstance(deleted.id, app: app, router: app.router) }
    }

    /// 列表空着时（`AppModel.homePlaceholder`）：第一次在拉、离线没缓存、账号里还没有 Botin（第一次登录）、都隐藏了。
    @ViewBuilder
    private func emptyState(_ placeholder: HomePlaceholder) -> some View {
        let zh = language == .chinese
        switch placeholder {
        case .loading:
            ProgressView()
        case .offlineWithoutCache:
            // 顶部的离线横幅按首页的策略写“显示的是缓存内容”，这里只说缓存是空的，不再写“离线，暂无数据”和它打架。
            ContentUnavailableView(
                zh ? "离线" : "Offline", systemImage: "wifi.slash",
                description: Text(HomeText.offlineEmptyMessage(language)))
        case .noBotins:
            // 按钮和右上的“+”一样打开新建表单。
            ContentUnavailableView {
                Label {
                    Text(HomeText.emptyTitle(language))
                } icon: {
                    BrandLogo()
                        .frame(height: Metrics.Spacing.xxxl)
                        .accessibilityHidden(true)
                }
            } description: {
                Text(HomeText.emptyMessage(language))
            } actions: {
                Button(AppRoute.adopt(agentID: nil).title(language)) {
                    model.router.open(.adopt(agentID: nil))
                }
                .glassButtonStyle(.prominent)
                .controlSize(.large)
            }
        case .allHidden:
            HomeAllHiddenView { isShowingHidden = true }
        }
    }
}

/// 都隐藏了（参考 113）：正中一个小的 `eye.slash`、一行灰字“所有 Botin 都已隐藏”，下面玻璃胶囊“显示已隐藏的 Botin”。
/// 参考的图标和字都比 `ContentUnavailableView` 的小一号，这里照参考自己排。
struct HomeAllHiddenView: View {
    let showHidden: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.s) {
            Image(systemName: "eye.slash")
                .font(Typography.title3.font)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(verbatim: HomeText.allHiddenTitle(language))
                .typography(.body)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Button(HomeText.showHidden(language)) { showHidden() }
                .glassButtonStyle()
                .buttonBorderShape(.capsule)
                .padding(.top, Metrics.Spacing.s)
        }
        .padding(Metrics.Spacing.m)
    }
}

#Preview("首页 · 浅色中文") {
    AppShell(model: AppModel(client: ShellPreviewClients.signedIn(), defaults: nil))
        .environment(\.displayLanguage, .chinese)
}

#Preview("首页 · 深色英文、没有实例") {
    AppShell(model: AppModel(client: ShellPreviewClients.empty(), defaults: nil))
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
