import SwiftUI
import ThinktinKit

/// 模型 key 列表（`.credentials`，入口：设置 → 模型 key）。改版成 insetGrouped `List`（规范 2.5、7.3 E；参考里没有这一页，照设置子页
/// 的写法）：在用的、停用的分开两组，每行厂商的首字头像、名字、厂商和后 4 位、一行灰字（停用、每日上限、协议），系统
/// `NavigationLink` 进详情；右上玻璃“+”弹出添加 key（`.addCredential` 的 sheet）；最后一组是用量的入口，脚注说启用后会唤醒等 key 的任务。
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
        List {
            if model.hasLoaded, let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                .clearListRow()
            }
            if model.hasLoaded && !model.isEmpty {
                section(zh ? "使用中" : "Active", credentials: model.activeCredentials, footer: intro)
                if !model.disabledCredentials.isEmpty {
                    section(zh ? "已停用" : "Disabled", credentials: model.disabledCredentials, footer: nil)
                }
                Section {
                    NavigationLink(value: AppRoute.usage) {
                        SettingsRowLabel(
                            title: AppRoute.usage.title(language),
                            subtitle: zh ? "按天、Botin、模型、key 看 token 用量" : "Token usage by day, Botin, model and key")
                    }
                } footer: {
                    Text(ModelsText.wakeExplanation(language))
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(AppRoute.credentials.title(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                Button {
                    router.open(.addCredential)
                } label: {
                    Label(AppRoute.addCredential.title(language), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(app.isOffline)
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: router.visibleRoute) {
            // 添加 key 的 sheet 关掉了（在设置的 sheet 里时是叠在上面的第二层）、从详情回来：重新拉。
            if router.visibleRoute == .credentials { Task { await model.load() } }
        }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }

    private var intro: String {
        language == .chinese
            ? "Botin 用你自己在厂商那里开的 API key 调模型，费用由厂商直接结算。key 加密保存，只显示后 4 位。"
            : "Botins call models with API keys from your own vendor accounts, billed by the vendor directly. "
                + "Keys are stored encrypted and only the last 4 characters are shown."
    }

    @ViewBuilder
    private var placeholder: some View {
        let zh = language == .chinese
        if model.hasLoaded {
            if model.isEmpty {
                ContentUnavailableView {
                    Label(zh ? "还没有模型 key" : "No model keys yet", systemImage: "key")
                } description: {
                    Text(
                        zh
                            ? "加一把厂商的 API key，Botin 才能干活。没有 key 时，任务会停在“等待 key”。"
                            : "Add an API key from a model vendor so Botins can work. Without one, tasks wait for a key."
                    )
                } actions: {
                    if !app.isOffline {
                        Button(AppRoute.addCredential.title(language)) { router.open(.addCredential) }
                            .glassButtonStyle(.prominent)
                            .controlSize(.large)
                    }
                }
            }
        } else if model.isLoading || model.error == nil {
            ProgressView()
        } else {
            ModelsUnavailableView(error: model.error) { Task { await model.load() } }
        }
    }

    private func section(_ title: String, credentials: [Credential], footer: String?) -> some View {
        Section {
            ForEach(credentials) { credential in
                NavigationLink(value: AppRoute.credential(credential.id)) {
                    ModelsCredentialRow(summary: model.summary(of: credential, language: language))
                }
            }
        } header: {
            Text(title).groupHeader()
        } footer: {
            if let footer { Text(footer) }
        }
        .themedRow()
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
