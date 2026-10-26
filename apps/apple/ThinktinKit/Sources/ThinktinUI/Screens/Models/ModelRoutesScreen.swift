import SwiftUI
import ThinktinKit

/// 实例的模型路由（`.modelRoutes(id)`，入口：实例详情、领养完成、引导、对话页“等待 key”的“去处理”）：
///
/// - 页头：实例名、agent、要什么协议的 key；数据去向的说明（发给哪些厂商）；有任务在等 key 时提一句；
/// - 每个别名一张卡片：main（必填、放第一个）、fast（可选，说明用途）、自定义的；选主 key（按 agent 的协议过滤、
///   停用的不列）、上游模型（选推荐的或手填）、降级链（最多 3 个备用，可以上下移）；
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
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = visibleError(model.error), model.isEditable {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.square.dashed",
                        title: zh ? "找不到这个实例" : "Instance not found",
                        message: zh ? "它可能已经被删除了。" : "It may have been deleted.",
                        actionTitle: zh ? "返回" : "Go back"
                    ) {
                        router.pop()
                    }
                } else if model.isEditable {
                    editor
                } else if model.isLoading || model.error == nil {
                    LoadingStateView()
                } else {
                    ModelsUnavailableView(error: model.error) { Task { await model.load() } }
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
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
                    Button(model.isSaving ? (zh ? "正在保存…" : "Saving…") : (zh ? "保存" : "Save")) { save() }
                        .disabled(!model.canSave || app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: router.sheet) {
            // 添加 key 的 sheet 关掉了：刷新 key，新 key 自动选进还没配的 main。
            if router.sheet == nil { Task { await model.refreshCredentials() } }
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
        header
        if let error = visibleError(model.detailsError) {
            ErrorBanner(error) { Task { await model.load() } }
        }
        InlineNotice(
            systemImage: "arrow.up.right.circle", tone: .neutral,
            text: ModelsText.routesDataSharing(
                instanceName: displayName, vendorNames: model.usedVendors(language).map(\.name), language: language))
        if let waiting = model.waitingRuns, waiting > 0, model.saveResult == nil {
            InlineNotice(
                systemImage: "hourglass", tone: .waiting,
                text: zh
                    ? "有 \(waiting) 个任务在等 key，配好保存后会接着跑。"
                    : "\(waiting) task(s) are waiting for a key; they resume once you save working routes.")
        }
        if model.hasNoUsableCredentials {
            noKeysCard
        } else if model.incompatibleCredentialCount > 0, let required = model.requiredProtocol {
            ModelsFootnote(
                text: zh
                    ? "另有 \(model.incompatibleCredentialCount) 把 key 不支持 \(ModelsText.protocolName(required))，\(model.agentName) 用不了，没列出来。"
                    : "\(model.incompatibleCredentialCount) other key(s) don't support "
                        + "\(ModelsText.protocolName(required)), so \(model.agentName) can't use them.")
        }
        ForEach(model.pageProblems, id: \.self) { problem in
            FieldMessage(text: problem.message(language))
        }
        ForEach(model.drafts) { draft in
            RouteCard(model: model, draftID: draft.id, canEdit: canWrite)
        }
        addAliasSection
        if let result = model.saveResult {
            InlineNotice(systemImage: "checkmark.circle", tone: .success, text: result.message(language))
        }
        if let error = model.saveError {
            ErrorBanner(error)
        }
        PillButton(
            model.isSaving ? (zh ? "正在保存…" : "Saving…") : (zh ? "保存路由" : "Save routes"),
            systemImage: model.isSaving ? nil : "checkmark"
        ) {
            save()
        }
        .disabled(!model.canSave || !canWrite)
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Spacing.s)
        if !canWrite {
            ModelsOfflineNote()
        } else if !model.hasChanges && model.saveResult == nil {
            Text(zh ? "没有要保存的修改。" : "Nothing to save.")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        let zh = language == .chinese
        var message = model.agentName
        if let required = model.requiredProtocol {
            message +=
                zh
                ? " · 要支持 \(ModelsText.protocolName(required)) 的 key"
                : " · needs keys that support \(ModelsText.protocolName(required))"
        }
        return PageHeader(title: displayName, message: message.isEmpty ? nil : message)
    }

    /// 实例的名字；实例本身没拉到（只拉到了路由）时写“这个实例”。
    private var displayName: String {
        let name = model.instanceName
        if !name.isEmpty { return name }
        return language == .chinese ? "这个实例" : "This instance"
    }

    private var noKeysCard: some View {
        let zh = language == .chinese
        let required = model.requiredProtocol.map(ModelsText.protocolName)
        return Card {
            Label {
                Text(
                    required.map {
                        zh
                            ? "还没有能给 \(model.agentName) 用的 key：要一把支持 \($0) 的。"
                            : "There's no key \(model.agentName) can use yet; it needs one that supports \($0)."
                    } ?? (zh ? "还没有能用的 key。" : "There's no usable key yet.")
                )
                .typography(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "key")
                    .foregroundStyle(StatusTone.waiting.color)
                    .accessibilityHidden(true)
            }
            PillButton(AppRoute.addCredential.title(language), systemImage: "plus", kind: .secondary, size: .compact) {
                router.open(.addCredential)
            }
            .disabled(!canWrite)
        }
    }

    private var addAliasSection: some View {
        let zh = language == .chinese
        let model = self.model
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            SectionHeader(title: zh ? "更多别名" : "More aliases")
            GroupedSection {
                if !model.hasFast {
                    ListRow(
                        systemImage: "hare", title: zh ? "加 fast 别名" : "Add the fast alias",
                        detail: ModelsText.fastPurpose(language),
                        action: model.canAddAlias && canWrite ? { @MainActor in _ = model.addFast() } : nil)
                    Divider()
                }
                ListRow(
                    systemImage: "plus", title: zh ? "加自定义别名" : "Add a custom alias",
                    detail: zh
                        ? "agent 按名字调用的别名，最多 \(RouteRules.maxAliases) 个。"
                        : "Aliases the agent calls by name, up to \(RouteRules.maxAliases).",
                    action: model.canAddAlias && canWrite ? { @MainActor in isAddingAlias = true } : nil)
            }
            ModelsFootnote(text: ModelsText.fallbackExplanation(language))
        }
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

/// 一个别名的卡片：名字和用途、主 key、上游模型、降级链。
private struct RouteCard: View {
    let model: ModelRoutesModel
    let draftID: RouteDraft.ID
    let canEdit: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        if let draft = model.draft(draftID) {
            let problems = model.problems(forRoute: draftID)
            Card {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                    Text(verbatim: draft.alias.isEmpty ? "—" : draft.alias)
                        .typography(.title3)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let tag = ModelsText.aliasTag(draft.alias, language: language) {
                        TagChip(text: tag)
                    }
                    Spacer(minLength: Metrics.Spacing.xs)
                    if !draft.isMain {
                        Button {
                            model.removeRoute(draftID)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEdit)
                        .accessibilityLabel(Text(zh ? "删掉别名 \(draft.alias)" : "Remove alias \(draft.alias)"))
                    }
                }
                Text(ModelsText.aliasPurpose(draft.alias, language: language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(problems.filter { $0 == .aliasInvalid || $0 == .aliasDuplicate }, id: \.self) { problem in
                    FieldMessage(text: problem.message(language))
                }
                RouteKeyPicker(
                    model: model, title: zh ? "主 key" : "Primary key", selection: draft.credentialID, canEdit: canEdit
                ) { id in
                    model.setCredential(id, forRoute: draftID)
                }
                if let problem = model.keyProblem(draft.credentialID) {
                    FieldMessage(text: problem.message(language))
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
                Divider()
                    .padding(.vertical, Metrics.Spacing.xxs)
                fallbacks(draft)
            }
        }
    }

    @ViewBuilder
    private func fallbacks(_ draft: RouteDraft) -> some View {
        let zh = language == .chinese
        Text(zh ? "降级链" : "Fallbacks")
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .accessibilityAddTraits(.isHeader)
        if draft.fallbacks.isEmpty {
            Text(zh ? "没有备用：主 key 出问题时任务会等 key。" : "No fallbacks: if the primary key fails, tasks wait for a key.")
                .typography(.footnote)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(draft.fallbacks.enumerated()), id: \.element.id) { index, fallback in
            FallbackEditor(
                model: model, draftID: draftID, fallback: fallback, position: index + 1,
                isLast: index == draft.fallbacks.count - 1, canEdit: canEdit)
        }
        if draft.fallbacks.count < ModelRoute.maxFallbacks {
            PillButton(zh ? "加备用 key" : "Add a fallback", systemImage: "plus", kind: .secondary, size: .compact) {
                _ = model.addFallback(toRoute: draftID)
            }
            .disabled(!canEdit)
        }
    }
}

/// 降级链里的一项：第几个、上下移、删掉、key、模型。
private struct FallbackEditor: View {
    let model: ModelRoutesModel
    let draftID: RouteDraft.ID
    let fallback: FallbackDraft
    let position: Int
    let isLast: Bool
    let canEdit: Bool

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let zh = language == .chinese
        let title = ModelsText.fallbackTitle(position, language: language)
        let fallbackID = fallback.id
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(spacing: Metrics.Spacing.xxs) {
                Text(title)
                    .typography(.subheadline)
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
                FieldMessage(text: problem.message(language))
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
        .padding(Metrics.Spacing.s)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale))
        }
    }

    private func iconButton(
        _ systemImage: String, label: String, disabled: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typography.footnote.font.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || !canEdit)
        .accessibilityLabel(Text(label))
    }
}

