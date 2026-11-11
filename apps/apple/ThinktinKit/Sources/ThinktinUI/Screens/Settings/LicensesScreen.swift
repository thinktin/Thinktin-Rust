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
///
/// 改版（参考里没有这一页，照设置子页排，规范 2.5）：分组列表，三节各是一组（组标题带个数、说明在脚注）；第三节每个许可证
/// 一个系统的 `DisclosureGroup`，组件是 `NavigationLink`；没搜到 `ContentUnavailableView.search`。
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
        List {
            if !model.hasNoResults(language) {
                if !model.isSearching {
                    Section {
                        Text(LicensesModel.intro(language))
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.horizontal, Metrics.Spacing.m)
                            .clearListRow()
                    }
                }
                agentsSection
                swiftSection
                coreSection
            }
        }
        .insetGroupedList()
        .settingsGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.hasNoResults(language) {
                ContentUnavailableView.search(text: model.query)
            }
        }
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
            Section {
                if !entries.isEmpty {
                    ForEach(entries) { entry in
                        AgentLicenseCard(entry: entry)
                    }
                } else if let error = model.agentsError {
                    if error.isOffline {
                        // 设置页面没有离线横幅（不用联网的页面），这一节自己说。
                        Label(
                            zh ? "离线，联网后显示引擎的许可证。" : "Offline. Engine licenses will show when you're back online.",
                            systemImage: "wifi.slash"
                        )
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                    } else {
                        ErrorBanner(error, onRetry: { Task { await model.loadAgents() } })
                            .clearListRow()
                    }
                } else if model.isLoadingAgents || !model.hasLoadedAgents {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(zh ? "还没有能用的引擎。" : "No engines yet.")
                        .typography(.body)
                        .foregroundStyle(Theme.inkTertiary)
                }
            } header: {
                LicensesSectionTitle(title: zh ? "引擎" : "Engines", count: model.hasLoadedAgents ? entries.count : nil)
            } footer: {
                Text(LicensesModel.agentsFootnote(language)).settingsGroupFooter()
            }
            .themedRow()
        }
    }

    // MARK: Swift 包

    @ViewBuilder
    private var swiftSection: some View {
        let zh = language == .chinese
        let packages = model.swiftPackages
        if !model.isSearching || !packages.isEmpty {
            Section {
                if packages.isEmpty {
                    Text(LicensesModel.noSwiftPackagesMessage(language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    componentRows(packages)
                }
            } header: {
                LicensesSectionTitle(title: zh ? "Swift 依赖" : "Swift packages", count: packages.count)
            }
            .themedRow()
        }
    }

    // MARK: 客户端核心

    @ViewBuilder
    private var coreSection: some View {
        let zh = language == .chinese
        let groups = model.groups
        if !(model.isSearching && groups.isEmpty) {
            Section {
                switch model.inventoryState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                case .failed(let error):
                    Label(error.message(language), systemImage: "exclamationmark.triangle")
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                case .loaded:
                    if let notices = model.noticesPath, !model.isSearching {
                        NavigationLink {
                            LicenseTextView(title: notices, path: notices, directory: model.directory)
                        } label: {
                            LabeledContent {
                                Text(verbatim: notices)
                            } label: {
                                Label(zh ? "完整清单" : "Full list", systemImage: "list.bullet.rectangle")
                            }
                        }
                    }
                    ForEach(groups) { group in
                        groupView(group)
                    }
                }
            } header: {
                LicensesSectionTitle(
                    title: zh ? "客户端核心（Rust）" : "Client core (Rust)",
                    count: model.inventory.map { _ in groups.reduce(0) { $0 + $1.components.count } })
            } footer: {
                if case .loaded = model.inventoryState, let summary = model.inventorySummary(language),
                    !model.isSearching
                {
                    Text(summary).settingsGroupFooter()
                }
            }
            .themedRow()
        }
    }

    /// 一个许可证一组，系统的 `DisclosureGroup`（搜的时候都展开）。
    private func groupView(_ group: LicenseGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { model.isSearching || expanded.contains(group.id) },
                set: { isOn in
                    if isOn { expanded.insert(group.id) } else { expanded.remove(group.id) }
                })
        ) {
            componentRows(group.components)
        } label: {
            LicenseGroupHeader(group: group, isExpanded: model.isSearching || expanded.contains(group.id))
        }
    }

    private func componentRows(_ components: [LicenseComponent]) -> some View {
        ForEach(components) { component in
            NavigationLink {
                LicenseComponentView(component: component, directory: model.directory)
            } label: {
                LicenseComponentRow(component: component)
            }
        }
    }
}

/// 一节的组标题：名字和个数（组标题的系统样式，不转大写）。
struct LicensesSectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
            Text(title)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .settingsGroupHeader()
        .accessibilityElement(children: .combine)
    }
}

/// 一个许可证的标题行（`DisclosureGroup` 的标签，展开的箭头由系统画）：许可证、组件数。
struct LicenseGroupHeader: View {
    let group: LicenseGroup
    let isExpanded: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let count = group.components.count
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(group.title(language))
                .typography(.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.Spacing.xs)
            Text(verbatim: "\(count)")
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(zh ? "\(group.title(language))，\(count) 个组件" : "\(group.title(language)), \(count) components")
        )
    }
}

/// 组里的一个组件（`NavigationLink` 的内容）：名字、版本。
struct LicenseComponentRow: View {
    let component: LicenseComponent

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
            Text(component.name)
                .typography(.body)
                .foregroundStyle(Theme.ink)
            Text(verbatim: component.version)
                .font(Typography.subheadline.font.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
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
