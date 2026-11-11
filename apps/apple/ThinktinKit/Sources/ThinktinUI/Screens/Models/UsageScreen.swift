import SwiftUI
import ThinktinKit

/// 用量看板（`.usage`，入口：设置、模型 key 列表、key 详情、对话页的用量按钮）。改版照参考 55（规范 4.9.3）：insetGrouped `List`，
///
/// - 最上面一组（参考 55 没有分组标题）：每把设了每日上限的 key 一行（名字、右边“今天 已用 / 上限”、系统的细进度条、
///   下面百分比），没有上限的 key 不列，一把都没有时这组不显示；
/// - 时间范围：7 / 30 / 90 天（系统分段控件，透明行）；
/// - 总计：总 token 数、请求数、失败和估算，输入 / 输出 / 缓存 / 计费分开；
/// - “每天”：按天的柱状图（Swift Charts，`UsageChart`）和最多的一天；
/// - “明细”：按天 / Botin / 模型 / key 分组（分段控件），每行 token 数、请求数、失败、估算；Botin 点开去它的模型路由，key 点开去
///   key 详情（系统 `NavigationLink`，压进眼前这层的栈）。
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
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: UsageModel(client: client))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        List {
            if !model.todayGauges.isEmpty {
                Section {
                    ForEach(model.todayGauges) { gauge in
                        UsageGaugeRow(gauge: gauge)
                    }
                } footer: {
                    Text(UsageToday.sectionFooter(language)).settingsGroupFooter()
                }
                .themedRow()
            }
            Section {
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
                .labelsHidden()
            }
            .clearListRow()
            if model.hasLoaded, let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                .clearListRow()
            }
            if model.hasLoaded && !model.isEmpty {
                dashboard
            }
        }
        .insetGroupedList()
        .settingsGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(AppRoute.usage.title(language))
        .refreshable {
            await model.load()
            await model.loadToday()
        }
        .task {
            async let today: Void = model.loadToday()
            await model.load()
            await today
        }
        .onChange(of: app.isOffline) {
            if !app.isOffline {
                Task {
                    await model.load()
                    await model.loadToday()
                }
            }
        }
    }

    /// 还没拉到、没有用量、拉不到时盖在列表上（分段控件和“今天”那组照样在）。
    @ViewBuilder
    private var placeholder: some View {
        let zh = language == .chinese
        if model.hasLoaded {
            if model.isEmpty {
                ContentUnavailableView(
                    zh ? "这段时间还没有用量" : "No usage in this period", systemImage: "chart.bar",
                    description: Text(
                        zh
                            ? "Botin 调模型之后，这里会按天显示 token 数。"
                            : "Once Botins call models, daily token counts show up here."))
            }
        } else if model.isLoading || model.error == nil {
            ProgressView()
        } else {
            ModelsUnavailableView(error: model.error) { Task { await model.load() } }
        }
    }

    @ViewBuilder
    private var dashboard: some View {
        let zh = language == .chinese
        let model = self.model
        Section {
            UsageTotalCard(total: model.total, period: model.period)
        }
        .themedRow()
        Section {
            UsageChart(points: model.dayPoints, timeZone: model.timeZone)
                .padding(.vertical, Metrics.Spacing.xs)
            if let peak = model.peakDay {
                Text(peakText(peak))
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        } header: {
            Text(zh ? "每天" : "Per day").settingsGroupHeader()
        }
        .themedRow()
        Section {
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
            .labelsHidden()
        } header: {
            Text(zh ? "明细" : "Breakdown").settingsGroupHeader()
        }
        .clearListRow()
        if let error = visibleError(model.groupError) {
            Section {
                ErrorBanner(error) { Task { await model.load() } }
            }
            .clearListRow()
        }
        let rows = model.rows(language: language)
        Section {
            if rows.isEmpty {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(rows) { row in
                    if let route = model.destination(of: row) {
                        NavigationLink(value: route) { UsageRowView(row: row) }
                    } else {
                        UsageRowView(row: row)
                    }
                }
            }
        } footer: {
            Text(UsageText.footnote(language)).settingsGroupFooter()
        }
        .themedRow()
    }

    /// “最多的一天：10月20日，3.6 万 token”。
    private func peakText(_ peak: UsageDayPoint) -> String {
        let day = Formatting.shortDate(
            peak.date, language: language, calendar: UsageChartFormat.calendar(model.timeZone))
        let tokens = Formatting.tokens(peak.tokens, language: language)
        return language == .chinese ? "最多的一天：\(day)，\(tokens) token" : "Busiest day: \(day), \(tokens) tokens"
    }
}

/// “今天”一组的一行（参考 55 的卡片）：key 的名字、右边灰色小字（`.footnote`，参考约 13pt）的“今天 已用 / 上限”，系统的线性 `ProgressView`（细条，看得见
/// 底下的轨道；以前的 `Gauge(.linearCapacity)` 在 iOS 26 上约 16pt 粗），下面百分比；用满了是警告色。
struct UsageGaugeRow: View {
    let gauge: UsageGauge

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(gauge.title)
                    .foregroundStyle(gauge.isDisabled ? Theme.inkSecondary : Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: Metrics.Spacing.xs)
                Text(gauge.todayAmountText(language))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
            ProgressView(value: gauge.fraction)
                .progressViewStyle(.linear)
                .tint(gauge.isExhausted ? StatusTone.waiting.color : Theme.accent)
            Text(verbatim: gauge.percentText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.vertical, Metrics.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(gauge.title))
        .accessibilityValue(Text(gauge.accessibilityValue(language)))
    }
}

/// 总计（分组列表里的一行）：大号的 token 总数，请求、失败、估算一行，下面是输入、输出、缓存、计费等小格子。
struct UsageTotalCard: View {
    let total: UsageBucket
    let period: UsageModel.Period

    @Environment(\.displayLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let zh = language == .chinese
        let items = UsageText.totalItems(total, language: language)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
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
        .padding(.vertical, Metrics.Spacing.xxs)
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

/// 明细的一行：名字、副标题、请求和失败；右边是 token 数。能点开的由外面包 `NavigationLink`（系统画箭头）。
struct UsageRowView: View {
    let row: UsageRow

    @Environment(\.displayLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(row.title)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(row.detail(language))
                    .font(.footnote)
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.accessibilityLabel(language)))
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
