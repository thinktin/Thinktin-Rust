import SwiftUI
import ThinktinKit

/// 实例的模型路由（`.modelRoutes(id)`，入口：实例详情、领养完成、引导、对话页“等待 key”的“去处理”）：
///
/// - 页头：实例名、agent、要什么协议的 key；数据去向的说明（发给哪些厂商）；有任务在等 key 时提一句；
/// - 改版成 insetGrouped `List`（规范 7.3 E，参考里没有这一页）：每个别名一组（`RouteSection`）：main（必填、放第一个）、
///   fast（可选，说明用途）、自定义的；选主 key（系统 `Picker(.menu)`，按引擎的协议过滤、停用的不列）、上游模型（标签在上的输入框
///   + 推荐菜单）、降级链（最多 3 个备用，可以上下移）；保存在右上（`ConfirmButton`）；
/// - 没有能用的 key 时给“添加 key”（弹 `.addCredential`，关掉后自动选上新 key）；
/// - 保存：路由里有没同意过数据共享的厂商时先确认；保存后说唤醒了几个等 key 的任务，刷新抽屉的等待状态。
/// - 改过没保存时返回按钮换成“放弃修改”（确认后才走）。
struct ModelRoutesScreen: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app

    var body: some View {
        ModelRoutesContent(
            client: client, instanceID: instanceID, instance: app.instances.first { $0.id == instanceID })
    }
}

