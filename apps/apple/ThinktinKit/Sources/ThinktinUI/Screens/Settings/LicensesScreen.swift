import SwiftUI
import ThinktinKit

/// 开源许可（WBS 12.12、16.5，`.licenses`；入口：设置 → 关于 → 开源许可）。三节：
///
/// 1. agent 的许可证（`agents()` 的 license、licenseNote、upstream；联网拉，拉不到时只有这一节提示）；
/// 2. Swift 依赖（现在没有第三方包，写明一句）；
/// 3. 客户端核心（Rust）带的第三方组件：ThinktinCore 资源里的 `inventory.json`，按许可证分组（点组名展开），点组件看
///    许可证原文；整份 `NOTICES.md` 也能打开。
///
/// 顶部可以搜（组件名、版本、许可证、作者、agent 名），搜的时候所有组都展开。清单在本机，不联网也能看。
struct LicensesScreen: View {
    @Environment(\.client) private var client
    @Environment(\.licensesDirectory) private var directory

    var body: some View {
        LicensesContent(model: LicensesModel(client: client, directory: directory))
    }
}

private struct LicensesContent: View {
    @State private var model: LicensesModel
    /// 展开着的组（按许可证）。
    @State private var expanded: Set<String> = []

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: LicensesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Spacing.xl) {
                AccountPageHeader(title: AppRoute.licenses.title(language), message: LicensesModel.intro(language))
                if model.hasNoResults(language) {
                    EmptyStateView(
                        systemImage: "magnifyingglass", title: zh ? "没有找到" : "No matches",
                        message: zh ? "换个组件名或许可证试试。" : "Try a different component or license name.")
                } else {
                    agentsSection
                    swiftSection
                    coreSection
                }
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.l)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .settingsNavigationTitle(AppRoute.licenses.title(language))
        .searchable(
            text: Binding(get: { model.query }, set: { model.query = $0 }),
            prompt: Text(zh ? "搜组件、许可证" : "Search components and licenses")
        )
        .refreshable { await model.loadAgents() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            // 联网后补拉 agent 列表。
            if !app.isOffline, !model.hasLoadedAgents { Task { await model.loadAgents() } }
        }
    }

    // MARK: agent

    @ViewBuilder
    private var agentsSection: some View {
        let zh = language == .chinese
        let entries = model.agentEntries(language)
        if !(model.isSearching && entries.isEmpty) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                LicensesSectionTitle(title: "Agent", count: model.hasLoadedAgents ? entries.count : nil)
                if !entries.isEmpty {
                    ForEach(entries) { entry in
                        AgentLicenseCard(entry: entry)
                    }
                } else if let error = model.agentsError {
                    if error.isOffline {
                        // 设置页面没有离线横幅（不用联网的页面），这一节自己说。
                        Card {
                            Label(
                                zh
                                    ? "离线，联网后显示 agent 的许可证。"
                                    : "Offline. Agent licenses will show when you're back online.",
                                systemImage: "wifi.slash"
                            )
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                        }
                    } else {
                        ErrorBanner(error, onRetry: { Task { await model.loadAgents() } })
                    }
                } else if model.isLoadingAgents || !model.hasLoadedAgents {
                    AgentsLoadingView()
                } else {
                    Text(zh ? "目录里还没有 agent。" : "No agents in the catalog yet.")
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
                LicensesFootnote(text: LicensesModel.agentsFootnote(language))
            }
        }
    }

    // MARK: Swift 包

    @ViewBuilder
    private var swiftSection: some View {
        let zh = language == .chinese
        let packages = model.swiftPackages
        if !model.isSearching || !packages.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                LicensesSectionTitle(title: zh ? "Swift 依赖" : "Swift packages", count: packages.count)
                if packages.isEmpty {
                    Card {
                        Text(LicensesModel.noSwiftPackagesMessage(language))
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    AccountSection {
                        componentRows(packages)
                    }
                }
            }
        }
    }

    // MARK: 客户端核心

    @ViewBuilder
    private var coreSection: some View {
        let zh = language == .chinese
        let groups = model.groups
        if !(model.isSearching && groups.isEmpty) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                LicensesSectionTitle(
                    title: zh ? "客户端核心（Rust）" : "Client core (Rust)",
                    count: model.inventory.map { _ in groups.reduce(0) { $0 + $1.components.count } })
                switch model.inventoryState {
                case .loading:
                    AgentsLoadingView()
                case .failed(let error):
                    Card {
                        Label(error.message(language), systemImage: "exclamationmark.triangle")
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                case .loaded:
                    if let summary = model.inventorySummary(language), !model.isSearching {
                        LicensesFootnote(text: summary)
                    }
                    if let notices = model.noticesPath, !model.isSearching {
                        AccountSection {
                            NavigationLink {
                                LicenseTextView(title: notices, path: notices, directory: model.directory)
                            } label: {
                                AccountRow(
                                    systemImage: "list.bullet.rectangle", title: zh ? "完整清单" : "Full list",
                                    value: notices, showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(groups) { group in
                        groupView(group)
                    }
                }
            }
        }
    }

    private func groupView(_ group: LicenseGroup) -> some View {
        let isExpanded = model.isSearching || expanded.contains(group.id)
        return AccountSection {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }
            } label: {
                LicenseGroupHeader(group: group, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .disabled(model.isSearching)
            if isExpanded {
                AccountRowDivider()
                componentRows(group.components)
            }
        }
    }

    private func componentRows(_ components: [LicenseComponent]) -> some View {
        ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
            if index > 0 { AccountRowDivider() }
            NavigationLink {
                LicenseComponentView(component: component, directory: model.directory)
            } label: {
                LicenseComponentRow(component: component)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 一节的标题：衬线字、可选的个数。
struct LicensesSectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
            Text(title)
                .typography(.title3)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: "\(count)")
                    .font(Typography.subheadline.font.monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一节下面的说明。
struct LicensesFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 组的标题行：许可证、组件数、展开 / 收起的箭头。
struct LicenseGroupHeader: View {
    let group: LicenseGroup
    let isExpanded: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let count = group.components.count
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            Image(systemName: "checkmark.shield")
                .frame(width: Metrics.Spacing.xl)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(group.title(language))
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.Spacing.xs)
            Text(verbatim: "\(count)")
                .font(Typography.subheadline.font.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(Typography.footnote.font.weight(.semibold))
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.s)
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(zh ? "\(group.title(language))，\(count) 个组件" : "\(group.title(language)), \(count) components")
        )
        .accessibilityValue(Text(isExpanded ? (zh ? "已展开" : "Expanded") : (zh ? "已收起" : "Collapsed")))
        .accessibilityAddTraits(.isButton)
    }
}

/// 组里的一个组件：名字、版本，点进去看详情。
struct LicenseComponentRow: View {
    let component: LicenseComponent

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(component.name)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: component.version)
                    .font(Typography.caption.font.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: Metrics.Spacing.xs)
            Image(systemName: "chevron.right")
                .font(Typography.footnote.font.weight(.semibold))
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(.leading, Metrics.Spacing.m + Metrics.Spacing.xl + Metrics.Spacing.s)
        .padding(.trailing, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.xs)
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("开源许可 · 浅色中文") {
    LicensesScreen().previewShell()
}

#Preview("开源许可 · 深色英文、没带清单") {
    LicensesScreen()
        .environment(\.licensesDirectory, nil)
        .previewShell(.english, scheme: .dark)
}
