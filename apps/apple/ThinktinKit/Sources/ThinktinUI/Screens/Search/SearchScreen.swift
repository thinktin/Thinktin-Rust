import SwiftUI
import ThinktinKit

/// 搜索（`.search`，WBS 12.21）：搜索框（打开就聚焦），按种类分组的结果（实例、运行、收件箱、计划、产出物），点开跳过去。
/// 只搜本机缓存，没联网也能用；联网时另拉一次计划和产出物。
struct SearchScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        SearchContent(model: SearchModel(client: client))
    }
}

private struct SearchContent: View {
    @State private var model: SearchModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: SearchModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if !model.isSearching {
                    Text(SearchText.hint(language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.Spacing.xs)
                } else if model.isEmpty {
                    EmptyStateView(
                        systemImage: "magnifyingglass", title: SearchText.noResults(model.query, language: language),
                        message: model.hasOnlineSources ? nil : SearchText.cacheOnly(language))
                } else {
                    if !model.hasOnlineSources && !model.isLoadingOnline {
                        NoticeText(text: SearchText.cacheOnly(language), tone: .muted)
                    }
                    ForEach(model.groups) { group in
                        AgentsSectionHeader(title: SearchText.groupTitle(group.kind, language: language))
                        AgentsGroup {
                            ForEach(group.results) { result in
                                if result.id != group.results.first?.id { Divider() }
                                SearchResultRow(result: result) { router.open(result.route) }
                            }
                        }
                        if group.total > group.results.count {
                            Text(SearchText.more(group.total - group.results.count, language: language))
                                .typography(.footnote)
                                .foregroundStyle(Theme.inkSecondary)
                                .padding(.horizontal, Metrics.Spacing.xs)
                        }
                    }
                }
            }
            .agentsPageLayout()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.search.title(language))
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

/// 一条结果：图标、标题（带 AI 标识的要标）、匹配到的那一段、时间。
struct SearchResultRow: View {
    let result: SearchResult
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minWidth: Metrics.Spacing.xl)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(verbatim: result.title.isEmpty ? AppRoute.search.title(language) : result.title)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let snippet = result.snippet, !snippet.isEmpty {
                        Text(verbatim: snippet)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let date = result.date {
                        Text(Formatting.relativeTime(date, language: language))
                            .typography(.caption)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    if result.isAIGenerated { AIGeneratedLabel() }
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var icon: String {
        switch result.kind {
        case .instance: "cpu"
        case .run: "list.bullet.rectangle"
        case .inbox: "tray"
        case .plan: "calendar"
        case .artifact: "doc"
        }
    }
}
