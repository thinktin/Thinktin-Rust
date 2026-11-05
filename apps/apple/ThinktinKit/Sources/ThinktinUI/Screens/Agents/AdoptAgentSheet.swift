import SwiftUI
import ThinktinKit

/// 新建 Botin（`.adopt(agentID:)`，sheet；规范 docs/ios-ui-redesign.md 4.7.1、6.4 A）：首页右上的“+”、首页空状态的
/// “新建 Botin”、引擎详情的“用它新建 Botin”（预选那个引擎）打开。代码里还叫领养（`AdoptionModel`、`adopt(...)`）。
///
/// - 原生 `Form`：上面是头像预览（按名字取字和颜色）；名字（`TextField`，名字的问题或提示写在分组脚注里）；引擎（行内
///   `Picker`，每行是名字和一句话介绍，不能用的灰掉、选不了；默认选哪个见 `AdoptionModel.defaultEngine`），引擎的
///   接入方式多于一个时再一行 `Picker(.menu)`；“了解引擎”压进引擎目录（目录 → 引擎详情，详情上的“用它新建 Botin”
///   回到这张表单、换成那个引擎，见 `Router.engineRequest`）；许可证和在哪里运行的说明是引擎分组的脚注。
/// - 左上 ×（`CloseButton`，自己填了名字时先确认），右上“新建”（`ConfirmButton`，新建中转圈；名字不对、没有引擎、
///   离线时不能点）。错误（包括 Botin 数到了上限）在表单里的横幅上；新建中、自己填了名字时不能下滑关掉（填了名字的
///   只能点 ×，和 × 一样先确认）。
/// - 建好了：关掉表单、从首页压栈进新 Botin 的对话（`AppModel.openCreatedInstance`）；以前“建好了”页上配模型路由的
///   引导挪到了对话页的空状态下面（`ConversationText.setupNote`）。
struct AdoptAgentSheet: View {
    let preselectedAgentID: AgentID?

    @Environment(AppModel.self) private var app
    @Environment(\.client) private var client

    init(preselectedAgentID: AgentID? = nil) {
        self.preselectedAgentID = preselectedAgentID
    }

    var body: some View {
        AdoptAgentForm(
            model: AdoptionModel(client: client, instances: app.instances, preselectedAgentID: preselectedAgentID))
    }
}

