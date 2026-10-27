import SwiftUI
import ThinktinKit

/// 计划详情（`.plan(id)`，深链 `thinktin://plan/{id}`、列表、实例详情、收件箱进来）：
///
/// - 头部：标题（agent 写的带 AI 生成标识）、状态、所属实例、下一次；
/// - 等确认的：提示并给“查看并确认”（不能直接恢复）；有规则失效的：标红；
/// - 目标、触发规则（下一次 / 上一次；失效停用的给“修改规则”“删除”）、策略、流水线步骤（只读，编辑在流水线编辑器）、
///   运行历史（服务端按计划过滤，往下翻，点开去运行详情）；
/// - 暂停 / 恢复、编辑（sheet）、删除（二次确认）。
///
/// 离线策略是“没有缓存”：离线时显示已经拉到的，写操作都禁用。
struct PlanDetailScreen: View {
    let planID: PlanID

    @Environment(\.client) private var client

    var body: some View {
        PlanDetailContent(client: client, planID: planID)
    }
}

private struct PlanDetailContent: View {
    @State private var model: PlanDetailModel
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false
    /// “修改规则”正在改的那一条。
    @State private var fixingTrigger: Trigger?
    /// 等二次确认要删的触发器。
    @State private var pendingTriggerDeletion: Trigger?
    @State private var isConfirmingTriggerDeletion = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, planID: PlanID) {
        _model = State(initialValue: PlanDetailModel(client: client, planID: planID))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let plan = model.plan, !model.isMissing {
                    header(plan)
                    if let error = model.actionError {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                    }
                    notices(plan)
                    SectionHeader(title: zh ? "目标" : "Goal")
                    PlanTextBlock(text: plan.goal, isAIGenerated: PlansText.isAIGenerated(.goal, in: plan))
                    triggersSection(plan)
                    SectionHeader(title: zh ? "策略" : "Policy")
                    PlanPolicyRows(plan: plan)
                    if plan.isPipeline { stepsSection(plan) }
                    historySection
                    actions(plan)
                } else if model.isMissing {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: zh ? "找不到这个计划" : "Plan not found",
                        message: zh ? "它可能已经被删除了，或者被 agent 取消了。" : "It may have been deleted or cancelled by an agent.",
                        actionTitle: zh ? "看全部计划" : "All plans"
                    ) {
                        router.open(.plans)
                    }
                } else if model.isLoading || model.error == nil {
                    LoadingStateView()
                } else {
                    EmptyStateView(
                        systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle",
                        title: zh ? "暂时拉不到这个计划" : "Couldn't load this plan")
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(AppRoute.plan(model.planID).title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.plan != nil && !model.isMissing { moreMenu }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .onChange(of: app.resubscribeRequest) {
            Task { await model.load() }
        }
        .onChange(of: router.topRoute) {
            // 从流水线编辑器（压栈的页面）回来：步骤可能改了。
            if router.topRoute == .plan(model.planID) && model.hasLoaded { Task { await model.reloadPlan() } }
        }
        .onChange(of: model.isDeleted) {
            if model.isDeleted { leave() }
        }
        .confirmationDialog(
            zh ? "删除这个计划？" : "Delete this plan?", isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.delete() }
            } label: {
                Text(zh ? "删除计划" : "Delete plan")
            }
            Button(role: .cancel) {
                isConfirmingDeletion = false
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(
                zh
                    ? "删除后不再运行，运行授权一起吊销。已经跑过的运行记录还在。"
                    : "It stops running and its run grant is revoked. Past runs stay in history.")
        }
        .confirmationDialog(
            zh ? "删除这条触发规则？" : "Delete this schedule?", isPresented: $isConfirmingTriggerDeletion,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let trigger = pendingTriggerDeletion {
                    Task { await model.deleteTrigger(trigger.id) }
                }
            } label: {
                Text(zh ? "删除规则" : "Delete schedule")
            }
            Button(role: .cancel) {
                pendingTriggerDeletion = nil
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(
                model.plan?.triggers.count == 1
                    ? (zh
                        ? "这是最后一条规则，删掉后计划不会再自动运行。"
                        : "This is the last schedule; the plan won't run on its own anymore.")
                    : (zh ? "其他规则照常。" : "The other schedules stay as they are."))
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                PlanEditorScreen(mode: .edit(model.planID), plan: model.plan) { saved in
                    isEditing = false
                    if let saved { model.apply(saved) }
                }
            }
            .shellEnvironment(app)
            .tint(Theme.accent)
        }
        .sheet(item: $fixingTrigger) { trigger in
            NavigationStack {
                TriggerEditorView(
                    draft: TriggerDraft(schedule: trigger.schedule),
                    title: zh ? "修改规则" : "Change rule", isSaving: model.isUpdating, error: model.actionError
                ) { schedule in
                    Task {
                        if await model.replaceTrigger(trigger.id, with: schedule) { fixingTrigger = nil }
                    }
                } onCancel: {
                    model.clearActionError()
                    fixingTrigger = nil
                }
            }
            .shellEnvironment(app)
            .tint(Theme.accent)
        }
    }

    /// 离线时不能改。
    private var canWrite: Bool { !app.isOffline }

    private func instanceName(_ id: InstanceID) -> String {
        app.instances.first { $0.id == id }?.name ?? (language == .chinese ? "已删除的实例" : "Deleted instance")
    }

    // MARK: 各部分

    private func header(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            PlanTitleText(plan: plan, style: .title)
                .accessibilityAddTraits(.isHeader)
            TagChipRow {
                PlanStatusLabel(status: plan.status)
                Button {
                    router.open(.instance(plan.instanceID))
                } label: {
                    Text(instanceName(plan.instanceID))
                        .typography(.footnote)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                if case .scheduled(let next) = plan.status {
                    Text(PlansText.nextFire(next, language: language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(.horizontal, Metrics.Spacing.xs)
    }

    @ViewBuilder
    private func notices(_ plan: Plan) -> some View {
        let zh = language == .chinese
        if plan.awaitingConfirmation {
            Card {
                Label {
                    Text(
                        zh
                            ? "agent 安排或改了这个计划，你确认之后才会按时运行。等确认的计划不能直接恢复。"
                            : "An agent set up or changed this plan. It runs on schedule only after you confirm; "
                                + "it can't simply be resumed."
                    )
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hourglass")
                        .foregroundStyle(StatusTone.waiting.color)
                        .accessibilityHidden(true)
                }
                PillButton(zh ? "查看并确认" : "Review and confirm", systemImage: "checkmark.seal", size: .compact) {
                    router.open(.confirmPlan(plan.id))
                }
            }
        }
        let blocked = blockedSteps(plan)
        if !blocked.isEmpty {
            InlineNotice(
                systemImage: "exclamationmark.triangle", tone: .waiting,
                text: PlanBlockedSteps.message(blocked, confirming: plan.awaitingConfirmation, language: language))
        }
        if plan.hasInvalidTriggers {
            InlineNotice(
                systemImage: "exclamationmark.triangle", tone: .failure,
                text: zh
                    ? "有 \(plan.invalidTriggers) 条规则已失效、被停用了，不会再触发。在下面改一下规则。"
                    : "\(plan.invalidTriggers) schedule(s) can no longer be read and were turned off. Change them below."
            )
        }
    }

    private func triggersSection(_ plan: Plan) -> some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            SectionHeader(title: zh ? "触发规则" : "Schedule")
            GroupedSection {
                if plan.triggers.isEmpty {
                    ListRow(
                        systemImage: "clock.badge.questionmark", title: zh ? "没有触发规则" : "No schedule",
                        detail: zh ? "不会自动运行。编辑计划加一条吧。" : "It won't run on its own. Edit the plan to add one.")
                }
                ForEach(plan.triggers) { trigger in
                    if trigger.id != plan.triggers.first?.id { Divider() }
                    PlanTriggerRow(
                        trigger: trigger, plan: plan, canEdit: canWrite && !model.isUpdating,
                        onFix: {
                            model.clearActionError()
                            fixingTrigger = trigger
                        },
                        onDelete: {
                            pendingTriggerDeletion = trigger
                            isConfirmingTriggerDeletion = true
                        })
                }
            }
            Text(
                zh
                    ? "时间是名义上的，为了错开高峰，实际可能晚几分钟开始。"
                    : "Times are nominal; runs may start a few minutes late to spread out the load."
            )
            .typography(.footnote)
            .foregroundStyle(Theme.inkTertiary)
            .padding(.horizontal, Metrics.Spacing.xs)
        }
    }

    private func stepsSection(_ plan: Plan) -> some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            SectionHeader(title: zh ? "流水线（\(plan.steps.count) 步）" : "Pipeline (\(plan.steps.count) steps)")
            PlanStepsView(plan: plan, instanceName: instanceName)
            PillButton(
                zh ? "在流水线编辑器里改" : "Edit in pipeline editor", systemImage: "point.3.connected.trianglepath.dotted",
                kind: .secondary, size: .compact
            ) {
                router.open(.pipelineEditor(planID: plan.id, teamID: nil))
            }
            .disabled(!canWrite)
        }
    }

    private var historySection: some View {
        let zh = language == .chinese
        let model = self.model
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            SectionHeader(title: zh ? "运行历史" : "Run history")
            if let error = visibleError(model.runsError) {
                ErrorBanner(error) { Task { await model.reloadRuns() } }
            }
            GroupedSection {
                if model.runsLoaded && model.runs.isEmpty {
                    ListRow(
                        systemImage: "clock.arrow.circlepath", title: zh ? "还没有运行过" : "No runs yet",
                        detail: zh ? "到点触发后会出现在这里。" : "Runs show up here once the plan fires.")
                } else if !model.runsLoaded {
                    LoadingStateView()
                }
                ForEach(model.runs) { run in
                    if run.id != model.runs.first?.id { Divider() }
                    PlanRunRow(run: run) { router.open(.run(run.id)) }
                }
                if model.hasMoreRuns {
                    Divider()
                    Button {
                        Task { await model.loadMoreRuns() }
                    } label: {
                        HStack(spacing: Metrics.Spacing.xs) {
                            if model.isLoadingRuns { ProgressView() }
                            Text(zh ? "更早的运行" : "Earlier runs")
                                .typography(.body)
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoadingRuns)
                }
            }
            if model.plan?.isPipeline == true {
                Text(
                    zh
                        ? "每次触发一行；流水线每一步的运行在运行详情的运行树里看。"
                        : "One row per run; each pipeline step's run is in the run tree on the run's page."
                )
                .typography(.footnote)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.horizontal, Metrics.Spacing.xs)
            }
        }
    }

    /// 在已删除的实例上的步骤（11.9，恢复、确认会报 409）：恢复报过冲突的用查到的；没有时按应用框架的实例列表看
    /// （拿到过才看，只看暂停、等确认的）。
    private func blockedSteps(_ plan: Plan) -> [PlanStep] {
        if !model.blockedSteps.isEmpty { return model.blockedSteps }
        guard plan.isPipeline, plan.isPaused || plan.awaitingConfirmation, app.hasLoadedInstances else { return [] }
        return PlanBlockedSteps.steps(in: plan, liveInstances: Set(app.instances.map(\.id)))
    }

    private func actions(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let model = self.model
        return VStack(spacing: Metrics.Spacing.s) {
            if model.canResume, blockedSteps(plan).isEmpty {
                PillButton(zh ? "恢复" : "Resume", systemImage: "play") {
                    Task { await model.setPaused(false) }
                }
                .disabled(!canWrite || model.isUpdating)
            } else if model.canPause {
                PillButton(zh ? "暂停" : "Pause", systemImage: "pause", kind: .secondary) {
                    Task { await model.setPaused(true) }
                }
                .disabled(!canWrite || model.isUpdating)
            }
            PillButton(zh ? "删除计划" : "Delete plan", systemImage: "trash", kind: .destructive) {
                isConfirmingDeletion = true
            }
            .disabled(!canWrite || model.isUpdating)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Spacing.l)
    }

    private var moreMenu: some View {
        let zh = language == .chinese
        let model = self.model
        return Menu {
            Button {
                isEditing = true
            } label: {
                Label(zh ? "编辑" : "Edit", systemImage: "pencil")
            }
            .disabled(!canWrite)
            if model.canResume, model.plan.map(blockedSteps)?.isEmpty ?? true {
                Button {
                    Task { await model.setPaused(false) }
                } label: {
                    Label(zh ? "恢复" : "Resume", systemImage: "play")
                }
                .disabled(!canWrite)
            } else if model.canPause {
                Button {
                    Task { await model.setPaused(true) }
                } label: {
                    Label(zh ? "暂停" : "Pause", systemImage: "pause")
                }
                .disabled(!canWrite)
            }
            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                Label(zh ? "删除计划" : "Delete plan", systemImage: "trash")
            }
            .disabled(!canWrite)
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel(Text(zh ? "更多操作" : "More"))
        }
    }

    /// 删掉了：离开这一页，刷新角标。
    private func leave() {
        let id = model.planID
        router.path.removeAll { $0 == .plan(id) || $0 == .confirmPlan(id) || $0 == .editPlan(id) }
        Task { await app.refreshBadges() }
    }
}

#Preview("计划详情 · 浅色中文") {
    PlanDetailScreen(planID: DemoData.digestPlanID).previewShell(client: PlansPreviewClients.withPlans())
}

#Preview("计划详情 · 深色英文") {
    PlanDetailScreen(planID: PlansPreviewClients.pipelinePlanID)
        .previewShell(.english, scheme: .dark, client: PlansPreviewClients.withPlans())
}

#Preview("计划详情 · 规则失效") {
    PlanDetailScreen(planID: PlansPreviewClients.invalidPlanID).previewShell(client: PlansPreviewClients.withPlans())
}

#Preview("计划详情 · 等确认 · 深色英文") {
    PlanDetailScreen(planID: DemoData.agentPlanID).previewShell(.english, scheme: .dark)
}

#Preview("计划详情 · 找不到") {
    PlanDetailScreen(planID: "gone").previewShell()
}
