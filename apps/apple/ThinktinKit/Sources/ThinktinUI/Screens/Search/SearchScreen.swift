import SwiftUI
import ThinktinKit

/// 搜索（`.search`，WBS 12.21）的压栈版：改版后 `.search` 回首页原地搜索（规范 4.2.4），这一页只在有人用
/// `NavigationLink(value: AppRoute.search)` 压栈时出现。内容和首页一样是 `SearchResultsView`。
struct SearchScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        SearchContent(model: SearchModel(client: client))
    }
}

private struct SearchContent: View {
    @State private var model: SearchModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: SearchModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        SearchResultsView(search: model)
            .themedGroupedBackground()
            .inlineNavigationTitle(AppRoute.search.title(language))
            .searchable(text: $model.query, prompt: Text(SearchText.prompt(language)))
            .task {
                model.loadCache()
                if !app.isOffline { await model.loadOnline() }
            }
            .onChange(of: app.isOffline) {
                if !app.isOffline { Task { await model.loadOnline() } }
            }
    }
}

/// 搜索的内容（规范 4.2.4，参考 78、79、80），首页原地搜索和压栈的搜索页共用：
///
/// - 顶上一排筛选胶囊（`FilterChipBar`：全部 / 消息 / Botin / 收件箱 / 产出物 / 计划；参考的“群聊”换成收件箱，6.24 A），
///   浮在列表上面（iOS 26 `safeAreaBar`）。
/// - 还没输入：“全部”和“Botin”直接列出 Botin（右边灰字“Botin”）；别的类正中一个小放大镜和“搜索消息”这样一句。
/// - 有结果：plain 列表、没有分隔线。“全部”按种类分组（组标题），选了一类的不分组。一行和首页的行一样排
///   （`SearchLayout`）：44pt 头像（Botin、消息）或种类图标，粗体标题（消息是“你发给 X” / “X 发给你”），右边小字时间
///   （一周内写星期几），下面一行灰色摘录。
/// - 没结果：系统的空状态；离线时只搜了缓存，说一声。
struct SearchResultsView: View {
    let search: SearchModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let search = self.search
        List {
            if search.isSearching {
                if !search.hasOnlineSources && !search.isLoadingOnline {
                    Text(SearchText.cacheOnly(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .listRowInsets(SearchLayout.noteInsets)
                        .listRowSeparator(.hidden)
                        .themedPlainRow()
                }
                if search.filter == nil {
                    ForEach(search.groups) { group in
                        Section {
                            rows(group)
                        } header: {
                            Text(SearchText.groupTitle(group.kind, language: language))
                                .textCase(nil)
                        }
                    }
                } else {
                    ForEach(search.groups) { group in
                        rows(group)
                    }
                }
            } else {
                ForEach(search.suggestions) { result in
                    row(result)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .floatingBar(edge: .top) { filterBar }
        .overlay { emptyState }
    }

    private var filterBar: some View {
        @Bindable var search = search
        return FilterChipBar(
            SearchModel.filters.map { .init(value: $0, title: SearchText.filterTitle($0, language: language)) },
            selection: $search.filter, horizontalInset: SearchLayout.chipInset
        )
        .padding(.vertical, Metrics.Spacing.xxs)
    }

    @ViewBuilder
    private func rows(_ group: SearchGroup) -> some View {
        ForEach(group.results) { result in
            row(result)
        }
        if group.total > group.results.count {
            Text(SearchText.more(group.total - group.results.count, language: language))
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .listRowInsets(SearchLayout.noteInsets)
                .listRowSeparator(.hidden)
                .themedPlainRow()
        }
    }

    private func row(_ result: SearchResult) -> some View {
        SearchResultRow(result: result, appearances: app.appearances) { router.open(result.route) }
            .listRowInsets(SearchLayout.rowInsets)
            .listRowSeparator(.hidden)
            .themedPlainRow()
    }

    @ViewBuilder
    private var emptyState: some View {
        if search.isSearching {
            if search.isEmpty {
                ContentUnavailableView(
                    SearchText.noResults(search.query, language: language), systemImage: "magnifyingglass",
                    description: search.hasOnlineSources ? nil : Text(SearchText.cacheOnly(language)))
            }
        } else if search.suggestions.isEmpty {
            // 参考 79：正中一个小放大镜和一句灰字。
            VStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(Typography.title3.font)
                    .accessibilityHidden(true)
                Text(search.filter.map { SearchText.searchKind($0, language: language) } ?? SearchText.hint(language))
                    .typography(.body)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Metrics.Spacing.xl)
            .accessibilityElement(children: .combine)
        }
    }
}

/// 搜索结果的版式：和首页的行一样（参考 78、80 量出来：44pt 头像离左边 22pt，文字从约 82pt 起，右边的小字离右边约 22pt，
/// 一行约 80pt；首页见 `HomeLayout`）。
enum SearchLayout {
    /// 一行：上下各 18pt，左 22pt、右 22pt。
    static let rowInsets = EdgeInsets(top: 18, leading: 22, bottom: 18, trailing: 22)
    /// “还有 N 条”“只搜了缓存”这种灰字：和行的文字左右对齐到同一条边，上下留得少。
    static let noteInsets = EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22)
    /// 筛选胶囊左右留白（参考 78 第一个胶囊离左边约 20pt）。
    static let chipInset = Metrics.Spacing.l
}

/// 一条结果（参考 78、80）：左边 44pt 的 Botin 头像（Botin、消息）或种类图标，和首页的行一样大；粗体标题（消息拼成
/// “你发给 X” / “X 发给你”），右边灰色小字时间（Botin 是种类标签，`.footnote`）；下面一行灰色摘录；agent 写的带 AI 生成标识。
struct SearchResultRow: View {
    let result: SearchResult
    /// Botin 的头像外观（`AppModel.appearances`）；nil 时是默认的头像。
    var appearances: InstanceAppearanceStore?
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    init(
        result: SearchResult, appearances: InstanceAppearanceStore? = nil, action: @escaping @MainActor () -> Void
    ) {
        self.result = result
        self.appearances = appearances
        self.action = action
    }

    /// 画 Botin 头像的：Botin 本身和消息（标题就是 Botin 的名字）。
    private var avatarInstance: InstanceID? {
        result.kind == .instance || result.kind == .run ? result.instanceID : nil
    }

    private var title: String {
        if let direction = result.direction {
            return SearchText.messageTitle(direction, botin: result.title, language: language)
        }
        return result.title.isEmpty ? AppRoute.search.title(language) : result.title
    }

    private var trailing: String? {
        if result.kind == .instance { return SearchText.kindLabel(.instance, language: language) }
        return result.date.map { SearchText.date($0, language: language) }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeLayout.rowSpacing) {
                leading
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                        Text(verbatim: title)
                            .typography(result.kind == .instance ? .body : .headline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: Metrics.Spacing.xs)
                        if let trailing {
                            Text(verbatim: trailing)
                                .typography(.footnote)
                                .foregroundStyle(Theme.inkTertiary)
                                .lineLimit(1)
                        }
                    }
                    if let snippet = result.snippet, !snippet.isEmpty {
                        Text(verbatim: snippet)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                    if result.isAIGenerated { AIGeneratedLabel() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var leading: some View {
        if let instanceID = avatarInstance {
            InstanceAvatar(
                result.title, appearance: appearances?.resolved(for: instanceID), size: Metrics.Avatar.list
            )
            .accessibilityHidden(true)
        } else {
            Image(systemName: icon)
                .font(Typography.title3.font)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: Metrics.Avatar.list, height: Metrics.Avatar.list)
                .background(
                    Theme.paperElevated,
                    in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                )
                .accessibilityHidden(true)
        }
    }

    private var icon: String {
        switch result.kind {
        case .instance: "person.crop.circle"
        case .run: "bubble.left"
        case .inbox: "tray"
        case .plan: "clock"
        case .artifact: "doc"
        }
    }
}
