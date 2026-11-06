import SwiftUI
import ThinktinKit

/// 首页（`.home`，主导航栈永远的根，WBS 12.16；规范 docs/ios-ui-redesign.md 4.2.1、6.1 A + A1，参考 01、119、120）：
///
/// - 没有标题。plain 列表，置顶的大头像在最上面，下面每行一个 Botin（`HomeInstanceRow`），最后活动新的在前
///   （`AppModel.homeContent`）；点一行压栈进它的对话（`Router.open(.conversation(id))`，顺带记成当前实例）。
/// - 左上账号头像 → 设置（sheet，`router.open(.settings)`）；右上“+” → 新建 Botin（sheet，`.adopt(agentID: nil)`）。
///   账号里还没有 Botin（第一次登录）时列表是“还没有 Botin”的空状态，按钮也打开新建表单。
///   两个都是 44pt 的玻璃圆（规范 4.2.1）。iOS 26 上两个都自己画在顶上的 `HomeTopBar` 里（导航栏藏起来），离左右边
///   都是 `HomeLayout.edge`，和下面列表的头像、时间对齐（用户 2026-11-06：左上头像和右边“+”不对称、列表头像没和
///   左上角对齐——系统工具栏给自己画的头像那一项多加了一圈边距）。iOS 17 / 18 的搜索栏挂在导航栏下面，导航栏不能藏，
///   还是工具栏里的两项。
/// - 底部：左边工作台菜单（`WorkbenchMenu`），右边搜索栏（iOS 26 在底部条里，旧系统在导航栈的导航栏下面）。
///   搜索栏激活时列表换成 Search 目录的 `SearchResultsView`（参考 78–80：顶上筛选胶囊，没输入时列出 Botin，结果是
///   “谁发给谁”的行），iOS 26 上同时藏起导航栏；`router.searchRequest` 变了（`open(.search)`、深链）就激活它。
///   macOS 没有底部条：工作台和“+”在工具栏右边，搜索栏是工具栏里的那个。
/// - 下拉刷新；回到首页时角标太久没刷新就刷新。离线、连接横幅由 `AppDestination` 放在顶部。
///
/// 列表本身（“等你处理”提示行、置顶的大头像、普通行、长按菜单、左滑、已隐藏的入口和空状态）在 `HomeInstanceList`
/// （第 1 轮 A 线，参考 01、32、33、110–116、119、120）。
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
        .toolbar {
            HomeToolbar(
                model: model, workbenchBadge: model.badges.workbenchTotal, language: language,
                topItemsInToolbar: !HomeTopBar.isAvailable)
        }
        .homeTopBar(model: model, isHidden: isSearchPresented)
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
///
/// 工作台的角标加在 `ToolbarItem` 上（`toolbarItemBadge` 现在原样返回，角标由按钮的 `toolbarBadge` 叠），数由首页的 `body` 读好传进来，
/// 角标跟着 `model.badges` 变。
private struct HomeToolbar: ToolbarContent {
    let model: AppModel
    let workbenchBadge: Int
    let language: DisplayLanguage
    /// 顶上两项放不放工具栏：iOS 26 放在 `HomeTopBar` 里（false），iOS 17 / 18 放工具栏（true）。
    var topItemsInToolbar = true

    var body: some ToolbarContent {
        #if os(iOS)
            if topItemsInToolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountButton(model: model)
                }
                // 玻璃圆是 `AccountButton` 自己画的，不要工具栏再套一层胶囊。
                .hidesSharedGlassBackground()
            }
            if topItemsInToolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    adoptButton
                }
            }
            ToolbarItem(placement: .bottomBar) {
                WorkbenchMenu(model: model)
            }
            .toolbarItemBadge(workbenchBadge)
            GlassToolbarSpacer(.fixed, placement: .bottomBar)
            BottomBarSearchItem()
        #else
            ToolbarItem(placement: .navigation) {
                AccountButton(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                WorkbenchMenu(model: model)
            }
            .toolbarItemBadge(workbenchBadge)
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

/// iOS 26 首页顶上的一条：左边账号头像、右边“+”，两个 44pt 玻璃圆，离左右边都是 `HomeLayout.edge`（和列表的头像、
/// 时间对齐，左右对称）。用安全区的条（`floatingBar(edge: .top)`，iOS 26 是 `safeAreaBar`，列表滚到它底下有系统的
/// 滚动边缘效果），导航栏藏起来，所以不会再被工具栏多加一圈边距。搜索时藏起来（搜索结果顶上是筛选胶囊）。
struct HomeTopBar: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    /// 只在 iOS 26 用：旧系统的搜索栏挂在导航栏下面，导航栏不能藏。
    static var isAvailable: Bool {
        #if os(iOS)
            if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    var body: some View {
        HStack {
            AccountButton(model: model)
                .buttonStyle(.plain)
            Spacer(minLength: Metrics.Spacing.m)
            Button {
                model.router.open(.adopt(agentID: nil))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .glassBackground(in: Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(AppRoute.adopt(agentID: nil).title(language)))
        }
        .padding(.horizontal, HomeLayout.edge)
        .padding(.vertical, Metrics.Spacing.xxs)
    }
}

extension View {
    /// iOS 26：藏起首页的导航栏，顶上放 `HomeTopBar`；`isHidden`（搜索时）不放。别的系统原样。
    @ViewBuilder
    fileprivate func homeTopBar(model: AppModel, isHidden: Bool) -> some View {
        #if os(iOS)
            if HomeTopBar.isAvailable {
                self
                    .toolbar(.hidden, for: .navigationBar)
                    .floatingBar(edge: .top, spacing: 0) {
                        if !isHidden { HomeTopBar(model: model) }
                    }
            } else {
                self
            }
        #else
            self
        #endif
    }
}

/// 左上的账号头像（昵称的第一个字），点了弹出设置。和设置里的账号行一样是中性灰的首字头像（不是 Botin 那种彩色的），
/// 账号还没拉到时是人像。
///
/// iOS：44pt 的玻璃圆，36pt 的头像几乎填满（`Metrics.Avatar.account`，参考 01、119），和右上的“+”一样大。玻璃圆自己画
/// （`glassBackground(in: Circle())`，iOS 17 / 18 是材质）：iOS 26 给非符号的标签套的是加了内边距的胶囊（约 56×44pt），
/// 所以 `HomeToolbar` 去掉了这一项共用的玻璃底。和系统工具栏的按钮一样不跟动态字体变大。
/// macOS：工具栏里一个导航栏尺寸的头像（`Metrics.Avatar.title`）。
private struct AccountButton: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let name = model.user?.nameForDisplay ?? ""
        Button {
            model.router.open(.settings)
        } label: {
            #if os(iOS)
                AccountAvatar(name, size: Metrics.Avatar.account)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .glassBackground(in: Circle(), interactive: true)
                    .contentShape(Circle())
                    .dynamicTypeSize(.large)
            #else
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "person.crop.circle")
                        .accessibilityHidden(true)
                } else {
                    AccountAvatar(name, size: Metrics.Avatar.title)
                }
            #endif
        }
        .accessibilityLabel(Text(AppRoute.settings.title(language)))
        .accessibilityValue(Text(verbatim: name))
    }
}

