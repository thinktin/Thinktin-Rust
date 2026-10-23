import SwiftUI
import ThinktinKit

/// key 详情（`.credential(id)`，入口：key 列表、用量看板的“按 key”）：
///
/// - 头部：厂商首字头像、名字（改备注）、厂商和后 4 位；
/// - 启用开关：停用还在用的 key 前先确认；启用、换 key 后服务端唤醒等 key 的任务，页面说唤醒了几个；
/// - 换 key（`replaceCredentialSecret`，路由不用改）；信息：厂商、协议、每日上限（只能添加时设）、添加时间；
/// - 最近 30 天的用量；用在哪些实例的哪些别名（点开去那个实例的路由）；
/// - 删除：还在路由里的不让删，先去改路由。
struct CredentialDetailScreen: View {
    let credentialID: CredentialID

    @Environment(\.client) private var client

    var body: some View {
        CredentialDetailContent(client: client, credentialID: credentialID)
    }
}

private struct CredentialDetailContent: View {
    @State private var model: CredentialDetailModel
    @State private var isRenaming = false
    @State private var isReplacing = false
    @State private var isConfirmingDisable = false
    @State private var isConfirmingDelete = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, credentialID: CredentialID) {
        _model = State(initialValue: CredentialDetailModel(client: client, credentialID: credentialID))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = agentsVisibleError(model.error), model.credential != nil {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let summary = model.summary(language), !model.isMissing {
                    header(summary)
                    statusSection(summary)
                    keySection
                    infoSection
                    usageSection
                    referencesSection
                    deleteSection
                } else if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.square.dashed", title: zh ? "找不到这把 key" : "Key not found",
                        message: zh ? "它可能已经被删除了。" : "It may have been deleted.",
                        actionTitle: zh ? "返回" : "Go back"
                    ) {
                        router.pop()
                    }
                } else if model.isLoading || model.error == nil {
                    AgentsLoadingView()
                } else {
                    ModelsUnavailableView(error: model.error) { Task { await model.load() } }
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(model.summary(language)?.name ?? AppRoute.credential(model.credentialID).title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.credential != nil && !model.isMissing {
                    Menu {
                        Button {
                            isRenaming = true
                        } label: {
                            Label(zh ? "改备注" : "Edit note", systemImage: "pencil")
                        }
                        Button {
                            isReplacing = true
                        } label: {
                            Label(zh ? "换 key" : "Replace key", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label(zh ? "删除 key" : "Delete key", systemImage: "trash")
                        }
                        .disabled(!model.canDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel(Text(zh ? "更多操作" : "More"))
                    }
                    .disabled(app.isOffline)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .confirmationDialog(
            zh ? "停用这把 key？" : "Disable this key?", isPresented: $isConfirmingDisable, titleVisibility: .visible
        ) {
            Button(zh ? "停用" : "Disable", role: .destructive) {
                Task { await model.setDisabled(true) }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(model.disableWarning(language) ?? "")
        }
        .confirmationDialog(
            zh ? "删除这把 key？" : "Delete this key?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button(zh ? "删除" : "Delete", role: .destructive) {
                let router = self.router
                Task {
                    if await model.delete() { router.pop() }
                }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(
                zh
                    ? "删除后不能恢复，平台上的密文一起清掉。厂商那边的 key 不受影响，需要的话去厂商控制台作废它。"
                    : "This can't be undone; the encrypted copy is wiped. The key itself stays valid at the vendor; "
                        + "revoke it in the vendor's console if needed.")
        }
        .sheet(
            isPresented: $isRenaming, onDismiss: { model.clearRenameError() },
            content: {
                NavigationStack {
                    CredentialRenameSheet(model: model) { isRenaming = false }
                }
                .shellEnvironment(app)
                .tint(Theme.accent)
            }
        )
        .sheet(
            isPresented: $isReplacing, onDismiss: { model.clearReplaceErrors() },
            content: {
                NavigationStack {
                    ReplaceCredentialSheet(model: model) { isReplacing = false }
                }
                .shellEnvironment(app)
                .tint(Theme.accent)
            }
        )
    }

    /// 离线时不能改。
    private var canWrite: Bool { !app.isOffline }

    // MARK: 各部分

    private func header(_ summary: CredentialSummary) -> some View {
        let zh = language == .chinese
        return HStack(alignment: .top, spacing: Metrics.Spacing.s) {
            AgentMonogram(summary.monogram, style: .title, size: 56)
                .opacity(summary.isDisabled ? 0.5 : 1)
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                Text(summary.name)
                    .typography(.title)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(summary.subtitle)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityLabel(Text(summary.accessibilityLabel(language)))
            }
            Spacer(minLength: Metrics.Spacing.xs)
            Button {
                isRenaming = true
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canWrite)
            .accessibilityLabel(Text(zh ? "改备注" : "Edit note"))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statusSection(_ summary: CredentialSummary) -> some View {
        let zh = language == .chinese
        let model = self.model
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            Card {
                Toggle(
                    isOn: Binding(
                        get: { !(model.credential?.isDisabled ?? false) },
                        set: { enabled in
                            if !enabled && model.disableWarning(language) != nil {
                                isConfirmingDisable = true
                            } else {
                                let app = self.app
                                Task {
                                    // 启用后服务端唤醒等 key 的任务：抽屉里的等待状态跟着变。
                                    if await model.setDisabled(!enabled), enabled { await app.refreshBadges() }
                                }
                            }
                        })
                ) {
                    VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                        Text(zh ? "启用" : "Enabled")
                            .typography(.headline)
                            .foregroundStyle(Theme.ink)
                        Text(
                            summary.isDisabled
                                ? (zh
                                    ? "已停用：用它的别名改用备用 key，没有备用的任务会等 key。"
                                    : "Disabled: aliases using it switch to fallbacks; others wait for a key.")
                                : ModelsText.wakeExplanation(language)
                        )
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!canWrite || model.isTogglingDisabled)
                .tint(Theme.accent)
            }
            if let error = model.toggleError {
                ErrorBanner(error)
            }
            wakeNotice
        }
    }

    @ViewBuilder
    private var wakeNotice: some View {
        let zh = language == .chinese
        if model.didWake {
            AgentsNotice(
                systemImage: "arrow.clockwise.circle", tone: .success,
                text: model.wakeResult?.message(language)
                    ?? (model.wakeResult == nil
                        ? ModelsText.wakeExplanation(language)
                        : (zh ? "现在没有在等 key 的任务。" : "No tasks are waiting for a key right now.")))
        }
    }

    private var keySection: some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "key" : "Key")
            if model.didReplace, let credential = model.credential {
                AgentsNotice(
                    systemImage: "checkmark.circle", tone: .success,
                    text: zh ? "已换成 \(credential.maskedKey)。" : "Replaced with \(credential.maskedKey).")
            }
            AgentsGroup {
                AgentsRow(
                    systemImage: "arrow.triangle.2.circlepath", title: zh ? "换 key" : "Replace key",
                    detail: zh
                        ? "在厂商那边换了 key、旧的泄露了时用，模型路由不用改。"
                        : "Use this when you rotate the key at the vendor or the old one leaked. Routes stay as they are.",
                    action: canWrite ? { @MainActor in isReplacing = true } : nil)
            }
        }
    }

    private var infoSection: some View {
        let zh = language == .chinese
        let credential = model.credential
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "信息" : "Details")
            AgentsGroup {
                AgentsRow(
                    systemImage: "building.2", title: zh ? "厂商" : "Vendor",
                    detail: credential.map {
                        ModelsText.vendorName($0.vendor, vendors: model.vendors, language: language)
                    })
                Divider()
                AgentsRow(
                    systemImage: "point.3.connected.trianglepath.dotted", title: zh ? "支持的协议" : "Protocols",
                    detail: credential.flatMap { ModelsText.protocolList($0.protocols, language: language) }
                        ?? (zh ? "服务端没给" : "Not reported"))
                Divider()
                AgentsRow(
                    systemImage: "gauge.with.dots.needle.33percent", title: zh ? "每日上限" : "Daily limit",
                    detail: ModelsText.dailyLimit(credential?.dailyTokenLimit, language: language))
                Divider()
                AgentsRow(
                    systemImage: "calendar.badge.plus", title: zh ? "添加于" : "Added",
                    detail: credential.map { Formatting.dateTime($0.createdAt, language: language) })
            }
            ModelsFootnote(text: ModelsText.dailyLimitFootnote(language))
        }
    }

    private var usageSection: some View {
        let zh = language == .chinese
        let detail: String
        if let usage = model.recentUsage {
            detail =
                Formatting.tokens(usage.totalTokens, language: language) + " tokens · "
                + UsageText.requestsLine(usage, language: language)
        } else {
            detail = zh ? "正在统计…" : "Loading…"
        }
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "用量" : "Usage")
            AgentsGroup {
                AgentsRow(
                    systemImage: "chart.bar",
                    title: zh
                        ? "最近 \(CredentialDetailModel.usageDays) 天" : "Last \(CredentialDetailModel.usageDays) days",
                    detail: detail, action: { router.open(.usage) })
            }
        }
    }

    private var referencesSection: some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "用在哪里" : "Used by")
            if let error = agentsVisibleError(model.detailsError) {
                ErrorBanner(error) { Task { await model.load() } }
            }
            AgentsGroup {
                if let references = model.references {
                    if references.isEmpty {
                        AgentsRow(
                            systemImage: "slider.horizontal.3", title: zh ? "还没有实例用它" : "No instance uses it yet",
                            detail: zh ? "在实例的模型路由里选它。" : "Pick it in an instance's model routes.")
                    }
                    ForEach(references) { reference in
                        if reference.id != references.first?.id { Divider() }
                        AgentsRow(
                            systemImage: reference.isFallback ? "arrow.turn.down.right" : "slider.horizontal.3",
                            title: reference.instanceName + " · " + reference.alias,
                            detail: reference.role(language),
                            action: { router.open(.modelRoutes(reference.instanceID)) })
                    }
                } else {
                    AgentsRow(
                        systemImage: "hourglass", title: zh ? "正在查模型路由…" : "Checking model routes…",
                        showsChevron: false)
                }
            }
        }
    }

    private var deleteSection: some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let message = model.deleteErrorMessage(language) {
                AgentsNotice(systemImage: "exclamationmark.triangle", tone: .failure, text: message)
            }
            PillButton(zh ? "删除 key" : "Delete key", systemImage: "trash", kind: .destructive) {
                isConfirmingDelete = true
            }
            .disabled(!model.canDelete || !canWrite)
            .frame(maxWidth: .infinity)
            if let reason = model.deleteBlockedReason(language) {
                Text(reason)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, Metrics.Spacing.l)
    }
}

