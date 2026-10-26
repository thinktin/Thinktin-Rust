import SwiftUI
import ThinktinKit

/// 保险箱（`.vault`，WBS 12.13）：说明、条数（满 200 条提示）、等你填写的请求（点进去填）、条目（用途、能用的实例，点进详情）、
/// 填过 / 拒绝 / 过期的请求。右上角新建。离线时显示已经拉到的，写操作禁用。
struct VaultScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        VaultContent(model: VaultModel(client: client))
    }
}

private struct VaultContent: View {
    @State private var model: VaultModel
    @State private var isCreating = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: VaultModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                AgentsPageHeader(title: AppRoute.vault.title(language), message: VaultText.intro(language))
                if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let error = model.actionError {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                }
                if !model.hasLoaded {
                    if model.error == nil { AgentsLoadingView() }
                } else {
                    if !model.pendingRequests.isEmpty {
                        AgentsSectionHeader(title: zh ? "等你填写" : "Waiting for you")
                        AgentsGroup {
                            ForEach(model.pendingRequests) { request in
                                if request.id != model.pendingRequests.first?.id { Divider() }
                                requestRow(request)
                            }
                        }
                    }
                    AgentsSectionHeader(title: VaultText.count(model.items.count, language: language))
                    if model.isFull {
                        AgentsNotice(
                            systemImage: "exclamationmark.triangle", tone: .waiting, text: VaultText.full(language))
                    }
                    if model.items.isEmpty {
                        AgentsNotice(
                            systemImage: "key", tone: .neutral,
                            text: zh
                                ? "还没有条目。右上角新建，或者在对话里填 agent 要的账号密码。"
                                : "Nothing saved yet. Add one, or fill in what an agent asks for in a chat.")
                    } else {
                        AgentsGroup {
                            ForEach(model.items) { item in
                                if item.id != model.items.first?.id { Divider() }
                                AgentsRow(
                                    systemImage: "key", title: item.name,
                                    detail: [
                                        item.purpose.isEmpty ? nil : item.purpose,
                                        VaultText.instances(item, names: model.instanceNames, language: language),
                                    ].compactMap { $0 }.joined(separator: " · ")
                                ) {
                                    router.open(.vaultItem(item.id))
                                }
                            }
                        }
                    }
                    if !model.pastRequests.isEmpty {
                        AgentsSectionHeader(title: zh ? "处理过的请求" : "Past requests")
                        AgentsGroup {
                            ForEach(model.pastRequests) { request in
                                if request.id != model.pastRequests.first?.id { Divider() }
                                requestRow(request)
                            }
                        }
                    }
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.vault.title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(app.isOffline || !model.hasLoaded || model.isFull)
                .accessibilityLabel(Text(zh ? "新建条目" : "New item"))
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: router.topRoute) {
            // 从条目、请求页回来：可能改了、删了、填了。
            if router.topRoute == .vault && model.hasLoaded { Task { await model.load() } }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                VaultItemEditorView(itemID: nil) { item in
                    isCreating = false
                    if let item { model.upsert(item) }
                }
            }
        }
    }

    private func requestRow(_ request: VaultRequest) -> some View {
        let status = model.status(of: request)
        return AgentsRow(
            systemImage: status == .pending ? "key.horizontal" : "clock.arrow.circlepath", title: request.name,
            detail: [
                model.instanceNames[request.instanceID],
                status == .pending
                    ? VaultText.requestExpires(request.expiresAt, now: Date(), language: language)
                    : ConversationText.vaultStatus(status, name: request.name, language: language),
            ].compactMap { $0 }.joined(separator: " · "),
            detailTone: status == .pending ? .waiting : nil
        ) {
            router.open(.vaultRequest(request.id))
        }
    }
}

/// 一个条目（`.vaultItem(id)`）：引用（可以复制）、用途、账号（只显示账号，密码永远看不到）、能用的实例、时间；修改、删除。
struct VaultItemScreen: View {
    let itemID: VaultItemID

    @Environment(\.client) private var client

    var body: some View {
        VaultItemContent(model: VaultItemModel(client: client, itemID: itemID))
    }
}

