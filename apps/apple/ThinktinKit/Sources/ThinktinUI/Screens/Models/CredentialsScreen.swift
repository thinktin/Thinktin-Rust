import SwiftUI
import ThinktinKit

/// 模型 key 列表（`.credentials`，入口：设置 → 模型 key）：在用的、停用的分开列，每把显示厂商、备注、后 4 位、
/// 每日上限、支持的协议；右上角“+”弹出添加 key（`.addCredential` 的 sheet），下面有用量看板的入口。
///
/// key 不缓存：离线时显示空状态（顶部的离线横幅由应用框架放），添加按钮禁用。sheet 关掉、从详情页回来都重新拉一次。
struct CredentialsScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        CredentialsContent(client: client)
    }
}

private struct CredentialsContent: View {
    @State private var model: CredentialsModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: CredentialsModel(client: client))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                AgentsPageHeader(
                    title: AppRoute.credentials.title(language),
                    message: zh
                        ? "agent 用你自己在厂商那里开的 API key 调模型，费用由厂商直接结算。key 加密保存，只显示后 4 位。"
                        : "Agents call models with API keys from your own vendor accounts, billed by the vendor directly. "
                            + "Keys are stored encrypted and only the last 4 characters are shown.")
                if model.hasLoaded, let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if model.hasLoaded {
                    list
                } else if model.isLoading || model.error == nil {
                    AgentsLoadingView()
                } else {
                    ModelsUnavailableView(error: model.error) { Task { await model.load() } }
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.credentials.title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.open(.addCredential)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(app.isOffline)
                .accessibilityLabel(Text(AppRoute.addCredential.title(language)))
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: router.sheet) {
            // 添加 key 的 sheet 关掉了：重新拉。
            if router.sheet == nil { Task { await model.load() } }
        }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }

    @ViewBuilder
    private var list: some View {
        let zh = language == .chinese
        if model.isEmpty {
            EmptyStateView(
                systemImage: "key",
                title: zh ? "还没有模型 key" : "No model keys yet",
                message: zh
                    ? "加一把厂商的 API key，agent 才能干活。没有 key 时，任务会停在“等待 key”。"
                    : "Add an API key from a model vendor so agents can work. Without one, tasks wait for a key.",
                actionTitle: app.isOffline ? nil : AppRoute.addCredential.title(language)
            ) {
                router.open(.addCredential)
            }
        } else {
            section(zh ? "使用中" : "Active", credentials: model.activeCredentials)
            if !model.disabledCredentials.isEmpty {
                section(zh ? "已停用" : "Disabled", credentials: model.disabledCredentials)
            }
        }
        AgentsSectionHeader(title: zh ? "用量" : "Usage")
        AgentsGroup {
            AgentsRow(
                systemImage: "chart.bar", title: AppRoute.usage.title(language),
                detail: zh ? "按天、实例、模型、key 看 token 用量" : "Token usage by day, instance, model and key",
                action: { router.open(.usage) })
        }
        ModelsFootnote(text: ModelsText.wakeExplanation(language))
            .padding(.top, Metrics.Spacing.xs)
    }

    private func section(_ title: String, credentials: [Credential]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: title)
            AgentsGroup {
                ForEach(credentials) { credential in
                    if credential.id != credentials.first?.id { Divider() }
                    ModelsCredentialRow(summary: model.summary(of: credential, language: language)) {
                        router.open(.credential(credential.id))
                    }
                }
            }
        }
    }
}

#Preview("模型 key · 浅色中文") {
    CredentialsScreen().previewShell()
}

#Preview("模型 key · 深色英文") {
    CredentialsScreen().previewShell(.english, scheme: .dark)
}

#Preview("模型 key · 还没有") {
    CredentialsScreen().previewShell(client: ModelsPreviewClients.noKeys())
}
