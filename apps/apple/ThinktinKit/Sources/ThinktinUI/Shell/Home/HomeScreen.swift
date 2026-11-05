import SwiftUI
import ThinktinKit

/// 首页（`.home`，主导航栈永远的根，WBS 12.16；规范 docs/ios-ui-redesign.md 4.2.1 第 0 轮的最小版、6.1 A + A1）：
///
/// - 没有标题。plain 列表，每行一个实例（`HomeInstanceRow`），最后活动新的在前（`AppModel.homeRows`）；
///   点一行压栈进它的对话（`NavigationLink(value: AppRoute.conversation(id))`，`Router` 顺带记成当前实例）。
/// - 左上账号头像 → 设置（sheet，`router.open(.settings)`）；右上“+” → 新建 Botin（sheet，`.adopt(agentID: nil)`）。
///   账号里还没有 Botin（第一次登录）时列表是“还没有 Botin”的空状态，按钮也打开新建表单。
///   两个都是系统工具栏的玻璃圆按钮（规范 4.2.1），头像放在玻璃圆里面。
/// - 底部：左边工作台菜单（`WorkbenchMenu`），右边搜索栏（iOS 26 在底部条里，旧系统在导航栈的导航栏下面）。
///   搜索栏里有字时列表换成搜索结果（`HomeSearchResults`）；`router.searchRequest` 变了（`open(.search)`、深链）就激活它。
///   macOS 没有底部条：工作台和“+”在工具栏右边，搜索栏是工具栏里的那个。
/// - 下拉刷新；回到首页时角标太久没刷新就刷新。离线、连接横幅由 `AppDestination` 放在顶部。
///
/// 置顶、隐藏、长按菜单、“等你处理”提示行、搜索的类型筛选是第 1、2 轮的（规范 7.3、7.4 的 A 线）。
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
            if search.isSearching {
                HomeSearchResults(search: search)
            } else {
                HomeInstanceList(model: model)
            }
        }
        .themedGroupedBackground()
        .searchable(text: $search.query, isPresented: $isSearchPresented, prompt: Text(SearchText.prompt(language)))
        .toolbar { HomeToolbar(model: model, language: language) }
        #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
        #else
            .navigationTitle(AppRoute.home.title(language))
        #endif
        .onAppear(perform: activatePendingSearch)
        .onChange(of: router.searchRequest, activatePendingSearch)
        .onChange(of: isSearchPresented) {
            guard isSearchPresented else { return }
            // 每次打开搜索都重读缓存（刚跑完的运行也搜得到），联网时再拉计划和产出物。
            search.loadCache()
            if !model.isOffline { Task { [search] in await search.loadOnline() } }
        }
        .task { await model.refreshBadgesIfStale() }
        .onChange(of: router.visibleRoute) {
            if router.visibleRoute == .home { Task { await model.refreshBadgesIfStale() } }
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

/// 首页的实例列表和它的几种状态（加载中、离线没缓存、没有实例、拉取失败）。
struct HomeInstanceList: View {
    let model: AppModel

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let rows = model.homeRows
        List {
            if let error = model.refreshError {
                ErrorBanner(error, onRetry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
            }
            ForEach(rows) { row in
                NavigationLink(value: AppRoute.conversation(row.id)) {
                    HomeInstanceRow(row: row)
                }
            }
            .listRowSeparator(.hidden)
            .themedPlainRow()
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .overlay {
            if let placeholder = model.homePlaceholder { emptyState(placeholder) }
        }
    }

    /// 列表空着时（`AppModel.homePlaceholder`）：第一次在拉、离线没缓存、账号里还没有 Botin（第一次登录）。
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
        }
    }
}

/// 首页的搜索结果（第 0 轮的最小版：按种类分组；规范 4.2.4 的“谁发给谁”和类型筛选是第 1、2 轮的，
/// 那时换成 Search 目录拆出来的 `SearchResultsView`）。点一条跳过去（`router.open`）。
struct HomeSearchResults: View {
    let search: SearchModel

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        List {
            if !search.hasOnlineSources && !search.isLoadingOnline {
                Text(SearchText.cacheOnly(language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
            }
            ForEach(search.groups) { group in
                // plain、没有分隔线（规范 2.5），行底透明（`themedPlainRow()`）。
                Section {
                    ForEach(group.results) { result in
                        SearchResultRow(result: result) { router.open(result.route) }
                            .listRowInsets(EdgeInsets())
                    }
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
                    if group.total > group.results.count {
                        Text(SearchText.more(group.total - group.results.count, language: language))
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .listRowSeparator(.hidden)
                            .themedPlainRow()
                    }
                } header: {
                    Text(SearchText.groupTitle(group.kind, language: language))
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if search.isEmpty {
                ContentUnavailableView(
                    SearchText.noResults(search.query, language: language), systemImage: "magnifyingglass",
                    description: search.hasOnlineSources ? nil : Text(SearchText.cacheOnly(language)))
            }
        }
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