private struct VaultItemContent: View {
    @State private var model: VaultItemModel
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false
    @State private var copied = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: VaultItemModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "key.slash", title: zh ? "找不到这个条目" : "Item not found",
                        message: zh ? "可能已经删掉了。" : "It may have been deleted.")
                } else if let detail = model.detail {
                    if let error = model.actionError {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                    }
                    content(detail)
                } else if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                } else {
                    AgentsLoadingView()
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(model.detail?.item.name ?? AppRoute.vaultItem(model.itemID).title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.detail != nil {
                    Button(zh ? "编辑" : "Edit") { isEditing = true }
                        .disabled(app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: model.isDeleted) {
            if model.isDeleted { router.pop() }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                VaultItemEditorView(itemID: model.itemID) { item in
                    isEditing = false
                    if item != nil { Task { await model.didSave() } }
                }
            }
        }
        .confirmationDialog(
            zh ? "删除“\(model.detail?.item.name ?? "")”？" : "Delete “\(model.detail?.item.name ?? "")”?",
            isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.delete() }
            } label: {
                Text(zh ? "删除" : "Delete")
            }
            Button(role: .cancel) {
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(
                zh
                    ? "删掉后 agent 再用 [vault:\(model.detail?.item.name ?? "")] 会失败，要重新填。"
                    : "Agents using [vault:\(model.detail?.item.name ?? "")] will fail until you add it again.")
        }
    }

    @ViewBuilder
    private func content(_ detail: VaultItemDetail) -> some View {
        let zh = language == .chinese
        let item = detail.item
        AgentsGroup {
            AgentsRow(
                systemImage: "curlybraces", title: item.reference,
                detail: copied
                    ? (zh ? "已复制" : "Copied") : (zh ? "在消息里这样写，agent 就能用它" : "Write this in a message to use it"),
                detailTone: copied ? .success : nil, showsChevron: false
            ) {
                Pasteboard.copy(item.reference)
                copied = true
            }
            if !item.purpose.isEmpty {
                Divider()
                AgentsRow(systemImage: "text.alignleft", title: zh ? "用途" : "Purpose", detail: item.purpose)
            }
            Divider()
            AgentsRow(
                systemImage: "person", title: zh ? "账号" : "Username",
                detail: detail.username.isEmpty ? (zh ? "没有账号" : "None") : detail.username)
            Divider()
            AgentsRow(
                systemImage: "lock", title: zh ? "密码" : "Password",
                detail: zh ? "已加密保存，谁都看不到明文（包括你）" : "Stored encrypted. Nobody can see it, including you.")
            Divider()
            AgentsRow(
                systemImage: "cpu", title: zh ? "能用它的实例" : "Instances",
                detail: VaultText.instances(item, names: model.instanceNames, language: language))
        }
        AgentsSectionHeader(title: zh ? "时间" : "Dates")
        AgentsGroup {
            AgentsRow(title: zh ? "创建" : "Created", detail: Formatting.relativeTime(item.createdAt, language: language))
            Divider()
            AgentsRow(title: zh ? "修改" : "Updated", detail: Formatting.relativeTime(item.updatedAt, language: language))
            Divider()
            AgentsRow(
                title: zh ? "上次使用" : "Last used",
                detail: item.lastUsedAt.map { Formatting.relativeTime($0, language: language) }
                    ?? (zh ? "还没用过" : "Never"))
        }
        Button(role: .destructive) {
            isConfirmingDeletion = true
        } label: {
            Text(zh ? "删除条目" : "Delete item")
                .typography(.subheadline)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StatusTone.failure.color)
        .disabled(app.isOffline || model.isDeleting)
    }
}

/// 新建 / 修改条目（sheet）：名字（新建时）、用途、账号、密码（修改时不填不改）、能用的实例。
struct VaultItemEditorView: View {
    let itemID: VaultItemID?
    /// 关掉（保存了带上条目，取消是 nil）。
    let onFinish: @MainActor (VaultItem?) -> Void

    @Environment(\.client) private var client

    var body: some View {
        VaultItemEditorContent(model: VaultItemEditorModel(client: client, itemID: itemID), onFinish: onFinish)
    }
}

