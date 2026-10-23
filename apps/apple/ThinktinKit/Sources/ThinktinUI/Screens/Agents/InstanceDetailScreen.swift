import SwiftUI
import ThinktinKit

/// 实例详情（`.instance(id)`，深链 `thinktin://instance/{id}`、对话页标题、Agent 详情的“你领养的”进来）：
///
/// - 头部：头像、名字（可以改）、agent 和版本、状态点和状态说明；
/// - “打开对话”；模型路由（没配 main 时提醒）；版本（落后时提示升级，可以回滚，下次唤醒生效）；
/// - 本实例的计划（agent 建的带 AI 生成标识）、新建计划、产出物、所在团队，都跳到各自功能的页面；
/// - 删除：先列出会被级联删掉的流水线步骤和团队成员身份（`InstanceDeleteSheet`），二次确认后再删。
///
/// 页面的离线策略是“有缓存”：离线时照样显示缓存里的实例，改名、换版本、删除、新建计划都禁用。
struct InstanceDetailScreen: View {
    let instanceID: InstanceID

    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app

    var body: some View {
        InstanceDetailContent(
            client: client, instanceID: instanceID, instance: app.instances.first { $0.id == instanceID })
    }
}

private struct InstanceDetailContent: View {
    @State private var model: InstanceDetailModel
    @State private var isRenaming = false
    @State private var isConfirmingDeletion = false
    /// 等确认要换的版本（`isConfirmingVersion` 时显示确认框）。
    @State private var pendingVersion: InstanceVersionOption?
    @State private var isConfirmingVersion = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, instanceID: InstanceID, instance: Instance?) {
        _model = State(initialValue: InstanceDetailModel(client: client, instanceID: instanceID, instance: instance))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let instance = model.instance, !model.isMissing {
                    InstanceHeader(instance: instance, agentName: model.agentDisplayName, canEdit: canWrite) {
                        isRenaming = true
                    }
                    PillButton(zh ? "打开对话" : "Open chat", systemImage: "bubble.left.and.text.bubble.right") {
                        router.open(.conversation(instance.id))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.Spacing.xs)
                    if let error = agentsVisibleError(model.detailsError) {
                        ErrorBanner(error) { Task { await model.load() } }
                    }
                    modelSection(instance)
                    versionSection(instance)
                    workSection(instance)
                    teamSection
                    infoSection(instance)
                    deleteButton
                } else if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.square.dashed",
                        title: zh ? "找不到这个实例" : "Instance not found",
                        message: zh ? "它可能已经被删除了。" : "It may have been deleted.",
                        actionTitle: zh ? "返回" : "Go back"
                    ) {
                        router.pop()
                    }
                } else if model.isLoading || model.error == nil {
                    AgentsLoadingView()
                } else {
                    EmptyStateView(
                        systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle",
                        title: zh ? "暂时拉不到这个实例" : "Couldn't load this instance")
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(model.instance?.name ?? AppRoute.instance(model.instanceID).title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.instance != nil && !model.isMissing {
                    Menu {
                        Button {
                            isRenaming = true
                        } label: {
                            Label(zh ? "改名" : "Rename", systemImage: "pencil")
                        }
                        .disabled(!canWrite)
                        Button(role: .destructive) {
                            isConfirmingDeletion = true
                        } label: {
                            Label(zh ? "删除实例" : "Delete instance", systemImage: "trash")
                        }
                        .disabled(!canWrite)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel(Text(zh ? "更多操作" : "More"))
                    }
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .confirmationDialog(
            pendingVersion?.actionTitle(language) ?? "",
            isPresented: $isConfirmingVersion, titleVisibility: .visible
        ) {
            if let option = pendingVersion {
                Button {
                    Task { await model.setVersion(option.version) }
                } label: {
                    Text(option.actionTitle(language))
                }
            }
            Button(role: .cancel) {
                isConfirmingVersion = false
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(
                zh
                    ? "下次唤醒沙箱时按新版本重建，工作区里的文件都保留，正在跑的任务不受影响。"
                    : "The sandbox is rebuilt on the new version the next time it wakes up. Files in the workspace "
                        + "are kept, and running tasks aren't affected.")
        }
        .sheet(
            isPresented: $isRenaming, onDismiss: { model.clearRenameError() },
            content: {
                NavigationStack {
                    InstanceRenameSheet(model: model) { isRenaming = false }
                }
                .shellEnvironment(app)
                .tint(Theme.accent)
            }
        )
        .sheet(
            isPresented: $isConfirmingDeletion, onDismiss: { finishDeletion() },
            content: {
                NavigationStack {
                    InstanceDeleteSheet(model: model) { isConfirmingDeletion = false }
                }
                .shellEnvironment(app)
                .tint(Theme.accent)
            }
        )
    }

    /// 离线时不能改（只读看缓存）。
    private var canWrite: Bool { !app.isOffline }

    // MARK: 各部分

    private func modelSection(_ instance: Instance) -> some View {
        let zh = language == .chinese
        let status = model.routeStatus
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "模型" : "Model")
            AgentsGroup {
                AgentsRow(
                    systemImage: status.needsAttention ? "exclamationmark.triangle" : "slider.horizontal.3",
                    title: AppRoute.modelRoutes(instance.id).title(language),
                    detail: status.summary(language), detailTone: status.needsAttention ? .waiting : nil,
                    action: { router.open(.modelRoutes(instance.id)) })
            }
        }
    }

    private func versionSection(_ instance: Instance) -> some View {
        let zh = language == .chinese
        let options = model.versionOptions
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "版本" : "Version")
            if let change = model.versionChange {
                AgentsNotice(systemImage: "clock.arrow.circlepath", tone: .active, text: change.message(language))
            } else if !model.isCurrentVersionListed, let latest = model.latestVersion {
                AgentsNotice(
                    systemImage: "exclamationmark.triangle", tone: .waiting,
                    text: zh
                        ? "现在用的 \(AgentsText.versionLabel(instance.agentVersion)) 已经不在目录里了，建议升级到 \(AgentsText.versionLabel(latest))。"
                        : "\(AgentsText.versionLabel(instance.agentVersion)) is no longer listed. Upgrading to "
                            + "\(AgentsText.versionLabel(latest)) is recommended.")
            } else if model.upgradeAvailable, let latest = model.latestVersion {
                AgentsNotice(
                    systemImage: "arrow.up.circle", tone: .active,
                    text: zh
                        ? "有新版本 \(AgentsText.versionLabel(latest))，升级后下次唤醒时生效。"
                        : "\(AgentsText.versionLabel(latest)) is available. It takes effect the next time the sandbox wakes up."
                )
            }
            if let error = model.versionError {
                ErrorBanner(error)
            }
            AgentsGroup {
                if options.isEmpty {
                    AgentsRow(
                        systemImage: "shippingbox", title: AgentsText.versionLabel(instance.agentVersion),
                        detail: zh ? "正在使用" : "In use")
                }
                ForEach(options) { option in
                    if option.id != options.first?.id { Divider() }
                    InstanceVersionRow(option: option, isBusy: model.isChangingVersion, canChange: canWrite) {
                        pendingVersion = option
                        isConfirmingVersion = true
                    }
                }
            }
        }
    }

    private func workSection(_ instance: Instance) -> some View {
        let zh = language == .chinese
        let plans = model.plans ?? []
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "计划和产出物" : "Plans and artifacts")
            AgentsGroup {
                ForEach(plans) { plan in
                    InstancePlanRow(plan: plan) { router.open(.plan(plan.id)) }
                    Divider()
                }
                if model.plans != nil && plans.isEmpty {
                    AgentsRow(
                        systemImage: "calendar", title: zh ? "还没有计划" : "No plans yet",
                        detail: zh
                            ? "可以新建一个，也可以直接对它说“每天 8 点…”。"
                            : "Create one, or just tell it something like “every day at 8…”.")
                    Divider()
                }
                AgentsRow(
                    systemImage: "plus", title: zh ? "新建计划" : "New plan",
                    action: { router.open(.newPlan(instanceID: instance.id)) }
                )
                .disabled(!canWrite)
                Divider()
                AgentsRow(
                    systemImage: "doc.on.doc", title: AppRoute.artifacts(instanceID: instance.id).title(language),
                    detail: zh ? "这个实例发布的文件" : "Files this instance published",
                    action: { router.open(.artifacts(instanceID: instance.id)) })
            }
        }
    }

    @ViewBuilder
    private var teamSection: some View {
        let zh = language == .chinese
        if let teams = model.teams, !teams.isEmpty {
            AgentsSectionHeader(title: zh ? "所在团队" : "Teams")
            AgentsGroup {
                ForEach(teams) { team in
                    if team.id != teams.first?.id { Divider() }
                    AgentsRow(
                        systemImage: "person.3", title: team.name,
                        detail: model.role(in: team) == .lead ? (zh ? "负责人" : "Lead") : (zh ? "成员" : "Member"),
                        action: { router.open(.team(team.id)) })
                }
            }
        }
    }

    private func infoSection(_ instance: Instance) -> some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: zh ? "信息" : "Details")
            AgentsGroup {
                AgentsRow(
                    systemImage: "point.3.connected.trianglepath.dotted", title: zh ? "接入方式" : "Runs via",
                    detail: AgentsText.harnessName(instance.harness, language: language))
                Divider()
                AgentsRow(
                    systemImage: "calendar.badge.plus", title: zh ? "领养于" : "Adopted",
                    detail: Formatting.dateTime(instance.createdAt, language: language))
                Divider()
                AgentsRow(
                    systemImage: "clock", title: zh ? "最近活动" : "Last active",
                    detail: Formatting.relativeTime(instance.lastActiveAt, language: language))
            }
        }
    }

    private var deleteButton: some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            PillButton(zh ? "删除实例" : "Delete instance", systemImage: "trash", kind: .destructive) {
                isConfirmingDeletion = true
            }
            .disabled(!canWrite)
            .frame(maxWidth: .infinity)
            Text(
                zh
                    ? "删除前会列出受影响的任务、流水线和团队，确认后才删。"
                    : "Before deleting, you'll see which tasks, pipelines and teams are affected."
            )
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
        .padding(.top, Metrics.Spacing.l)
    }

    /// 删除确认页关掉了：删掉了就离开这个实例的页面、刷新实例列表。
    private func finishDeletion() {
        guard model.isDeleted else { return }
        let id = model.instanceID
        let app = self.app
        let router = self.router
        Task { await InstanceDetailScreen.leaveDeletedInstance(id, app: app, router: router) }
    }
}

