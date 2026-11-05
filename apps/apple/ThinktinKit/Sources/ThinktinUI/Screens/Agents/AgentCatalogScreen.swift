import SwiftUI
import ThinktinKit

/// Agent 目录（界面上是“引擎”；`.agentCatalog`）：新建 Botin 表单里的“了解引擎”、引导、没有 Botin 时的“新任务”、
/// 对话页“Botin 已删”的空状态进来（新建的主路径是首页“+”弹的表单，在表单里选引擎）。每个 agent 一张卡片（名字、出处、
/// 一句话介绍、版本、许可证、接入方式、几个 Botin 在用），点开去详情，详情上“用它新建 Botin”。
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

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: AgentCatalogModel(client: client))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                PageHeader(
                    title: zh ? "选一个引擎" : "Pick an engine",
                    message: zh
                        ? "引擎决定 Botin 怎么干活，同一个引擎可以给好几个 Botin 用。每个 Botin 都在自己的沙箱里运行，用你配置的模型 key，"
                            + "建好后可以随时改名、升级或删除。"
                        : "The engine is what powers a Botin, and one engine can power several Botins. Each Botin runs in "
                            + "its own sandbox with the model keys you set up. You can rename, upgrade or delete it any time."
                )
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                content
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(AppRoute.agentCatalog.title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            // 联网后自动刷新（离线横幅上写了“联网后会自动刷新”）。
            if !app.isOffline { Task { await model.load() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        let zh = language == .chinese
        if model.isEmpty {
            EmptyStateView(
                systemImage: "square.stack.3d.up", title: zh ? "还没有能用的引擎" : "No engines yet",
                message: zh ? "稍后再来看看。" : "Check back later.")
        } else if model.hasNothingToShow {
            if model.isLoading || model.error == nil {
                LoadingStateView()
            } else {
                EmptyStateView(
                    systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle",
                    title: zh ? "暂时拉不到引擎列表" : "Couldn't load the engines",
                    message: model.error?.isOffline == true
                        ? (zh ? "联网后会自动刷新。" : "This will refresh when you're back online.") : nil)
            }
        } else {
            ForEach(model.cards(instances: app.instances, language: language)) { card in
                Button {
                    router.open(.agent(card.id))
                } label: {
                    AgentCatalogCardView(card: card)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(card.accessibilityLabel(language)))
                .accessibilityHint(Text(zh ? "查看详情，用它新建 Botin" : "Shows details. You can create a Botin with it."))
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}

/// 目录里的一张卡片。
struct AgentCatalogCardView: View {
    let card: AgentCatalogCard

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                InstanceAvatar(card.name)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(card.name)
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                    if let byline = card.byline {
                        Text(byline)
                            .typography(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            if !card.summary.isEmpty {
                Text(card.summary)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TagChipRow {
                TagChip(text: card.versionLabel)
                if let adopted = card.adoptedLabel(language) {
                    TagChip(text: adopted)
                }
            }
            // 许可证名字可能很长（“Anthropic 商业条款（专有）”），单独一行，能换行。
            Text((language == .chinese ? "许可证：" : "License: ") + card.licenseLabel)
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !card.harnessLabels.isEmpty {
                Text(
                    (language == .chinese ? "接入方式：" : "Runs via: ")
                        + AgentsText.list(card.harnessLabels, language: language)
                )
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Agent 目录 · 浅色中文") {
    AgentCatalogScreen().previewShell()
}

#Preview("Agent 目录 · 深色英文") {
    AgentCatalogScreen().previewShell(.english, scheme: .dark)
}

#Preview("Agent 目录 · 空的") {
    AgentCatalogScreen().previewShell(client: AgentsPreviewClients.emptyCatalog())
}
