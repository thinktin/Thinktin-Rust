import SwiftUI
import ThinktinKit

/// Agent 详情（`.agent(id)`）：介绍、许可证和许可说明、上游仓库、接入方式、可用版本、要哪种模型接口、能用的地区，
/// 已经领养的实例；“领养”打开领养表单（`AdoptAgentSheet`）。
///
/// 领养好之后按表单里选的下一步跳：配模型路由（12.4 的 `.modelRoutes`，返回栈是“新实例的对话 → 路由页”）、
/// 先加 key（路由页上再弹添加 key）、或者直接去新实例的对话。跳之前先刷新应用框架的实例列表，抽屉里马上有它。
struct AgentDetailScreen: View {
    let agentID: AgentID

    @Environment(\.client) private var client

    var body: some View {
        AgentDetailContent(client: client, agentID: agentID)
    }
}

private struct AgentDetailContent: View {
    @State private var model: AgentDetailModel
    @State private var isAdopting = false
    /// 表单里领养成功了（关掉表单后要刷新实例列表）。
    @State private var didAdopt = false
    /// 领养表单关掉之后要去哪（表单里选的）。
    @State private var exit: AdoptionExit?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, agentID: AgentID) {
        _model = State(initialValue: AgentDetailModel(client: client, agentID: agentID))
    }

    var body: some View {
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let agent = model.agent {
                    AgentDetailBody(
                        agent: agent, instances: model.adoptedInstances(in: app.instances),
                        canAdopt: !app.isOffline
                    ) {
                        isAdopting = true
                    }
                } else if model.isMissing {
                    EmptyStateView(
                        systemImage: "shippingbox",
                        title: language == .chinese ? "这个 agent 已经下架了" : "This agent is no longer offered",
                        message: language == .chinese
                            ? "已经领养的实例不受影响，可以继续用。" : "Instances you already adopted keep working.",
                        actionTitle: language == .chinese ? "看看别的 agent" : "Browse other agents"
                    ) {
                        router.open(.agentCatalog)
                    }
                } else if model.isLoading || model.error == nil {
                    AgentsLoadingView()
                } else {
                    EmptyStateView(
                        systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle",
                        title: language == .chinese ? "暂时拉不到这个 agent" : "Couldn't load this agent")
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(model.agent == nil ? AppRoute.agent(model.agentID).title(language) : model.displayName)
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .sheet(
            isPresented: $isAdopting, onDismiss: { finishAdoption() },
            content: {
                if let agent = model.agent {
                    NavigationStack {
                        AdoptAgentSheet(
                            agent: agent, existingNames: app.instances.map(\.name), client: app.client,
                            onAdopted: { didAdopt = true },
                            onExit: { exit in
                                self.exit = exit
                                isAdopting = false
                            })
                    }
                    .shellEnvironment(app)
                    .tint(Theme.accent)
                }
            })
    }

    /// 领养表单关掉了：领养过就按表单里选的下一步跳（直接划走的只刷新实例列表）；没领养什么也不做。
    private func finishAdoption() {
        let exit = self.exit ?? .stay
        let adopted = didAdopt
        self.exit = nil
        didAdopt = false
        guard adopted else { return }
        let app = self.app
        let router = self.router
        Task { await exit.perform(app: app, router: router) }
    }
}

/// 详情的内容（拉到 agent 之后）。
private struct AgentDetailBody: View {
    let agent: AgentInfo
    let instances: [Instance]
    let canAdopt: Bool
    let onAdopt: @MainActor () -> Void

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let name = AgentsText.displayName(of: agent)
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            // 头部：头像、名字、出处、一句话介绍。
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                AgentMonogram(AgentsText.monogram(of: name), style: .title, size: 56)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(name)
                        .typography(.title)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let byline = AgentsText.byline(of: agent.id, language: language) {
                        Text(byline)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !agent.description.isEmpty {
                Text(agent.description)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PillButton(zh ? "领养" : "Adopt", systemImage: "plus", action: onAdopt)
                .disabled(!canAdopt)
                .accessibilityHint(Text(zh ? "起个名字，领养一个新实例" : "Name and adopt a new instance"))
                .padding(.vertical, Metrics.Spacing.xs)

            licenseSection
            harnessSection
            versionSection
            protocolSection
            if !agent.sites.isEmpty {
                AgentsSectionHeader(title: zh ? "能用的地区" : "Available in")
                AgentsGroup {
                    AgentsRow(
                        systemImage: "globe",
                        title: AgentsText.list(
                            agent.sites.map { AgentsText.siteName($0, language: language) }, language: language))
                }
            }
            if !instances.isEmpty {
                AgentsSectionHeader(title: zh ? "你领养的" : "Your instances")
                AgentsGroup {
                    ForEach(instances) { instance in
                        if instance.id != instances.first?.id { Divider() }
                        AgentsRow(
                            title: instance.name,
                            detail: AgentsText.versionLabel(instance.agentVersion) + " · "
                                + instance.state.localizedName(language),
                            action: { router.open(.instance(instance.id)) })
                    }
                }
            }
        }
    }

