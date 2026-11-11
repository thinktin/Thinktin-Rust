import SwiftUI
import ThinktinKit

/// 引擎目录（代码里是 agent 目录，`.agentCatalog`；规范 4.7.1 末尾、4.8.4，借参考 101、104 的插件完整列表的版式）：新建 Botin
/// 表单里的“了解引擎”、下架引擎的“看看别的引擎”进来（新建的主路径是首页“+”弹的表单，在表单里选引擎）。
///
/// - plain 列表、不画分隔线，标题“引擎”；每行：40pt 圆角方块图标（名字的首字）、名字、最多两行 `.footnote` 灰字介绍，右边
///   玻璃胶囊“选这个”（参考“连接”：普通大小、中性色的字；点了用它新建 Botin：在新建表单里时退回表单、换成它，别处弹预选
///   它的表单），不能用的灰掉写“暂不可用”。
/// - 点行弹引擎详情（参考 105–107 的插件详情 sheet，medium / large 两档，`AgentDetailScreen`）；详情里的按钮先关掉 sheet 再走路由。
/// - 最下面一段灰字说明引擎是什么（参考没有页头，挪到列表末尾）。
///
/// 目录不缓存：离线时显示“暂无数据”的空状态（横幅由应用框架统一放），联网后自动再拉一次。
struct AgentCatalogScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        AgentCatalogContent(client: client)
    }
}

private struct AgentCatalogContent: View {
    @State private var model: AgentCatalogModel
    /// 弹出详情的引擎。
    @State private var selected: AgentInfo?
    /// 详情 sheet 里点了的操作，sheet 关掉后再做（sheet 还在时弹别的 sheet、压栈会被系统丢掉）。
    @State private var pendingAction: AgentDetailAction?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: AgentCatalogModel(client: client))
    }

    var body: some View {
        let model = self.model
        List {
            if let error = visibleError(model.error) {
                ErrorBanner(error) { Task { await model.load() } }
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
            }
            if !model.hasNothingToShow {
                ForEach(model.cards(instances: app.instances, language: language)) { card in
                    EngineRow(card: card, canCreate: !app.isOffline) {
                        selected = model.agent(card.id)
                    } onUse: {
                        router.open(.adopt(agentID: card.id))
                    }
                    .padding(.horizontal, EngineCatalogLayout.extraSideInset)
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
                }
                Text(footnote)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.top, Metrics.Spacing.s)
                    .padding(.horizontal, EngineCatalogLayout.extraSideInset)
                    .listRowSeparator(.hidden)
                    .themedPlainRow()
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, EngineCatalogLayout.topMargin, for: .scrollContent)
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(AppRoute.agentCatalog.title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            // 联网后自动刷新（离线横幅上写了“联网后会自动刷新”）。
            if !app.isOffline { Task { await model.load() } }
        }
        .onSubpageRequest(.engineDetail, when: !model.agents.isEmpty) { selected = model.agents.first }
        .sheet(item: $selected, onDismiss: performPendingAction) { agent in
            NavigationStack {
                AgentDetailScreen(agentID: agent.id, agent: agent) { action in
                    pendingAction = action
                    selected = nil
                }
            }
            .shellEnvironment(app)
            .environment(\.displayLanguage, language)
            .tint(Theme.accent)
            // 和连接详情同一个版式、同样两档（小的那一档比 `.medium` 高一点，参考 38、52 的 sheet 上沿约在屏幕高的 43.7%）。
            .presentationDetents([ConnectionsLayout.detailDetent, .large])
            // 参考 38、52 的详情 sheet 没有拖动条（连接详情也藏了）。
            .presentationDragIndicator(.hidden)
        }
    }

    /// 列表最后的一段说明（以前的页头）。
    private var footnote: String {
        language == .chinese
            ? "引擎决定 Botin 怎么干活，同一个引擎可以给好几个 Botin 用。每个 Botin 都在自己的沙箱里运行，用你配置的模型 key，"
                + "建好后可以随时改名、升级或删除。"
            : "The engine is what powers a Botin, and one engine can power several Botins. Each Botin runs in "
                + "its own sandbox with the model keys you set up. You can rename, upgrade or delete it any time."
    }

    /// 没有行可显示时：目录是空的、在拉、拉不到。
    @ViewBuilder
    private var placeholder: some View {
        let zh = language == .chinese
        if model.isEmpty {
            ContentUnavailableView {
                Label(zh ? "还没有能用的引擎" : "No engines yet", systemImage: "square.stack.3d.up")
            } description: {
                Text(zh ? "稍后再来看看。" : "Check back later.")
            }
        } else if model.hasNothingToShow {
            if model.isLoading || model.error == nil {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label(
                        zh ? "暂时拉不到引擎列表" : "Couldn't load the engines",
                        systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle")
                } description: {
                    if model.error?.isOffline == true {
                        Text(zh ? "联网后会自动刷新。" : "This will refresh when you're back online.")
                    }
                }
            }
        }
    }

    /// 详情 sheet 关掉后做它要的事：用它新建（在新建表单里时 `Router` 退回表单、换引擎）、打开 Botin 资料。
    private func performPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .create(let id): router.open(.adopt(agentID: id))
        case .openInstance(let id): router.open(.instance(id))
        case .browseCatalog: break
        }
    }
}