private struct ModelRoutesContent: View {
    @State private var model: ModelRoutesModel
    @State private var isAddingAlias = false
    @State private var newAlias = ""
    @State private var isConfirmingDiscard = false
    /// 等确认数据共享的厂商（非空时弹确认框）。
    @State private var pendingConsent: [ConsentVendor] = []

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, instanceID: InstanceID, instance: Instance?) {
        _model = State(initialValue: ModelRoutesModel(client: client, instanceID: instanceID, instance: instance))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let isDirty = model.hasUserEdits && model.hasChanges
        List {
            if let error = visibleError(model.error), model.isEditable {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                .clearListRow()
            }
            if model.isEditable && !model.isMissing {
                editor
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.isMissing {
                ContentUnavailableView {
                    Label(zh ? "找不到这个 Botin" : "Botin not found", systemImage: "questionmark.square.dashed")
                } description: {
                    Text(zh ? "它可能已经被删除了。" : "It may have been deleted.")
                } actions: {
                    Button(zh ? "返回" : "Go back") { router.pop() }
                        .glassButtonStyle()
                }
            } else if !model.isEditable {
                if model.isLoading || model.error == nil {
                    ProgressView()
                } else {
                    ModelsUnavailableView(error: model.error) { Task { await model.load() } }
                }
            }
        }
        .inlineNavigationTitle(AppRoute.modelRoutes(model.instanceID).title(language))
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isDirty {
                    Button(zh ? "放弃修改" : "Discard") { isConfirmingDiscard = true }
                        .disabled(model.isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.isEditable {
                    ConfirmButton(zh ? "保存" : "Save", isWorking: model.isSaving) { save() }
                        .disabled(!model.canSave || app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: router.visibleRoute) {
            // 添加 key 的 sheet 关掉了（这一页在 sheet 里时是叠在上面的第二层）：刷新 key，新 key 自动选进还没配的 main。
            if router.visibleRoute == .modelRoutes(model.instanceID) { Task { await model.refreshCredentials() } }
        }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .confirmationDialog(
            zh ? "放弃没保存的修改？" : "Discard unsaved changes?", isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(zh ? "放弃修改" : "Discard changes", role: .destructive) {
                model.discardChanges()
                router.pop()
            }
            Button(zh ? "继续编辑" : "Keep editing", role: .cancel) {}
        }
        .confirmationDialog(
            zh ? "把对话发给这些厂商？" : "Send conversations to these vendors?",
            isPresented: Binding(get: { !pendingConsent.isEmpty }, set: { if !$0 { pendingConsent = [] } }),
            titleVisibility: .visible
        ) {
            Button(zh ? "同意并保存" : "Agree and save") {
                pendingConsent = []
                commitSave(consented: true)
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(
                ModelsText.routesConsentNotice(
                    instanceName: displayName, vendorNames: pendingConsent.map(\.name), language: language))
        }
        .alert(zh ? "加一个别名" : "Add an alias", isPresented: $isAddingAlias) {
            TextField(zh ? "别名，比如 vision" : "Alias, e.g. vision", text: $newAlias)
                .modelsIdentifierInput()
            Button(zh ? "加上" : "Add") {
                _ = model.addAlias(newAlias)
                newAlias = ""
            }
            .disabled(model.aliasProblem(newAlias) != nil)
            Button(zh ? "取消" : "Cancel", role: .cancel) { newAlias = "" }
        } message: {
            Text(aliasHint)
        }
    }

    // MARK: 编辑

    @ViewBuilder
    private var editor: some View {
        let zh = language == .chinese
        let model = self.model
        Section {
            header
        }
        .clearListRow()
        Section {
            if let error = visibleError(model.detailsError) {
                ErrorBanner(error) { Task { await model.load() } }
            }
            Label(
                ModelsText.routesDataSharing(
                    instanceName: displayName, vendorNames: model.usedVendors(language).map(\.name),
                    language: language),
                systemImage: "arrow.up.right.circle"
            )
            .font(.subheadline)
            .foregroundStyle(Theme.inkSecondary)
            if let waiting = model.waitingRuns, waiting > 0, model.saveResult == nil {
                Label(
                    zh
                        ? "有 \(waiting) 个任务在等 key，配好保存后会接着跑。"
                        : "\(waiting) task(s) are waiting for a key; they resume once you save working routes.",
                    systemImage: "hourglass"
                )
                .foregroundStyle(StatusTone.waiting.color)
            }
            if model.hasNoUsableCredentials {
                noKeysRows
            }
            ForEach(model.pageProblems, id: \.self) { problem in
                Text(problem.message(language))
                    .foregroundStyle(Theme.danger)
            }
            if let result = model.saveResult {
                Label(result.message(language), systemImage: "checkmark.circle")
                    .foregroundStyle(StatusTone.success.color)
            }
            if let error = model.saveError {
                ErrorBanner(error)
            }
        } footer: {
            if !model.hasNoUsableCredentials, model.incompatibleCredentialCount > 0,
                let required = model.requiredProtocol
            {
                Text(
                    zh
                        ? "另有 \(model.incompatibleCredentialCount) 把 key 不支持 \(ModelsText.protocolName(required))，\(model.agentName) 用不了，没列出来。"
                        : "\(model.incompatibleCredentialCount) other key(s) don't support "
                            + "\(ModelsText.protocolName(required)), so \(model.agentName) can't use them.")
            } else if !canWrite {
                Text(zh ? "离线时不能修改，联网后再试。" : "You can't make changes while offline.")
            }
        }
        .themedRow()
        ForEach(model.drafts) { draft in
            RouteSection(model: model, draftID: draft.id, canEdit: canWrite)
        }
        addAliasSection
    }

    /// 页面头部：Botin 的名字、引擎和要的协议（标题已经是“模型路由”）。
    private var header: some View {
        let zh = language == .chinese
        var message = model.agentName
        if let required = model.requiredProtocol {
            message +=
                zh
                ? " · 要支持 \(ModelsText.protocolName(required)) 的 key"
                : " · needs keys that support \(ModelsText.protocolName(required))"
        }
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(displayName)
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.Spacing.xs)
    }

    /// 实例的名字；实例本身没拉到（只拉到了路由）时写“这个 Botin”。
    private var displayName: String {
        let name = model.instanceName
        if !name.isEmpty { return name }
        return language == .chinese ? "这个 Botin" : "This Botin"
    }

    @ViewBuilder
    private var noKeysRows: some View {
        let zh = language == .chinese
        let required = model.requiredProtocol.map(ModelsText.protocolName)
        Label(
            required.map {
                zh
                    ? "还没有能给 \(model.agentName) 用的 key：要一把支持 \($0) 的。"
                    : "There's no key \(model.agentName) can use yet; it needs one that supports \($0)."
            } ?? (zh ? "还没有能用的 key。" : "There's no usable key yet."),
            systemImage: "key"
        )
        .foregroundStyle(StatusTone.waiting.color)
        Button(AppRoute.addCredential.title(language)) { router.open(.addCredential) }
            .disabled(!canWrite)
    }

    private var addAliasSection: some View {
        let zh = language == .chinese
        let model = self.model
        return Section {
            if !model.hasFast {
                Button {
                    _ = model.addFast()
                } label: {
                    SettingsRowLabel(
                        title: zh ? "加 fast 别名" : "Add the fast alias", subtitle: ModelsText.fastPurpose(language),
                        subtitleLineLimit: nil)
                }
                .disabled(!model.canAddAlias || !canWrite)
            }
            Button {
                isAddingAlias = true
            } label: {
                SettingsRowLabel(
                    title: zh ? "加自定义别名" : "Add a custom alias",
                    subtitle: zh
                        ? "Botin 按名字调用的别名，最多 \(RouteRules.maxAliases) 个。"
                        : "Aliases the Botin calls by name, up to \(RouteRules.maxAliases).",
                    subtitleLineLimit: nil)
            }
            .disabled(!model.canAddAlias || !canWrite)
        } header: {
            Text(zh ? "更多别名" : "More aliases").groupHeader()
        } footer: {
            Text(ModelsText.fallbackExplanation(language))
        }
        .themedRow()
    }

    /// 离线时不能改。
    private var canWrite: Bool { !app.isOffline }

    /// 加别名的弹窗里的说明：输入有问题时说问题，否则说格式规则。
    private var aliasHint: String {
        if let problem = model.aliasProblem(newAlias), problem != .empty { return problem.message(language) }
        return AliasProblem.invalid.message(language)
    }

    // MARK: 保存

    private func save() {
        let pending = model.vendorsNeedingConsent(language)
        if !pending.isEmpty {
            pendingConsent = pending
            return
        }
        commitSave(consented: false)
    }

    private func commitSave(consented: Bool) {
        let model = self.model
        let app = self.app
        Task {
            if await model.save(consented: consented) {
                // 唤醒了等 key 的任务：抽屉里的等待状态跟着变。
                await app.refreshBadges()
            }
        }
    }
}

/// 一个别名一组（分组列表的 `Section`）：标题是别名和标签，行是用途、主 key（系统 `Picker(.menu)`）、上游模型（输入框 + 推荐菜单）、
/// 降级链（每个备用一行标题带上移 / 下移 / 删掉，再一行 key、一行模型）、“加备用 key”，不是 main 的最后红字“删掉这个别名”。
private struct RouteSection: View {
    let model: ModelRoutesModel
    let draftID: RouteDraft.ID
    let canEdit: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        if let draft = model.draft(draftID) {
            let problems = model.problems(forRoute: draftID)
            Section {
                Text(ModelsText.aliasPurpose(draft.alias, language: language))
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                ForEach(problems.filter { $0 == .aliasInvalid || $0 == .aliasDuplicate }, id: \.self) { problem in
                    Text(problem.message(language)).foregroundStyle(Theme.danger)
                }
                RouteKeyPicker(
                    model: model, title: zh ? "主 key" : "Primary key", selection: draft.credentialID, canEdit: canEdit
                ) { id in
                    model.setCredential(id, forRoute: draftID)
                }
                if let problem = model.keyProblem(draft.credentialID) {
                    Text(problem.message(language)).foregroundStyle(Theme.danger)
                } else if model.keepsDisabledKey(draft.credentialID) {
                    RouteKeptKeyNotice()
                }
                RouteModelField(
                    model: model,
                    text: Binding(
                        get: { model.draft(draftID)?.upstreamModel ?? "" },
                        set: { model.setModel($0, forRoute: draftID) }),
                    credentialID: draft.credentialID,
                    problem: model.modelProblem(draft.upstreamModel)?.message(language),
                    canEdit: canEdit)
                ForEach(Array(draft.fallbacks.enumerated()), id: \.element.id) { index, fallback in
                    FallbackRows(
                        model: model, draftID: draftID, fallback: fallback, position: index + 1,
                        isLast: index == draft.fallbacks.count - 1, canEdit: canEdit)
                }
                if draft.fallbacks.count < ModelRoute.maxFallbacks {
                    Button {
                        _ = model.addFallback(toRoute: draftID)
                    } label: {
                        Label(zh ? "加备用 key" : "Add a fallback", systemImage: "plus")
                    }
                    .disabled(!canEdit)
                }
                if !draft.isMain {
                    Button(zh ? "删掉这个别名" : "Remove this alias", role: .destructive) {
                        model.removeRoute(draftID)
                    }
                    .foregroundStyle(Theme.danger)
                    .disabled(!canEdit)
                }
            } header: {
                HStack(spacing: Metrics.Spacing.xs) {
                    Text(verbatim: draft.alias.isEmpty ? "—" : draft.alias)
                    if let tag = ModelsText.aliasTag(draft.alias, language: language) {
                        Text("· " + tag)
                    }
                }
                .groupHeader()
                .accessibilityAddTraits(.isHeader)
            } footer: {
                if draft.fallbacks.isEmpty {
                    Text(
                        zh
                            ? "没有备用：主 key 出问题时任务会等 key。"
                            : "No fallbacks: if the primary key fails, tasks wait for a key.")
                }
            }
            .themedRow()
        }
    }
}

/// 降级链里的一项（几行）：“备用 N”和上移、下移、删掉，key、模型。
private struct FallbackRows: View {
    let model: ModelRoutesModel
    let draftID: RouteDraft.ID
    let fallback: FallbackDraft
    let position: Int
    let isLast: Bool
    let canEdit: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let title = ModelsText.fallbackTitle(position, language: language)
        let fallbackID = fallback.id
        HStack(spacing: Metrics.Spacing.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Metrics.Spacing.xs)
            iconButton("chevron.up", label: zh ? "\(title)上移" : "Move \(title) up", disabled: position == 1) {
                model.moveFallback(fallbackID, inRoute: draftID, by: -1)
            }
            iconButton("chevron.down", label: zh ? "\(title)下移" : "Move \(title) down", disabled: isLast) {
                model.moveFallback(fallbackID, inRoute: draftID, by: 1)
            }
            iconButton("xmark", label: zh ? "删掉\(title)" : "Remove \(title)", disabled: false) {
                model.removeFallback(fallbackID, fromRoute: draftID)
            }
        }
        RouteKeyPicker(
            model: model, title: zh ? "备用 key" : "Fallback key", selection: fallback.credentialID, canEdit: canEdit
        ) { id in
            model.setFallbackCredential(id, fallback: fallbackID, route: draftID)
        }
        if let problem = model.keyProblem(fallback.credentialID) {
            Text(problem.message(language)).foregroundStyle(Theme.danger)
        } else if model.keepsDisabledKey(fallback.credentialID) {
            RouteKeptKeyNotice()
        }
        RouteModelField(
            model: model,
            text: Binding(
                get: { model.draft(draftID)?.fallbacks.first { $0.id == fallbackID }?.upstreamModel ?? "" },
                set: { model.setFallbackModel($0, fallback: fallbackID, route: draftID) }),
            credentialID: fallback.credentialID,
            problem: model.modelProblem(fallback.upstreamModel)?.message(language),
            canEdit: canEdit)
    }

    private func iconButton(
        _ systemImage: String, label: String, disabled: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(disabled || !canEdit)
    }
}