/// 选 key：系统菜单，列出能选的 key（按协议过滤过、没停用的），选中的打勾。
private struct RouteKeyPicker: View {
    let model: ModelRoutesModel
    let title: String
    let selection: CredentialID?
    let canEdit: Bool
    let onSelect: @MainActor (CredentialID) -> Void

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let zh = language == .chinese
        let options = model.selectableCredentials
        let current = model.credentialTitle(selection, language: language)
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        Menu {
            ForEach(options) { credential in
                Button {
                    onSelect(credential.id)
                } label: {
                    if credential.id == selection {
                        Label(model.credentialTitle(credential.id, language: language), systemImage: "checkmark")
                    } else {
                        Text(model.credentialTitle(credential.id, language: language))
                    }
                }
            }
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                Image(systemName: "key")
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(title)
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    Text(current)
                        .typography(.body)
                        .foregroundStyle(selection == nil ? Theme.inkTertiary : Theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typography.footnote.font)
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.Spacing.s)
            .padding(.vertical, Metrics.Spacing.xs)
            .frame(minHeight: Metrics.minTapTarget)
            .background(Theme.paperElevated, in: shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
            .contentShape(Rectangle())
        }
        .disabled(!canEdit || options.isEmpty)
        .accessibilityLabel(Text(title + (zh ? "：" : ": ") + current))
        .accessibilityHint(
            Text(options.isEmpty ? (zh ? "还没有能用的 key" : "No usable keys yet") : (zh ? "选一把 key" : "Choose a key")))
    }
}

/// 上游模型：输入框，右边是厂商推荐的模型菜单（自定义地址没有）。
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
        HStack(alignment: .top, spacing: Metrics.Spacing.xs) {
            ModelsField(
                title: zh ? "上游模型" : "Upstream model", text: text,
                prompt: suggestions.first ?? (zh ? "厂商那边的模型名" : "The vendor's model name"),
                kind: .identifier,
                problem: problem,
                hint: suggestions.isEmpty
                    ? (zh ? "填厂商那边的模型名。" : "Enter the model name used by the vendor.")
                    : (zh ? "可以选推荐的，也可以手填。" : "Pick a recommended one or type your own.")
            )
            .disabled(!canEdit)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { name in
                        Button {
                            text.wrappedValue = name
                        } label: {
                            if name == text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(Theme.accent)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .disabled(!canEdit)
                // 和输入框对齐（上面有一行小标题）。
                .padding(.top, Metrics.Spacing.l)
                .accessibilityLabel(Text(zh ? "推荐的模型" : "Recommended models"))
            }
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
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
