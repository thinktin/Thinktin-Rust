import SwiftUI
import ThinktinKit

/// 引擎详情里点了的操作（详情是 sheet 时交给弹它的页面：先关 sheet 再走路由）。
enum AgentDetailAction: Hashable {
    /// 用它新建 Botin（`.adopt(agentID:)`）。
    case create(AgentID)
    /// 打开在用它的一个 Botin 的资料。
    case openInstance(InstanceID)
    /// 下架了，看看别的引擎。
    case browseCatalog
}

/// 引擎详情（代码里是 agent 详情；规范 4.8.3 的插件详情版式，参考 105、106、107、52）：引擎目录点行弹的 medium / large sheet；
/// `.agent(id)` 路由（压栈）也是这个页面。
///
/// - 左上 ×（sheet 时）；居中 56pt 圆角方块图标、名字（`.title2.bold()`）、出处；下面一段灰字介绍（参考的说明段落）；
/// - 分组（参考“账户”那一组的位置）：许可证（和上游仓库）、接入方式、版本、模型接口、能用的地区、在用它的 Botin；
/// - 底部居中的胶囊主按钮“用它新建 Botin”（参考“连接”，浮在内容上，medium 档也看得到；离线灰掉）。
///   在新建表单里打开的（“了解引擎”→ 目录 → 详情）点了回到那张表单、换成这个引擎（`Router.engineRequest`），不叠第二张。
/// - 下架了：`ContentUnavailableView` +“看看别的引擎”。
struct AgentDetailScreen: View {
    let agentID: AgentID
    /// 目录里的那一条（先显示，不用等拉）。
    var agent: AgentInfo?
    /// 详情是 sheet 时给：左上加 ×，按钮的操作交给弹它的页面。nil 是压栈的页面，操作直接走路由。
    var onAction: (@MainActor (AgentDetailAction?) -> Void)?

    @Environment(\.client) private var client

    init(
        agentID: AgentID, agent: AgentInfo? = nil, onAction: (@MainActor (AgentDetailAction?) -> Void)? = nil
    ) {
        self.agentID = agentID
        self.agent = agent
        self.onAction = onAction
    }

    var body: some View {
        AgentDetailContent(client: client, agentID: agentID, agent: agent, onAction: onAction)
    }
}