/// 选 key：系统 `Picker(.menu)`（行内左边标题、右边选中的 key），列出能选的 key（按协议过滤过、没停用的）；现在选的不在里面
/// （留着的停用 key）时也列上，没选时是“未选”。
private struct RouteKeyPicker: View {
    let model: ModelRoutesModel
    let title: String
    let selection: CredentialID?
    let canEdit: Bool
    let onSelect: @MainActor (CredentialID) -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let options = model.selectableCredentials
        Picker(
            selection: Binding(get: { selection }, set: { id in if let id { onSelect(id) } })
        ) {
            if selection == nil {
                Text(zh ? "未选" : "None").tag(CredentialID?.none)
            } else if let selection, !options.contains(where: { $0.id == selection }) {
                Text(model.credentialTitle(selection, language: language)).tag(CredentialID?.some(selection))
            }
            ForEach(options) { credential in
                Text(model.credentialTitle(credential.id, language: language)).tag(CredentialID?.some(credential.id))
            }
        } label: {
            Text(title)
        }
        .pickerStyle(.menu)
        .disabled(!canEdit || options.isEmpty)
        .accessibilityHint(
            Text(options.isEmpty ? (zh ? "还没有能用的 key" : "No usable keys yet") : (zh ? "选一把 key" : "Choose a key")))
    }
}