private struct AdoptAgentForm: View {
    @State private var model: AdoptionModel
    @State private var isConfirmingDiscard = false
    @FocusState private var isNameFocused: Bool

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: AdoptionModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        Form {
            Section {
                InstanceAvatar(model.name, size: Metrics.Avatar.edit)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                    .listRowBackground(Color.clear)
            }
            nameSection
            engineSection
            if let error = model.error {
                Section {
                    ErrorBanner(error) { create() }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if app.isOffline {
                offlineSection
            }
        }
        .formStyle(.grouped)
        .inlineNavigationTitle(AppRoute.adopt(agentID: nil).title(language))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton(action: close)
                    .disabled(model.isAdopting)
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(
                    NewBotinText.create(language), isWorking: model.isAdopting,
                    workingLabel: NewBotinText.creating(language), action: create
                )
                .disabled(!model.canSubmit || app.isOffline)
            }
        }
        .interactiveDismissDisabled(model.isAdopting || model.hasUserInput)
        .confirmationDialog(
            NewBotinText.discardTitle(language), isPresented: $isConfirmingDiscard, titleVisibility: .visible
        ) {
            Button(NewBotinText.discard(language), role: .destructive) { router.dismissSheet() }
            Button(NewBotinText.keepEditing(language), role: .cancel) {}
        }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            // 联网后补拉目录（离线时拉不到）。
            if !app.isOffline && !model.hasLoadedAgents { Task { await model.load() } }
        }
        .onAppear(perform: applyEngineRequest)
        .onChange(of: router.engineRequest) { applyEngineRequest() }
    }

    // MARK: 分组

    private var nameSection: some View {
        let zh = language == .chinese
        let model = self.model
        let problem = model.nameProblem
        return Section {
            TextField(
                NewBotinText.nameTitle(language), text: Binding(get: { model.name }, set: { model.name = $0 }),
                prompt: Text(NewBotinText.namePrompt(language))
            )
            .focused($isNameFocused)
            .submitLabel(.done)
            .autocorrectionDisabled()
            .disabled(model.isAdopting)
        } header: {
            Text(zh ? "名字" : "Name")
        } footer: {
            Text(problem?.message(language) ?? NewBotinText.nameHint(language))
                .foregroundStyle(problem == nil ? Theme.inkSecondary : StatusTone.failure.color)
        }
    }

    private var engineSection: some View {
        let model = self.model
        return Section {
            if model.agents.isEmpty {
                engineStatusRow
            } else {
                Picker(
                    NewBotinText.engineTitle(language),
                    selection: Binding(
                        get: { model.selectedAgentID },
                        set: { id in
                            if let id { model.selectEngine(id) }
                        })
                ) {
                    ForEach(model.engineOptions(language)) { option in
                        EngineOptionLabel(option: option)
                            .tag(AgentID?.some(option.id))
                            .disabled(!option.isAvailable)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(model.isAdopting)
            }
            if model.showsHarnessChoice {
                Picker(
                    NewBotinText.harnessTitle(language),
                    selection: Binding(get: { model.harness }, set: { model.harness = $0 })
                ) {
                    ForEach(model.harnessOptions, id: \.self) { harness in
                        Text(AgentsText.harnessName(harness, language: language)).tag(harness)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isAdopting)
            }
            NavigationLink(value: AppRoute.agentCatalog) {
                Label(NewBotinText.aboutEngines(language), systemImage: "info.circle")
            }
        } header: {
            Text(NewBotinText.engineTitle(language))
        } footer: {
            if let agent = model.selectedAgent {
                Text(NewBotinText.engineFooter(agent, language: language))
            }
        }
    }

    /// 目录还没拉到：在拉、拉不到（可以重试）、目录是空的。
    @ViewBuilder
    private var engineStatusRow: some View {
        let zh = language == .chinese
        let model = self.model
        if model.hasLoadedAgents {
            Text(NewBotinText.noEngines(language))
                .foregroundStyle(Theme.inkSecondary)
        } else if let error = model.loadError, !model.isLoadingAgents {
            LabeledContent(NewBotinText.enginesUnavailable(language)) {
                if !error.isOffline {
                    Button(zh ? "重试" : "Retry") { Task { await model.load() } }
                }
            }
        } else {
            LabeledContent(NewBotinText.engineTitle(language)) {
                ProgressView()
            }
        }
    }

    private var offlineSection: some View {
        let zh = language == .chinese
        let app = self.app
        return Section {
            Text(NewBotinText.offlineNote(language))
                .foregroundStyle(Theme.inkSecondary)
            Button(zh ? "重新检查网络" : "Check again") { Task { await app.refresh() } }
        }
    }

    // MARK: 操作

    private func create() {
        guard model.canSubmit, !app.isOffline else { return }
        isNameFocused = false
        let model = self.model
        let app = self.app
        Task {
            guard let instance = await model.adopt() else { return }
            await app.openCreatedInstance(instance)
        }
    }

    /// ×：自己填了名字时先确认，否则直接关掉。
    private func close() {
        if model.hasUserInput {
            isConfirmingDiscard = true
        } else {
            router.dismissSheet()
        }
    }

    /// 引擎详情上点了“用它新建 Botin”（详情是从这张表单压进去的，`Router` 已经退回表单）：换成那个引擎。表单的目录
    /// 还没拉到时模型先记下，拉到后再换（`AdoptionModel.requestEngine`），所以路由上的请求这里就可以清掉。
    private func applyEngineRequest() {
        guard let id = router.engineRequest else { return }
        router.engineRequestHandled()
        model.requestEngine(id)
    }
}

/// 引擎选择器的一行：名字，下面一行介绍（不能用时说不能用）。读屏念 `EngineOption.accessibilityLabel`（多念几个 Botin 在用）。
private struct EngineOptionLabel: View {
    let option: EngineOption

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let detail = option.detail(language)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(option.name)
                .foregroundStyle(option.isAvailable ? Theme.ink : Theme.inkSecondary)
            if !detail.isEmpty {
                Text(detail)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(option.accessibilityLabel(language)))
    }
}

#Preview("新建 Botin · 浅色中文") {
    NavigationStack {
        AdoptAgentSheet()
    }
    .previewShell()
}

#Preview("新建 Botin · 深色英文、预选 Codex") {
    NavigationStack {
        AdoptAgentSheet(preselectedAgentID: DemoData.codexAgentID)
    }
    .previewShell(.english, scheme: .dark)
}
