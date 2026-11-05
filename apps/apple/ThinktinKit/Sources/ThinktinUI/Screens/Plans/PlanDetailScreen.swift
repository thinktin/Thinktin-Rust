import SwiftUI
import ThinktinKit

/// 计划详情（`.plan(id)`，深链 `thinktin://plan/{id}`、列表、实例详情、收件箱进来）。参考里没有这一页，按规范第 2 节换成
/// 原生的 insetGrouped 列表，版式跟 Botin 资料（参考 09）一个路子：
///
/// - 头部（透明行，居中）：状态图标、标题（agent 写的带 AI 生成标识）、状态 · 下一次、所属 Botin（能点）；
/// - 等确认的：一组提示和“查看并确认”（不能直接恢复）；有步骤卡住、规则失效的：各一行提示；
/// - 目标、触发规则（下一次 / 上一次；失效停用的给“修改规则”“删除”）、策略、流水线步骤（只读，编辑在流水线编辑器）、
///   运行历史（服务端按计划过滤，往下翻，点开去运行详情）；
/// - 最后一组暂停 / 恢复、删除（二次确认）；右上“…”里编辑（sheet）、暂停 / 恢复、删除。
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
        List {
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let plan = model.plan, !model.isMissing {
                Section {
                    header(plan)
                        .clearListRow()
                }
                if let error = model.actionError {
                    Section {
                        ErrorBanner(error, onDismiss: { model.clearActionError() })
                            .clearListRow()
                    }
                }
                notices(plan)
                Section {
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                        Text(plan.goal)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if PlansText.isAIGenerated(.goal, in: plan) { AIGeneratedLabel() }
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text(zh ? "目标" : "Goal").textCase(nil)
                }
                .themedRow()
                triggersSection(plan)
                policySection(plan)
                if plan.isPipeline { stepsSection(plan) }
                historySection
                actions(plan)
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(AppRoute.plan(model.planID).title(language))
        .toolbar {
            if model.plan != nil && !model.isMissing {
                ToolbarItem(placement: ToolbarSlot.trailing) { moreMenu }
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
        .onChange(of: router.visibleRoute) {
            // 从流水线编辑器（压栈的页面）回来：步骤可能改了。看 `visibleRoute`：这一页也可能在 sheet 的栈里。
            if router.visibleRoute == .plan(model.planID) && model.hasLoaded { Task { await model.reloadPlan() } }
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
        app.instances.first { $0.id == id }?.name ?? (language == .chinese ? "已删除的 Botin" : "Deleted Botin")
    }

    // MARK: 空状态

    @ViewBuilder
    private var placeholder: some View {
        let zh = language == .chinese
        if model.isMissing {
            ContentUnavailableView {
                Label(zh ? "找不到这个计划" : "Plan not found", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text(zh ? "它可能已经被删除了，或者被 Botin 取消了。" : "It may have been deleted or cancelled by a Botin.")
            } actions: {
                Button(zh ? "看全部计划" : "All plans") { router.open(.plans(instanceID: nil)) }
                    .glassButtonStyle()
            }
        } else if model.plan == nil {
            if model.isLoading || model.error == nil {
                ProgressView()
            } else {
                ContentUnavailableView(
                    zh ? "暂时拉不到这个计划" : "Couldn't load this plan",
                    systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle")
            }
        }
    }

    // MARK: 各部分

    /// 头部（Botin 资料那样居中）：状态图标、标题、状态 · 下一次、所属 Botin。
    private func header(_ plan: Plan) -> some View {
        let status = plan.status
        return VStack(spacing: Metrics.Spacing.xs) {
            Image(systemName: status.systemImage)
                .font(.system(size: 44))
                .foregroundStyle(status.tone.color)
                .accessibilityHidden(true)
            Text(plan.title)
                .font(Font.title2.bold())
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if PlansText.isAIGenerated(.title, in: plan) { AIGeneratedLabel() }
            HStack(spacing: Metrics.Spacing.xs) {
                PlanStatusLabel(status: status)
                if case .scheduled(let next) = status {
                    Text(PlansText.nextFire(next, language: language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            Button(instanceName(plan.instanceID)) {
                router.open(.instance(plan.instanceID))
            }
            .glassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.s)
    }

    @ViewBuilder
    private func notices(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let blocked = blockedSteps(plan)
        if plan.awaitingConfirmation || !blocked.isEmpty || plan.hasInvalidTriggers {
            Section {
                if plan.awaitingConfirmation {
                    Label {
                        Text(
                            zh
                                ? "Botin 安排或改了这个计划，你确认之后才会按时运行。等确认的计划不能直接恢复。"
                                : "A Botin set up or changed this plan. It runs on schedule only after you confirm; "
                                    + "it can't simply be resumed."
                        )
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "hourglass")
                            .foregroundStyle(StatusTone.waiting.color)
                    }
                    NavigationLink(value: AppRoute.confirmPlan(plan.id)) {
                        Label(zh ? "查看并确认" : "Review and confirm", systemImage: "checkmark.seal")
                            .foregroundStyle(Theme.accent)
                    }
                }
                if !blocked.isEmpty {
                    Label {
                        Text(
                            PlanBlockedSteps.message(blocked, confirming: plan.awaitingConfirmation, language: language)
                        )
                        .typography(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(StatusTone.waiting.color)
                    }
                }
                if plan.hasInvalidTriggers {
                    Label {
                        Text(
                            zh
                                ? "有 \(plan.invalidTriggers) 条规则已失效、被停用了，不会再触发。在下面改一下规则。"
                                : "\(plan.invalidTriggers) schedule(s) can no longer be read and were turned off. "
                                    + "Change them below."
                        )
                        .typography(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(StatusTone.failure.color)
                    }
                }
            }
            .themedRow()
        }
    }

    private func triggersSection(_ plan: Plan) -> some View {
        let zh = language == .chinese
        return Section {
            if plan.triggers.isEmpty {
                LabeledContent {
                    Text(zh ? "不会自动运行。编辑计划加一条吧。" : "It won't run on its own. Edit the plan to add one.")
                } label: {
                    Label(zh ? "没有触发规则" : "No schedule", systemImage: "clock.badge.questionmark")
                }
            }
            ForEach(plan.triggers) { trigger in
                PlanTriggerRow(
                    trigger: trigger, plan: plan, canEdit: canWrite && !model.isUpdating,
                    onFix: {
                        model.clearActionError()
                        fixingTrigger = trigger
                    },
                    onDelete: {
                        pendingTriggerDeletion = trigger
                        isConfirmingTriggerDeletion = true
                    }
                )
                .listRowInsets(EdgeInsets())
            }
        } header: {
            Text(zh ? "触发规则" : "Schedule").textCase(nil)
        } footer: {
            Text(
                zh
                    ? "时间是名义上的，为了错开高峰，实际可能晚几分钟开始。"
                    : "Times are nominal; runs may start a few minutes late to spread out the load.")
        }
        .themedRow()
    }

    private func policySection(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let policy = plan.policy
        let risky = policy.preauthorizedTools.contains(where: PlansText.isRiskyTool)
        return Section {
            LabeledContent {
                Text(PlansText.toolsSummary(policy.preauthorizedTools, language: language))
                    .foregroundStyle(risky ? StatusTone.waiting.color : Theme.inkSecondary)
            } label: {
                Label(zh ? "预授权的工具" : "Pre-approved tools", systemImage: "checkmark.shield")
            }
            LabeledContent {
                Text(PlansText.approvalSummary(policy, language: language))
            } label: {
                Label(zh ? "审批" : "Approvals", systemImage: "hand.raised")
            }
            LabeledContent {
                Text(PlansText.budgetSummary(policy.budget, language: language))
            } label: {
                Label(zh ? "每次运行的上限" : "Per-run limits", systemImage: "gauge.with.dots.needle.33percent")
            }
            LabeledContent {
                Text(PlansText.dailyLimitSummary(policy.dailyTokenLimit, language: language))
            } label: {
                Label(zh ? "每日 token 上限" : "Daily token limit", systemImage: "calendar.day.timeline.left")
            }
            LabeledContent {
                Text(PlansText.waitSummary(policy, language: language))
            } label: {
                Label(zh ? "等待" : "Waiting", systemImage: "hourglass")
            }
            LabeledContent {
                Text(PlansText.catchUpName(plan.catchUp, language: language))
            } label: {
                Label(zh ? "错过的怎么补" : "Missed runs", systemImage: "arrow.uturn.backward.circle")
            }
        } header: {
            Text(zh ? "策略" : "Policy").textCase(nil)
        } footer: {
            if let detail = PlansText.catchUpDetail(plan.catchUp, language: language) { Text(detail) }
        }
        .themedRow()
    }

    private func stepsSection(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let stages = PipelineLayout.stages(plan.steps)
        let ai = PlansText.isAIGenerated(.stepPrompt, in: plan)
        return Section {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                ForEach(stage) { step in
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                        Text(PlanStepsView.stageTitle(index: index, parallel: stage.count > 1, language: language))
                            .typography(.caption)
                            .foregroundStyle(Theme.inkTertiary)
                        HStack(spacing: Metrics.Spacing.xs) {
                            Text(verbatim: step.key)
                                .font(Typography.subheadline.monospacedFont)
                                .foregroundStyle(Theme.ink)
                            Text(instanceName(step.instanceID))
                                .typography(.subheadline)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                        }
                        Text(step.prompt)
                            .typography(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(4)
                        if ai { AIGeneratedLabel() }
                        if !step.dependsOn.isEmpty {
                            Text((zh ? "等这几步做完：" : "After: ") + step.dependsOn.joined(separator: zh ? "、" : ", "))
                                .typography(.footnote)
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Button {
                router.open(.pipelineEditor(planID: plan.id, teamID: nil))
            } label: {
                Label(
                    zh ? "在流水线编辑器里改" : "Edit in pipeline editor", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(!canWrite)
        } header: {
            Text(zh ? "流水线（\(plan.steps.count) 步）" : "Pipeline (\(plan.steps.count) steps)").textCase(nil)
        }
        .themedRow()
    }

    private var historySection: some View {
        let zh = language == .chinese
        let model = self.model
        return Section {
            if let error = visibleError(model.runsError) {
                ErrorBanner(error) { Task { await model.reloadRuns() } }
                    .clearListRow()
            }
            if model.runsLoaded && model.runs.isEmpty {
                LabeledContent {
                    Text(zh ? "到点触发后会出现在这里。" : "Runs show up here once the plan fires.")
                } label: {
                    Label(zh ? "还没有运行过" : "No runs yet", systemImage: "clock.arrow.circlepath")
                }
            } else if !model.runsLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            ForEach(model.runs) { run in
                PlanRunRow(run: run) { router.open(.run(run.id)) }
                    .listRowInsets(EdgeInsets())
            }
            if model.hasMoreRuns {
                Button {
                    Task { await model.loadMoreRuns() }
                } label: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        if model.isLoadingRuns { ProgressView() }
                        Text(zh ? "更早的运行" : "Earlier runs")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isLoadingRuns)
            }
        } header: {
            Text(zh ? "运行历史" : "Run history").textCase(nil)
        } footer: {
            if model.plan?.isPipeline == true {
                Text(
                    zh
                        ? "每次触发一行；流水线每一步的运行在运行详情的运行树里看。"
                        : "One row per run; each pipeline step's run is in the run tree on the run's page.")
            }
        }
        .themedRow()
    }

    /// 在已删除的实例上的步骤（11.9，恢复、确认会报 409）：恢复报过冲突的用查到的；没有时按应用框架的实例列表看
    /// （拿到过才看，只看暂停、等确认的）。
    private func blockedSteps(_ plan: Plan) -> [PlanStep] {
        if !model.blockedSteps.isEmpty { return model.blockedSteps }
        guard plan.isPipeline, plan.isPaused || plan.awaitingConfirmation, app.hasLoadedInstances else { return [] }
        return PlanBlockedSteps.steps(in: plan, liveInstances: Set(app.instances.map(\.id)))
    }

    /// 最后一组：暂停 / 恢复、删除（设置页那样的整行按钮）。
    private func actions(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let model = self.model
        return Section {
            if model.canResume, blockedSteps(plan).isEmpty {
                Button {
                    Task { await model.setPaused(false) }
                } label: {
                    Label(zh ? "恢复" : "Resume", systemImage: "play")
                }
                .disabled(!canWrite || model.isUpdating)
            } else if model.canPause {
                Button {
                    Task { await model.setPaused(true) }
                } label: {
                    Label(zh ? "暂停" : "Pause", systemImage: "pause")
                }
                .disabled(!canWrite || model.isUpdating)
            }
            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                Label(zh ? "删除计划" : "Delete plan", systemImage: "trash")
            }
            .disabled(!canWrite || model.isUpdating)
        }
        .themedRow()
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
            Label(zh ? "更多操作" : "More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
    }

    /// 删掉了：离开这一页（主栈或 sheet 的栈，哪层有拿哪层），刷新角标。
    private func leave() {
        let id = model.planID
        router.removeRoutes { $0 == .plan(id) || $0 == .confirmPlan(id) || $0 == .editPlan(id) }
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