/// 上游模型：标签在上的输入框，右边是厂商推荐的模型菜单（自定义地址没有）；问题或说明在下面。
private struct RouteModelField: View {
    let model: ModelRoutesModel
    let text: Binding<String>
    let credentialID: CredentialID?
    let problem: String?
    let canEdit: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let suggestions = model.suggestedModels(for: credentialID)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            VaultLabeledField(title: zh ? "上游模型" : "Upstream model") {
                HStack {
                    TextField(suggestions.first ?? (zh ? "厂商那边的模型名" : "The vendor's model name"), text: text)
                        .fontDesign(.monospaced)
                        .modelsIdentifierInput()
                        .disabled(!canEdit)
                    if !suggestions.isEmpty {
                        Menu {
                            Picker(
                                selection: Binding(
                                    get: { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) },
                                    set: { text.wrappedValue = $0 })
                            ) {
                                ForEach(suggestions, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label(zh ? "推荐的模型" : "Recommended models", systemImage: "list.bullet")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canEdit)
                    }
                }
            }
            Text(
                problem
                    ?? (suggestions.isEmpty
                        ? (zh ? "填厂商那边的模型名。" : "Enter the model name used by the vendor.")
                        : (zh ? "可以选推荐的，也可以手填。" : "Pick a recommended one or type your own."))
            )
            .font(.footnote)
            .foregroundStyle(problem == nil ? Theme.inkSecondary : Theme.danger)
        }
    }
}

#Preview("模型路由 · 浅色中文") {
    ModelRoutesScreen(instanceID: DemoData.writerID).previewShell()
}

#Preview("模型路由 · 深色英文") {
    ModelRoutesScreen(instanceID: DemoData.reviewerID).previewShell(.english, scheme: .dark)
}

#Preview("模型路由 · 还没配、有任务在等 key") {
    ModelRoutesScreen(instanceID: DemoData.writerID).previewShell(client: ModelsPreviewClients.waitingForKey())
}

#Preview("模型路由 · 没有 key · 深色英文") {
    ModelRoutesScreen(instanceID: DemoData.writerID)
        .previewShell(.english, scheme: .dark, client: ModelsPreviewClients.noKeys())
}

/// 别名里留着的停用 key（11.9：实例原来就用着的可以留着）：提示一句，不是错误。
private struct RouteKeptKeyNotice: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        Label(ModelsText.keptDisabledKeyNotice(language), systemImage: "pause.circle")
            .font(.footnote)
            .foregroundStyle(Theme.inkSecondary)
    }
}