private struct AgentDetailContent: View {
    @State private var model: AgentDetailModel
    let onAction: (@MainActor (AgentDetailAction?) -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(
        client: any ClientProtocol, agentID: AgentID, agent: AgentInfo?,
        onAction: (@MainActor (AgentDetailAction?) -> Void)?
    ) {
        _model = State(initialValue: AgentDetailModel(client: client, agentID: agentID, agent: agent))
        self.onAction = onAction
    }

    var body: some View {
        let model = self.model
        List {
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let agent = model.agent {
                AgentDetailSections(agent: agent, instances: model.adoptedInstances(in: app.instances)) { id in
                    perform(.openInstance(id))
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .floatingBar(edge: .bottom) {
            if let agent = model.agent {
                createButton(agent)
            }
        }
        .inlineNavigationTitle(model.agent == nil ? AppRoute.agent(model.agentID).title(language) : model.displayName) {
            // 参考的详情 sheet 没有标题（头部已经有名字）。
            EmptyView()
        }
        .toolbar {
            if onAction != nil {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { onAction?(nil) }
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }

    /// 底部居中的胶囊（参考“连接”）：不占满整宽。
    private func createButton(_ agent: AgentInfo) -> some View {
        let zh = language == .chinese
        return Button {
            perform(.create(agent.id))
        } label: {
            Text(zh ? "用它新建 Botin" : "Create a Botin with it")
                .font(Font.headline)
                .padding(.horizontal, Metrics.Spacing.m)
        }
        .glassButtonStyle(.prominent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(app.isOffline || !agent.canPowerNewBotin)
        .accessibilityHint(Text(zh ? "起个名字，新建一个用这个引擎的 Botin" : "Name a new Botin that runs on this engine"))
        .padding(.vertical, Metrics.Spacing.s)
        .frame(maxWidth: .infinity)
    }

    /// 还没有引擎可显示时：下架了、在拉、拉不到。
    @ViewBuilder
    private var placeholder: some View {
        let zh = language == .chinese
        if model.isMissing {
            ContentUnavailableView {
                Label(zh ? "这个引擎已经下架了" : "This engine is no longer offered", systemImage: "shippingbox")
            } description: {
                Text(zh ? "已经在用它的 Botin 不受影响，可以继续用。" : "Botins that already use it keep working.")
            } actions: {
                Button(zh ? "看看别的引擎" : "Browse other engines") { perform(.browseCatalog) }
                    .glassButtonStyle()
            }
        } else if model.agent == nil {
            if model.isLoading || model.error == nil {
                ProgressView()
            } else {
                ContentUnavailableView(
                    zh ? "暂时拉不到这个引擎" : "Couldn't load this engine",
                    systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle")
            }
        }
    }

    /// sheet 时交给弹它的页面（先关 sheet）；压栈的页面直接走路由。
    private func perform(_ action: AgentDetailAction) {
        if let onAction {
            onAction(action)
            return
        }
        switch action {
        case .create(let id): router.open(.adopt(agentID: id))
        case .openInstance(let id): router.open(.instance(id))
        case .browseCatalog: router.open(.agentCatalog)
        }
    }
}

/// 拉到引擎之后的几组：头部（图标、名字、出处、介绍），许可证、接入方式、版本、模型接口、地区、在用它的 Botin。
private struct AgentDetailSections: View {
    let agent: AgentInfo
    let instances: [Instance]
    let onOpenInstance: @MainActor (InstanceID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let name = AgentsText.displayName(of: agent)
        Section {
            VStack(spacing: Metrics.Spacing.s) {
                EngineIcon(name: name, size: EngineIcon.detailSize)
                VStack(spacing: Metrics.Spacing.xxs) {
                    Text(name)
                        .font(Font.title2.bold())
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if let byline = AgentsText.byline(of: agent.id, language: language) {
                        Text(byline)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                if !agent.description.isEmpty {
                    Text(agent.description)
                        .typography(.body)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.Spacing.xs)
            .clearListRow()
        }

        licenseSection
        Section {
            ForEach(agent.catalogHarnesses, id: \.self) { harness in
                DetailRow(
                    title: AgentsText.harnessName(harness, language: language),
                    detail: AgentsText.harnessDetail(harness, language: language),
                    trailing: harness == agent.defaultHarness && agent.harnesses.count > 1
                        ? (zh ? "默认" : "Default") : nil)
            }
        } header: {
            Text(zh ? "接入方式" : "How it runs").textCase(nil)
        }
        .themedRow()

        Section {
            LabeledContent(zh ? "最新" : "Latest", value: AgentsText.versionLabel(agent.catalogLatestVersion))
            LabeledContent(
                zh ? "可用版本" : "Available",
                value: AgentsText.list(agent.catalogVersions.map(AgentsText.versionLabel), language: language))
        } header: {
            Text(zh ? "版本" : "Versions").textCase(nil)
        } footer: {
            Text(
                zh
                    ? "新建 Botin 时用最新版本，之后可以在 Botin 的工作区里升级或换回旧版本。"
                    : "New Botins use the latest version. You can upgrade or roll back later from the Botin's workspace."
            )
        }
        .themedRow()

        protocolSection
        if !agent.sites.isEmpty {
            Section {
                Text(
                    AgentsText.list(agent.sites.map { AgentsText.siteName($0, language: language) }, language: language)
                )
            } header: {
                Text(zh ? "能用的地区" : "Available in").textCase(nil)
            }
            .themedRow()
        }
        if !instances.isEmpty {
            Section {
                ForEach(instances) { instance in
                    Button {
                        onOpenInstance(instance.id)
                    } label: {
                        HStack(spacing: Metrics.Spacing.s) {
                            InstanceAvatar(
                                instance.name, appearance: app.appearances.resolved(for: instance.id), size: 28)
                            Text(instance.name)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: Metrics.Spacing.s)
                            Text(
                                AgentsText.versionLabel(instance.agentVersion) + " · "
                                    + instance.state.localizedName(language)
                            )
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            Image(systemName: "chevron.right")
                                .font(Typography.footnote.font.weight(.semibold))
                                .foregroundStyle(Theme.inkTertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(zh ? "在用它的 Botin" : "Botins using it").textCase(nil)
            }
            .themedRow()
        }
    }

    private var licenseSection: some View {
        let zh = language == .chinese
        let proprietary = AgentsText.isProprietary(agent.license)
        return Section {
            Label {
                DetailRow(title: AgentsText.licenseName(agent.license, language: language), detail: agent.licenseNote)
            } icon: {
                Image(systemName: proprietary ? "exclamationmark.shield" : "checkmark.shield")
                    .foregroundStyle(Theme.inkSecondary)
            }
            if let url = agent.upstreamURL {
                Link(destination: url) {
                    LabeledContent {
                        Text(url.host ?? url.absoluteString)
                    } label: {
                        Label(zh ? "上游仓库" : "Upstream repository", systemImage: "arrow.up.right.square")
                    }
                }
                .accessibilityHint(Text(zh ? "在浏览器里打开" : "Opens in your browser"))
            }
        } header: {
            Text(zh ? "许可证" : "License").textCase(nil)
        }
        .themedRow()
    }

    @ViewBuilder
    private var protocolSection: some View {
        let zh = language == .chinese
        let needed = agent.activeProtocol.map { [$0] } ?? agent.protocols
        if !needed.isEmpty {
            Section {
                Text(AgentsText.list(needed.map(AgentsText.protocolName), language: language))
            } header: {
                Text(zh ? "模型接口" : "Model API").textCase(nil)
            } footer: {
                Text(
                    zh
                        ? "配模型路由时，要选支持这种接口的模型 key。"
                        : "When you set up model routes, pick keys that support this API.")
            }
            .themedRow()
        }
    }
}

/// 分组里的一行：标题、下面的灰字（可选）、右边的灰字（可选）。
private struct DetailRow: View {
    let title: String
    var detail: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                Text(title)
                    .foregroundStyle(Theme.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("引擎详情 · 浅色中文") {
    NavigationStack {
        AgentDetailScreen(agentID: DemoData.claudeAgentID) { _ in }
    }
    .previewShell()
}

#Preview("引擎详情 · 深色英文") {
    AgentDetailScreen(agentID: DemoData.codexAgentID).previewShell(.english, scheme: .dark)
}

#Preview("引擎详情 · 已下架") {
    AgentDetailScreen(agentID: "retired").previewShell()
}