    private var licenseSection: some View {
        let zh = language == .chinese
        let proprietary = AgentsText.isProprietary(agent.license)
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "许可证" : "License")
            AgentsGroup {
                AgentsRow(
                    systemImage: proprietary ? "exclamationmark.shield" : "checkmark.shield",
                    title: AgentsText.licenseName(agent.license, language: language),
                    detail: agent.licenseNote)
                if let url = agent.upstreamURL {
                    Divider()
                    Link(destination: url) {
                        AgentsRow(
                            systemImage: "arrow.up.right.square", title: zh ? "上游仓库" : "Upstream repository",
                            detail: url.host ?? url.absoluteString, showsChevron: false)
                    }
                    .accessibilityHint(Text(zh ? "在浏览器里打开" : "Opens in your browser"))
                }
            }
        }
    }

    private var harnessSection: some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "接入方式" : "How it runs")
            AgentsGroup {
                ForEach(agent.catalogHarnesses, id: \.self) { harness in
                    if harness != agent.catalogHarnesses.first { Divider() }
                    AgentsRow(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        title: AgentsText.harnessName(harness, language: language),
                        detail: AgentsText.harnessDetail(harness, language: language),
                        accessory: {
                            if harness == agent.defaultHarness && agent.harnesses.count > 1 {
                                AgentsTag(text: zh ? "默认" : "Default")
                            }
                        })
                }
            }
        }
    }

    private var versionSection: some View {
        let zh = language == .chinese
        let versions = agent.catalogVersions.map(AgentsText.versionLabel)
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "版本" : "Versions")
            AgentsGroup {
                AgentsRow(
                    systemImage: "shippingbox",
                    title: (zh ? "最新 " : "Latest ") + AgentsText.versionLabel(agent.catalogLatestVersion),
                    detail: zh
                        ? "领养时用最新版本。可用版本：\(AgentsText.list(versions, language: language))。之后可以在实例详情里升级或回滚。"
                        : "New instances use the latest version. Available: \(AgentsText.list(versions, language: language)). "
                            + "You can upgrade or roll back later from the instance details.")
            }
        }
    }

    @ViewBuilder
    private var protocolSection: some View {
        let zh = language == .chinese
        let needed = agent.activeProtocol.map { [$0] } ?? agent.protocols
        if !needed.isEmpty {
            AgentsSectionHeader(title: zh ? "模型接口" : "Model API")
            AgentsGroup {
                AgentsRow(
                    systemImage: "key",
                    title: AgentsText.list(needed.map(AgentsText.protocolName), language: language),
                    detail: zh
                        ? "配模型路由时，要选支持这种接口的模型 key。"
                        : "When you set up model routes, pick keys that support this API.")
            }
        }
    }
}

/// 领养表单关掉之后去哪。
enum AdoptionExit: Hashable, Sendable {
    /// 去配新实例的模型路由。
    case configureRoutes(InstanceID)
    /// 先加 key（停在新实例的路由页上，上面弹添加 key）。
    case addCredential(InstanceID)
    /// 先去新实例的对话。
    case openConversation(InstanceID)
    /// 不跳（取消了，或者领养好了直接关掉表单，留在详情页）。
    case stay

    /// 领养好之后跳过去：先刷新应用框架的实例列表（抽屉里马上有新实例，当前实例换成它时也不会被校正回去）。
    @MainActor
    func perform(app: AppModel, router: Router) async {
        await app.refresh()
        switch self {
        case .configureRoutes(let id):
            // 返回栈：新实例的对话 → 路由页（配好返回就是对话）。
            router.show(.modelRoutes(id))
        case .addCredential(let id):
            // 先停在路由页，上面弹添加 key；加好关掉就接着配路由。
            router.show(.modelRoutes(id))
            router.present(.addCredential)
        case .openConversation(let id):
            router.selectInstance(id)
        case .stay:
            break
        }
    }
}

#Preview("Agent 详情 · 浅色中文") {
    AgentDetailScreen(agentID: DemoData.claudeAgentID).previewShell()
}

#Preview("Agent 详情 · 深色英文") {
    AgentDetailScreen(agentID: DemoData.codexAgentID).previewShell(.english, scheme: .dark)
}

#Preview("Agent 详情 · 已下架") {
    AgentDetailScreen(agentID: "retired").previewShell()
}
