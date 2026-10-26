import SwiftUI
import ThinktinKit

/// 用量看板（`.usage`，入口：设置、模型 key 列表、key 详情、对话页的用量按钮）：
///
/// - 时间范围：7 / 30 / 90 天（分段控件）；
/// - 总计卡片：总 token 数、请求数、失败和估算，输入 / 输出 / 缓存 / 计费分开；
/// - 按天的柱状图（Swift Charts，`UsageChart`）；
/// - 表格：按天 / 实例 / 模型 / key 分组，每行 token 数、请求数、失败、估算；实例点开去它的模型路由，key 点开去 key 详情。
///
/// 用量不缓存：离线时显示空状态（离线横幅由应用框架放）。
struct UsageScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        UsageContent(client: client)
    }
}

private struct UsageContent: View {
    @State private var model: UsageModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: UsageModel(client: client))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                PageHeader(
                    title: AppRoute.usage.title(language),
                    message: zh
                        ? "模型网关记下的 token 用量，费用由厂商按你的 key 结算。"
                        : "Token usage recorded by the model gateway; vendors bill it to your keys.")
                Picker(
                    zh ? "时间范围" : "Period",
                    selection: Binding(
                        get: { model.period },
                        set: { period in
                            model.select(period: period)
                            Task { await model.load() }
                        })
                ) {
                    ForEach(UsageModel.Period.allCases, id: \.self) { period in
                        Text(period.title(language)).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                if model.hasLoaded, let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if model.hasLoaded {
                    if model.isEmpty {
                        EmptyStateView(
                            systemImage: "chart.bar",
                            title: zh ? "这段时间还没有用量" : "No usage in this period",
                            message: zh
                                ? "agent 调模型之后，这里会按天显示 token 数。"
                                : "Once agents call models, daily token counts show up here.")
                    } else {
                        dashboard
                    }
                } else if model.isLoading || model.error == nil {
                    LoadingStateView()
                } else {
                    ModelsUnavailableView(error: model.error) { Task { await model.load() } }
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(AppRoute.usage.title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }

    @ViewBuilder
    private var dashboard: some View {
        let zh = language == .chinese
        let model = self.model
        UsageTotalCard(total: model.total, period: model.period)
        SectionHeader(title: zh ? "每天" : "Per day")
        Card {
            UsageChart(points: model.dayPoints, timeZone: model.timeZone)
            if let peak = model.peakDay {
                Text(peakText(peak))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        SectionHeader(title: zh ? "明细" : "Breakdown")
        Picker(
            zh ? "分组" : "Group by",
            selection: Binding(
                get: { model.group },
                set: { group in
                    model.select(group: group)
                    if group != .day { Task { await model.load() } }
                })
        ) {
            ForEach(UsageGroup.allCases, id: \.self) { group in
                Text(group.title(language)).tag(group)
            }
        }
        .pickerStyle(.segmented)
        if let error = visibleError(model.groupError) {
            ErrorBanner(error) { Task { await model.load() } }
        }
        let rows = model.rows(language: language)
        if rows.isEmpty {
            if model.isLoading {
                LoadingStateView()
            }
        } else {
            GroupedSection {
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider() }
                    UsageRowView(row: row, action: action(for: row))
                }
            }
        }
        ModelsFootnote(text: UsageText.footnote(language))
    }

    /// “最多的一天：10月20日，3.6 万 token”。
    private func peakText(_ peak: UsageDayPoint) -> String {
        let day = Formatting.shortDate(
            peak.date, language: language, calendar: UsageChartFormat.calendar(model.timeZone))
        let tokens = Formatting.tokens(peak.tokens, language: language)
        return language == .chinese ? "最多的一天：\(day)，\(tokens) token" : "Busiest day: \(day), \(tokens) tokens"
    }

    /// 表格一行点开去哪（实例 → 模型路由，key → key 详情）；按天、按模型的不能点。
    private func action(for row: UsageRow) -> (@MainActor () -> Void)? {
        guard let route = model.destination(of: row) else { return nil }
        let router = self.router
        return { router.open(route) }
    }
}

/// 总计卡片：大号的 token 总数（衬线），请求、失败、估算一行，下面是输入、输出、缓存、计费等小格子。
struct UsageTotalCard: View {
    let total: UsageBucket
    let period: UsageModel.Period

    @Environment(\.displayLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let zh = language == .chinese
        let items = UsageText.totalItems(total, language: language)
        Card {
            Text(zh ? "最近 \(period.days) 天共用了" : "Last \(period.days) days")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
            Text(Formatting.tokens(total.totalTokens, language: language) + " tokens")
                .typography(.title)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(UsageText.requestsLine(total, language: language))
                .typography(.subheadline)
                .foregroundStyle(total.failedRequests > 0 ? StatusTone.waiting.color : Theme.inkSecondary)
            Divider()
                .padding(.vertical, Metrics.Spacing.xxs)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    ForEach(items, id: \.0) { item in stat(item) }
                }
            } else {
                VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                    HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                        ForEach(items.prefix(3), id: \.0) { item in stat(item) }
                    }
                    HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                        ForEach(items.dropFirst(3), id: \.0) { item in stat(item) }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ item: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
            Text(item.0)
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
            Text(item.1)
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 表格的一行：名字、副标题、请求和失败；右边是 token 数。能点开时整行是按钮。
struct UsageRowView: View {
    let row: UsageRow
    var action: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(row.accessibilityLabel(language)))
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(row.accessibilityLabel(language)))
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(row.title)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(row.detail(language))
                    .typography(.footnote)
                    .foregroundStyle(row.bucket.failedRequests > 0 ? StatusTone.waiting.color : Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if dynamicTypeSize.isAccessibilitySize {
                    tokens
                }
            }
            Spacer(minLength: Metrics.Spacing.xs)
            if !dynamicTypeSize.isAccessibilitySize {
                tokens
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.s)
        .frame(minHeight: Metrics.minTapTarget)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var tokens: some View {
        Text(row.tokens(language))
            .typography(.headline)
            .foregroundStyle(Theme.ink)
            .monospacedDigit()
    }
}

#Preview("用量 · 浅色中文") {
    UsageScreen().previewShell()
}

#Preview("用量 · 深色英文") {
    UsageScreen().previewShell(.english, scheme: .dark)
}

#Preview("用量 · 没有用量") {
    UsageScreen().previewShell(client: ModelsPreviewClients.noUsage())
}