private struct VaultItemEditorContent: View {
    @State private var model: VaultItemEditorModel
    let onFinish: @MainActor (VaultItem?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(model: VaultItemEditorModel, onFinish: @escaping @MainActor (VaultItem?) -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let problems = model.visibleProblems
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = model.saveError {
                    ErrorBanner(error, onDismiss: { model.clearSaveError() })
                }
                if !model.hasLoaded {
                    if let error = model.error {
                        ErrorBanner(error) { Task { await model.load() } }
                    } else {
                        AgentsLoadingView()
                    }
                } else {
                    if problems.contains(.full) {
                        AgentsNotice(
                            systemImage: "exclamationmark.triangle", tone: .waiting, text: VaultText.full(language))
                    }
                    if model.isEditing {
                        AgentsGroup {
                            AgentsRow(
                                systemImage: "key", title: model.name,
                                detail: zh ? "名字建好后不能改" : "The name can't be changed")
                        }
                    } else {
                        PlansTextField(
                            title: ConversationText.vaultNameField(language),
                            text: Binding(get: { model.name }, set: { model.setName($0) }), prompt: "github",
                            problem: problems.compactMap { problem -> String? in
                                if case .name = problem { return VaultText.formProblem(problem, language: language) }
                                return nil
                            }.first,
                            hint: model.renamedTo.map { VaultText.renamed($0, language: language) }
                                ?? (zh ? "消息里写成 [vault:名字]" : "Write it as [vault:name] in a message"),
                            monospaced: true)
                    }
                    PlansTextField(
                        title: ConversationText.vaultPurposeField(language), text: $model.purpose,
                        prompt: zh ? "比如：发布 npm 包" : "For example: publish npm packages", limit: VaultRules.maxPurpose,
                        count: model.purpose.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count,
                        problem: message(problems, .purposeTooLong) ?? message(problems, .controlCharacters))
                    PlansTextField(
                        title: ConversationText.vaultUsernameField(language), text: $model.username,
                        problem: message(problems, .usernameTooLong))
                    passwordField(problems)
                    instancesSection(problems)
                }
            }
            .agentsPageLayout()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .agentsNavigationTitle(model.isEditing ? (zh ? "修改条目" : "Edit item") : (zh ? "新建条目" : "New item"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onFinish(nil) }
                    .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isSaving ? (zh ? "正在保存…" : "Saving…") : (zh ? "保存" : "Save")) {
                    Task {
                        if let item = await model.save() { onFinish(item) }
                    }
                }
                .disabled(
                    model.isSaving || !model.hasLoaded || app.isOffline || (model.isEditing && !model.hasChanges))
            }
        }
        .interactiveDismissDisabled(model.hasChanges || model.isSaving)
        .task { await model.load() }
    }

    private func message(_ problems: [VaultFormProblem], _ problem: VaultFormProblem) -> String? {
        problems.contains(problem) ? VaultText.formProblem(problem, language: language) : nil
    }

    @ViewBuilder
    private func passwordField(_ problems: [VaultFormProblem]) -> some View {
        let zh = language == .chinese
        let problem = problems.compactMap { problem -> String? in
            if case .password = problem { return VaultText.formProblem(problem, language: language) }
            return nil
        }.first
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(zh ? "密码" : "Password")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            SecureField(zh ? "密码" : "Password", text: $model.password)
                .textFieldStyle(.plain)
                .vaultFieldStyle()
                .passwordContentType()
            Text(
                problem
                    ?? (model.isEditing
                        ? VaultText.passwordKept(language)
                        : (zh ? "只存加密后的，存进去后谁都看不到明文。" : "Only the encrypted form is stored; nobody can read it back."))
            )
            .typography(.footnote)
            .foregroundStyle(problem == nil ? Theme.inkSecondary : StatusTone.failure.color)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func instancesSection(_ problems: [VaultFormProblem]) -> some View {
        let zh = language == .chinese
        let model = self.model
        AgentsSectionHeader(title: zh ? "能用它的实例" : "Instances that can use it")
        AgentsGroup {
            AgentsChoiceRow(title: zh ? "所有实例" : "All instances", isSelected: model.allInstances) {
                model.allInstances = true
            }
            Divider()
            AgentsChoiceRow(title: zh ? "只给选中的实例" : "Only the ones I pick", isSelected: !model.allInstances) {
                model.allInstances = false
            }
        }
        if !model.allInstances {
            if let problem = message(problems, .noInstances) ?? message(problems, .tooManyInstances) {
                Text(problem)
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.failure.color)
                    .padding(.horizontal, Metrics.Spacing.xs)
            }
            AgentsGroup {
                ForEach(model.instances) { instance in
                    if instance.id != model.instances.first?.id { Divider() }
                    let isOn = model.selected.contains(instance.id)
                    Button {
                        model.toggle(instance.id)
                    } label: {
                        HStack(spacing: Metrics.Spacing.s) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isOn ? Theme.accent : Theme.inkTertiary)
                                .accessibilityHidden(true)
                            Text(verbatim: instance.name)
                                .typography(.body)
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Metrics.Spacing.m)
                        .frame(minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}

/// 填写请求（`.vaultRequest(id)`）：agent 要的账号密码，填好只进保险箱；已有同名条目的先提示会换掉它。处理过、过期了的显示结果。
struct VaultRequestScreen: View {
    let requestID: VaultRequestID

    @Environment(\.client) private var client

    var body: some View {
        VaultRequestContent(model: VaultRequestModel(client: client, requestID: requestID))
    }
}

private struct VaultRequestContent: View {
    @State private var model: VaultRequestModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: VaultRequestModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "key.slash", title: zh ? "找不到这个请求" : "Request not found",
                        message: zh ? "可能已经过期清理掉了。" : "It may have expired and been cleaned up.")
                } else if let request = model.request {
                    if let error = model.actionError {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                    }
                    content(request)
                } else if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                } else {
                    AgentsLoadingView()
                }
            }
            .agentsPageLayout()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.vaultRequest(model.requestID).title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    @ViewBuilder
    private func content(_ request: VaultRequest) -> some View {
        let zh = language == .chinese
        let model = self.model
        let status = model.status ?? request.status
        let problems = model.visibleProblems
        AgentsGroup {
            AgentsRow(
                systemImage: "key", title: ConversationText.vaultItemName(request.name, language: language),
                detail: model.instanceNames[request.instanceID].map { zh ? "实例：\($0)" : "Instance: \($0)" })
            if !request.purpose.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: request.purpose)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    AIGeneratedLabel()
                }
                .padding(.horizontal, Metrics.Spacing.m)
                .padding(.vertical, Metrics.Spacing.s)
            }
            if let runID = request.runID {
                Divider()
                AgentsRow(systemImage: "list.bullet.rectangle", title: zh ? "来自这次运行" : "From this run") {
                    router.open(.run(runID))
                }
            }
        }
        if status == .pending {
            NoticeText(
                text: VaultText.requestExpires(request.expiresAt, now: Date(), language: language), tone: .waiting)
            if let existing = model.existingItem {
                AgentsNotice(
                    systemImage: "arrow.triangle.2.circlepath", tone: .waiting,
                    text: VaultText.requestReplaces(existing.name, language: language))
            }
            if request.needsUsername {
                PlansTextField(
                    title: ConversationText.vaultField(.username, language: language), text: $model.username,
                    problem: problems.contains(.usernameTooLong)
                        ? VaultText.formProblem(.usernameTooLong, language: language) : nil)
            }
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                SecureField(ConversationText.vaultField(.password, language: language), text: $model.password)
                    .textFieldStyle(.plain)
                    .vaultFieldStyle()
                    .passwordContentType()
                if let problem = problems.compactMap({ problem -> String? in
                    if case .password = problem { return VaultText.formProblem(problem, language: language) }
                    return nil
                }).first {
                    Text(problem)
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                }
            }
            Text(ConversationText.vaultRequestNote(language))
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(ConversationText.vaultFulfill(language), systemImage: "lock") {
                Task { _ = await model.fulfill() }
            }
            .frame(maxWidth: .infinity)
            .disabled(model.password.isEmpty || model.isWorking || app.isOffline)
            PillButton(ConversationText.vaultDecline(language), kind: .secondary) {
                Task { _ = await model.decline() }
            }
            .frame(maxWidth: .infinity)
            .disabled(model.isWorking || app.isOffline)
            if model.isWorking { ProgressView().frame(maxWidth: .infinity) }
        } else {
            NoticeText(
                text: ConversationText.vaultStatus(status, name: request.name, language: language),
                tone: status == .fulfilled ? .success : .muted)
            if status == .fulfilled, let itemID = request.itemID {
                PillButton(zh ? "查看条目" : "View item", systemImage: "key", kind: .secondary) {
                    router.open(.vaultItem(itemID))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