/// 改备注（key 详情弹出）。
struct CredentialRenameSheet: View {
    let model: CredentialDetailModel
    let onClose: @MainActor () -> Void

    @State private var draft: String
    @Environment(\.displayLanguage) private var language

    init(model: CredentialDetailModel, onClose: @escaping @MainActor () -> Void) {
        self.model = model
        self.onClose = onClose
        _draft = State(initialValue: model.credential?.label ?? "")
    }

    var body: some View {
        let zh = language == .chinese
        let problem = CredentialRules.labelProblem(draft)
        let vendor = model.credential.map {
            ModelsText.vendorName($0.vendor, vendors: model.vendors, language: language)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                ModelsField(
                    title: zh ? "备注" : "Note", text: $draft, prompt: vendor,
                    problem: problem?.message(language),
                    hint: zh
                        ? "最多 \(Credential.maxLabelLength) 个字；留空就显示厂商名。"
                        : "Up to \(Credential.maxLabelLength) characters; leave empty to show the vendor name.")
                if let error = model.renameError {
                    ErrorBanner(error)
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(zh ? "改备注" : "Edit note")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onClose() }
                    .disabled(model.isRenaming)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isRenaming ? (zh ? "正在保存…" : "Saving…") : (zh ? "保存" : "Save")) {
                    let label = draft
                    Task {
                        if await model.rename(to: label) { onClose() }
                    }
                }
                .disabled(problem != nil || model.isRenaming)
            }
        }
        .interactiveDismissDisabled(model.isRenaming)
        .presentationDetents([.medium, .large])
    }
}