extension InstanceDetailScreen {
    /// 实例删掉之后：导航栈里属于它的页面（实例详情、它的路由、产出物）都拿掉，再刷新应用框架的实例列表
    /// （当前实例被删时应用框架会换到别的实例、回到根）。
    @MainActor
    static func leaveDeletedInstance(_ id: InstanceID, app: AppModel, router: Router) async {
        router.path.removeAll { $0.instanceID == id }
        await app.refresh()
    }
}

/// 头部：头像、名字、agent 和版本、状态。
private struct InstanceHeader: View {
    let instance: Instance
    let agentName: String
    let canEdit: Bool
    let onRename: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                AgentMonogram(AgentsText.monogram(of: instance.name), style: .title, size: 56)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(instance.name)
                        .typography(.title)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(agentName + " · " + AgentsText.versionLabel(instance.agentVersion))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .accessibilityLabel(Text(zh ? "改名" : "Rename"))
            }
            .fixedSize(horizontal: false, vertical: true)
            Card {
                HStack(spacing: Metrics.Spacing.xs) {
                    StatusDot(instance.state)
                        .accessibilityHidden(true)
                    Text(instance.state.localizedName(language))
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                }
                Text(AgentsText.stateExplanation(instance.state, language: language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// 版本列表的一行：版本号、“最新”“正在使用”标签；不是现在的版本时可以点（升级 / 回滚）。
private struct InstanceVersionRow: View {
    let option: InstanceVersionOption
    let isBusy: Bool
    let canChange: Bool
    let onChoose: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        AgentsRow(
            systemImage: option.isCurrent ? "checkmark.circle.fill" : "shippingbox",
            title: AgentsText.versionLabel(option.version),
            detail: option.isCurrent ? nil : option.actionTitle(language),
            detailTone: option.change == .upgrade ? .active : nil,
            action: option.isCurrent || !canChange || isBusy ? nil : onChoose,
            accessory: {
                AgentsTagRow {
                    if option.isLatest { AgentsTag(text: zh ? "最新" : "Latest") }
                    if option.isCurrent { AgentsTag(text: zh ? "正在使用" : "In use") }
                }
            })
    }
}

/// 计划的一行：标题（agent 建的带 AI 生成标识）、待确认 / 已暂停。
private struct InstancePlanRow: View {
    let plan: Plan
    let onOpen: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        AgentsRow(
            systemImage: "calendar", title: plan.title,
            detail: plan.awaitingConfirmation
                ? (zh ? "待确认" : "Needs confirmation") : (plan.isPaused ? (zh ? "已暂停" : "Paused") : nil),
            detailTone: plan.awaitingConfirmation ? .waiting : nil,
            action: onOpen,
            accessory: {
                if AgentsText.isAIGenerated(plan) { AIGeneratedLabel() }
            })
    }
}

/// 一条提示（换了版本、有新版本、版本下架了）。
struct AgentsNotice: View {
    let systemImage: String
    let tone: StatusTone
    let text: String

    var body: some View {
        Label {
            Text(text)
                .typography(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
        }
        .padding(Metrics.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paperElevated, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 改名（实例详情弹出）。
struct InstanceRenameSheet: View {
    let model: InstanceDetailModel
    let onClose: @MainActor () -> Void

    @State private var draft: String
    @Environment(\.displayLanguage) private var language

    init(model: InstanceDetailModel, onClose: @escaping @MainActor () -> Void) {
        self.model = model
        self.onClose = onClose
        _draft = State(initialValue: model.instance?.name ?? "")
    }

    var body: some View {
        let zh = language == .chinese
        let problem = InstanceNameRule.problem(draft)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                AgentsNameField(
                    title: zh ? "实例的名字" : "Instance name", text: $draft, problem: problem,
                    hint: zh
                        ? "最多 \(InstanceNameRule.maxLength) 个字。" : "Up to \(InstanceNameRule.maxLength) characters.")
                if let error = model.renameError {
                    ErrorBanner(error)
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(zh ? "改名" : "Rename")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onClose() }
                    .disabled(model.isRenaming)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isRenaming ? (zh ? "正在保存…" : "Saving…") : (zh ? "保存" : "Save")) {
                    let name = draft
                    Task {
                        if await model.rename(to: name) { onClose() }
                    }
                }
                .disabled(problem != nil || model.isRenaming)
            }
        }
        .interactiveDismissDisabled(model.isRenaming)
        .presentationDetents([.medium, .large])
    }
}

#Preview("实例详情 · 浅色中文") {
    InstanceDetailScreen(instanceID: DemoData.writerID).previewShell()
}

#Preview("实例详情 · 深色英文") {
    InstanceDetailScreen(instanceID: DemoData.reviewerID).previewShell(.english, scheme: .dark)
}

#Preview("改名 · 浅色中文") {
    InstanceRenameSheet(
        model: InstanceDetailModel(
            client: MockClient(autoReply: false), instanceID: DemoData.writerID,
            instance: DemoData.state().instances[0])
    ) {}
    .previewShell()
}

#Preview("改名 · 深色英文") {
    InstanceRenameSheet(
        model: InstanceDetailModel(
            client: MockClient(autoReply: false), instanceID: DemoData.reviewerID,
            instance: DemoData.state().instances[1])
    ) {}
    .previewShell(.english, scheme: .dark)
}

#Preview("实例详情 · 找不到") {
    InstanceDetailScreen(instanceID: "gone").previewShell()
}