/// 首页的实例列表和它的几种状态（加载中、离线没缓存、没有实例、都隐藏了、拉取失败）。
///
/// - 有待审批或未读时最上面一行“等你处理”的胶囊（`HomeAttentionRow`，规范 4.2.1、6.1 A1），点了进审批中心或收件箱。
/// - 再下面是置顶的大头像（`PinnedInstancesGrid`，参考 111、120），下面是普通行（参考 01、119），中间没有分区标题。
/// - 每一行（和每个置顶的头像）长按是系统菜单（`HomeInstanceMenuContent`，预览卡 `HomeInstancePreviewCard`）；
///   普通行左滑是“置顶”“隐藏”（参考 110）。
/// - 改名是系统弹窗（`HomeRenameAlert`），删除先弹列出影响的确认页（`InstanceDeleteSheet`），复制 ID 有成功的触感。
/// - 有隐藏的 Botin 时列表最底下一行灰字“已隐藏 N 个 Botin”，都隐藏了是参考 113 的空状态；两个都进“已隐藏的 Botin”页。
struct HomeInstanceList: View {
    let model: AppModel

    @State private var renaming: Instance?
    @State private var renameText = ""
    @State private var deleting: HomeDeletion?
    /// 最近一次打开删除确认页的（sheet 关掉时 `deleting` 已经是 nil，删没删成看它）。
    @State private var lastDeletion: HomeDeletion?
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
            if let hint = model.homeAttentionHint {
                HomeAttentionRow(hint: hint) { router.openTopLevel(hint.route) }
                    .listRowInsets(HomeLayout.hintInsets)
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
            }
            if !content.pinned.isEmpty {
                PinnedInstancesGrid(
                    rows: content.pinned, appearances: model.appearances, primaryID: model.local.primary.primaryID,
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
                    HomeInstanceRow(
                        row: row, appearance: appearance, isPrimary: model.local.primary.isPrimary(row.id))
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
                    router.open(.hiddenBotins)
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
        .modifier(HomeRenameAlert(model: model, target: $renaming, name: $renameText))
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
            renameText = row.instance.name
            renaming = row.instance
        case .copyID:
            Pasteboard.copy(id.rawValue)
            copies += 1
        case .delete:
            let deletion = HomeDeletion(
                id: id,
                model: InstanceDetailModel(
                    client: model.client, instanceID: id, instance: row.instance, local: model.local))
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
            HomeAllHiddenView { model.router.open(.hiddenBotins) }
        }
    }
}

/// 都隐藏了（参考 113）：正中一个小的 `eye.slash`（`.body` 大小，约 19pt）、一行灰字“Botin 都藏起来了”，下面玻璃胶囊
/// “查看藏起来的 Botin”（medium 的 `.subheadline`，比系统按钮的字小一号）。参考的图标和字都比 `ContentUnavailableView`
/// 的小一号，这里照参考自己排；文案是 ThinkTin 自己的（`HomeText`）。
struct HomeAllHiddenView: View {
    let showHidden: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.s) {
            Image(systemName: "eye.slash")
                .font(Typography.body.font)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(verbatim: HomeText.allHiddenTitle(language))
                .typography(.body)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Button(HomeText.showHidden(language)) { showHidden() }
                .font(Typography.subheadline.font.weight(.medium))
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
