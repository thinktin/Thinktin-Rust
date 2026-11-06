import SwiftUI
import ThinktinKit

/// 连接目录（`.connections(category:)`；规范 4.8.1，参考 36、40–51）：首页左下的玻璃圆（和参考 36 一样是 large sheet，
/// 左上 × 由 `SheetStack` 加）、设置里的“连接”（压进设置 sheet 的栈）、深链（压在首页上）进来。
///
/// - 标题“连接”；右上玻璃胶囊“已连接 N 个”（参考 36，中性色的字），压栈到已连接列表。
/// - 顶上一排横向滚动的分类胶囊（`FilterChipBar`：全部、iPhone、电脑、模型、密码管理器、效率、通信……），Mac 上没有“iPhone”。
/// - “全部”：“推荐 >”“精选 >”两组（`.headline` 的标题，点了压栈到完整列表），各露出几个；选了分类是那一类的
///   一组（参考 40–51 是同一个页面换了选中的胶囊；“此 iPhone”标题下面有一段说明）。
/// - plain 列表、不画分隔线、左右 22pt（`ConnectionsLayout`）：40pt 图标、名字、两行 `.footnote` 灰字、右边小胶囊
///   （连接 / 允许 / 添加 / 已连接）；点行弹详情 sheet。
/// - 底部的搜索框“按名字或用途搜索”（`.searchable`，iOS 26 的 iPhone 上在底部）；有字时列表换成搜索结果。
/// - 列表最后一段灰字说清楚现在能连哪几样。
///
/// ThinkTin 还不能连的应用是演示数据（`ConnectionsDemoData`），按钮弹“即将推出”；电脑、IM 渠道、模型 key、保险箱是真的，
/// 按钮打开现有的页面。离线时目录照样显示，自带的那几项不放按钮（横幅由应用框架统一放）。
struct ConnectionsCatalogScreen: View {
    var category: ConnectionCategory?

    @Environment(\.client) private var client

    var body: some View {
        ConnectionsCatalogContent(client: client, category: category)
    }
}

private struct ConnectionsCatalogContent: View {
    @State private var model: ConnectionsModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, category: ConnectionCategory?) {
        _model = State(
            initialValue: ConnectionsModel(client: client, category: category, onPhone: ConnectionsPlatform.isPhone))
    }

    var body: some View {
        let model = self.model
        ConnectionsHost(model: model) { actions in
            List {
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                        .connectionListRow()
                }
                if !isSearching {
                    categoryBar
                        .connectionListRow(insets: EdgeInsets())
                }
                ForEach(model.sections(language)) { section in
                    if section.id != .search {
                        ConnectionSectionHeading(
                            title: section.title, explanation: section.explanation,
                            onMore: moreAction(section.moreRoute)
                        )
                        .connectionListRow(insets: ConnectionsLayout.headingInsets)
                    }
                    ForEach(section.rows) { row in
                        ConnectionRowView(row: row, actions: actions)
                            .connectionListRow(insets: ConnectionsLayout.rowInsets)
                    }
                }
                if !isSearching {
                    Text(ConnectionsText.catalogFootnote(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .connectionListRow(insets: ConnectionsLayout.footnoteInsets)
                }
            }
            .listStyle(.plain)
            .themedGroupedBackground()
            .overlay {
                if isSearching, model.sections(language).first?.rows.isEmpty == true {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .inlineNavigationTitle(AppRoute.connections(category: nil).title(language))
            .toolbar {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    // 拉到之前不知道几个，先只写“已连接”。
                    Button(
                        model.hasLoaded
                            ? ConnectionsText.connectedCount(model.connectedCount, language: language)
                            : ConnectionsText.connected(language)
                    ) {
                        router.open(.connectedApps)
                    }
                    // 参考 36 的“已连接 5 个”是白字：工具栏的次按钮用中性色（规范 2.2），强调色只给选中的胶囊和主按钮。
                    .neutralTint()
                }
            }
            .searchable(text: $model.query, prompt: Text(ConnectionsText.searchPrompt(language)))
            .refreshable { await model.load() }
            .task { await model.load() }
            .onChange(of: app.isOffline) {
                if !app.isOffline { Task { await model.load() } }
            }
            .onChange(of: router.visibleRoute) {
                // 从 IM 渠道、模型 key 这些页面回来时重新数一遍（可能刚加了群、key）。
                if case .connections = router.visibleRoute { Task { await model.load() } }
            }
        }
    }

    /// 组标题点开完整列表（参考 36 组标题后面的“>”）；没有完整列表的组为 nil。
    private func moreAction(_ route: AppRoute?) -> (@MainActor () -> Void)? {
        guard let route else { return nil }
        return { router.open(route) }
    }

    private var isSearching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 分类胶囊（参考 36 顶上一排，选中的高亮；“全部”是 nil）。左右和行对齐（22pt）；顶上多留一点、底下不留
    /// （参考的胶囊离导航栏远、离第一个组标题近，`ConnectionsLayout`）。
    private var categoryBar: some View {
        let options: [FilterChipBar<ConnectionCategory?>.Option] =
            [.init(value: nil, title: language == .chinese ? "全部" : "All")]
            + model.categories.map { .init(value: $0, title: $0.title(language)) }
        return FilterChipBar(options, selection: $model.category, horizontalInset: ConnectionsLayout.horizontal)
            .padding(.top, ConnectionsLayout.chipBarTop)
    }
}

#Preview("连接目录 · 浅色中文") {
    ConnectionsCatalogScreen().previewShell()
}

#Preview("连接目录 · iPhone · 深色英文") {
    ConnectionsCatalogScreen(category: .thisDevice).previewShell(.english, scheme: .dark)
}

#Preview("连接目录 · 通信") {
    ConnectionsCatalogScreen(category: .communication).previewShell()
}