/// 换 key（key 详情弹出）：打码输入新 key，被拒时显示原因。
struct ReplaceCredentialSheet: View {
    let model: CredentialDetailModel
    let onClose: @MainActor () -> Void

    @State private var newKey = ""
    @State private var didAttempt = false
    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let vendor = model.credential.map {
            ModelsText.vendorName($0.vendor, vendors: model.vendors, language: language)
        }
        let localProblem = CredentialRules.keyProblem(newKey)
        let shownProblem: String? = {
            if let localProblem, localProblem != .required || didAttempt { return localProblem.message(language) }
            if let rejection = model.replaceRejection, rejection.concernsKey {
                return rejection.message(vendorName: vendor ?? "", language: language)
            }
            return nil
        }()
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                Text(
                    zh
                        ? "换成同一个厂商（\(vendor ?? "")）的新 key。模型路由不用改，等 key 的任务会接着跑。"
                        : "Replace it with a new key from the same vendor (\(vendor ?? "")). Routes stay as they are, and "
                            + "tasks waiting for a key resume."
                )
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                ModelsField(
                    title: zh ? "新的 API key" : "New API key", text: $newKey,
                    prompt: zh ? "粘贴新的 key" : "Paste the new key", kind: .secret, problem: shownProblem,
                    hint: zh ? "旧的 key 会被覆盖。" : "The old key is overwritten.")
                if let rejection = model.replaceRejection, !rejection.concernsKey {
                    AgentsNotice(
                        systemImage: "exclamationmark.octagon", tone: .failure,
                        text: rejection.message(vendorName: vendor ?? "", language: language))
                }
                if let error = model.replaceError {
                    ErrorBanner(error)
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(zh ? "换 key" : "Replace key")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onClose() }
                    .disabled(model.isReplacing)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isReplacing ? (zh ? "正在保存…" : "Saving…") : (zh ? "换上" : "Replace")) {
                    didAttempt = true
                    let key = newKey
                    let app = self.app
                    Task {
                        guard await model.replaceSecret(key) else { return }
                        onClose()
                        // 换 key 后服务端唤醒等 key 的任务：抽屉里的等待状态跟着变。
                        await app.refreshBadges()
                    }
                }
                .disabled(model.isReplacing)
            }
        }
        .interactiveDismissDisabled(model.isReplacing)
        .presentationDetents([.medium, .large])
    }
}