/// 引擎目录的边距（参考 101、104 量的）。
enum EngineCatalogLayout {
    /// 行的左右比系统的行边距（16pt）再缩进多少：参考图标离屏幕左边 22.8pt，胶囊离右边 23pt。
    static let extraSideInset: CGFloat = 7
    /// 列表顶上多留的空：参考第一个图标的上沿在返回按钮圆心下面 74pt（不留是 56pt）。
    static let topMargin = Metrics.Spacing.m + Metrics.Spacing.unit / 2
}

/// 目录的一行（参考 101、104）：图标、名字、两行 `.footnote` 灰字，右边玻璃胶囊。点行（胶囊以外）看详情。行的上下不再
/// 自己加边距（系统的行边距就够，参考两行之间约 70–89pt）；图标到字 16pt（参考图标 22.8pt 起、字 79pt 起）。左右的缩进
/// 由目录页加（`EngineCatalogLayout.extraSideInset`）。
struct EngineRow: View {
    let card: AgentCatalogCard
    let canCreate: Bool
    let onOpen: @MainActor () -> Void
    let onUse: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        HStack(spacing: Metrics.Spacing.s) {
            Button(action: onOpen) {
                HStack(spacing: Metrics.Spacing.m) {
                    EngineIcon(name: card.name, size: EngineIcon.rowSize)
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                        Text(card.name)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        let subtitle = card.rowSubtitle
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .typography(.footnote)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(card.accessibilityLabel(language)))
            .accessibilityHint(Text(zh ? "查看详情" : "Shows details"))
            .accessibilityAddTraits(.isButton)
            // 参考“连接”：普通大小（约 35pt 高）、中性色的字（`glassButtonStyle` 的次按钮，参考约 13pt 中等粗细），不是强调色的
            // 小胶囊。
            Button(action: onUse) {
                Text(card.actionTitle(language))
                    .font(Typography.footnote.font.weight(.medium))
            }
            .glassButtonStyle()
            .buttonBorderShape(.capsule)
            .disabled(!card.isAvailable || !canCreate)
            .accessibilityLabel(Text(card.actionAccessibilityLabel(language)))
        }
    }
}

/// 引擎的图标：圆角方块（参考插件图标的样子，和 Botin 默认的圆形头像分开），名字的首字（白字）、按名字取色；底色是首字
/// 图标那套暗一点的（`AvatarGlyph.palette`），不是 Botin 的鲜明色板。
struct EngineIcon: View {
    /// 列表行（规范 2.4：应用 / agent 图标方块 40）。
    static let rowSize: CGFloat = 40
    /// 详情 sheet 的头部（参考 105 约 56）。
    static let detailSize: CGFloat = 56

    let name: String
    let size: CGFloat

    var body: some View {
        AvatarGlyph(name: name, size: size)
            .accessibilityHidden(true)
    }
}

#Preview("引擎目录 · 浅色中文") {
    AgentCatalogScreen().previewShell()
}

#Preview("引擎目录 · 深色英文") {
    AgentCatalogScreen().previewShell(.english, scheme: .dark)
}

#Preview("引擎目录 · 空的") {
    AgentCatalogScreen().previewShell(client: AgentsPreviewClients.emptyCatalog())
}