#Preview("key 详情 · 浅色中文") {
    CredentialDetailScreen(credentialID: DemoData.deepseekCredentialID).previewShell()
}

#Preview("key 详情 · 深色英文") {
    CredentialDetailScreen(credentialID: DemoData.qwenCredentialID).previewShell(.english, scheme: .dark)
}

#Preview("key 详情 · 找不到") {
    CredentialDetailScreen(credentialID: "gone").previewShell()
}

#Preview("换 key · 浅色中文") {
    ReplaceCredentialSheet(
        model: CredentialDetailModel(
            client: MockClient(autoReply: false), credentialID: DemoData.claudeCredentialID,
            credential: DemoData.state().credentials[0])
    ) {}
    .previewShell()
}

#Preview("换 key · 深色英文") {
    ReplaceCredentialSheet(
        model: CredentialDetailModel(
            client: MockClient(autoReply: false), credentialID: DemoData.deepseekCredentialID,
            credential: DemoData.state().credentials[1])
    ) {}
    .previewShell(.english, scheme: .dark)
}

#Preview("改备注 · 浅色中文") {
    CredentialRenameSheet(
        model: CredentialDetailModel(
            client: MockClient(autoReply: false), credentialID: DemoData.deepseekCredentialID,
            credential: DemoData.state().credentials[1])
    ) {}
    .previewShell()
}

#Preview("改备注 · 深色英文") {
    CredentialRenameSheet(
        model: CredentialDetailModel(
            client: MockClient(autoReply: false), credentialID: DemoData.claudeCredentialID,
            credential: DemoData.state().credentials[0])
    ) {}
    .previewShell(.english, scheme: .dark)
}
