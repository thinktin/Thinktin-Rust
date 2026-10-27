import SwiftUI
import ThinktinKit

/// 新建、编辑计划（`.newPlan`、`.editPlan` 两个 sheet；详情页、确认页的“修改后确认”也用它）：
///
/// - 实例（新建时选，编辑时不能换）、标题（最多 100 个字）、目标（最多 8000 个字），字数实时显示；
/// - 触发规则：一到十条，点开进触发器编辑器（每天、每周几、每月几号、一次性、高级 cron / RRULE，自然语言描述、
///   接下来几次的预览），左边是描述和下一次；
/// - 策略：预授权的工具种类、审批等多久和超时后怎么办、每次运行的上限（token、时长、步数）、每日 token 上限、
///   等电脑 / 等 key 多久；错过的怎么补；
/// - 流水线的步骤只读，在流水线编辑器（`.pipelineEditor`，12.7）里改。
///
/// 保存按钮在本地校验通过、有改动时才能点；有没保存的改动时下拉不能关，“取消”先问一句。
struct PlanEditorScreen: View {
    let mode: PlanEditorModel.Mode
    var plan: Plan?
    /// 关掉（保存了带上保存后的计划，取消是 nil）。
    let onFinish: @MainActor (Plan?) -> Void

    @Environment(\.client) private var client

    var body: some View {
        PlanEditorContent(client: client, mode: mode, plan: plan, onFinish: onFinish)
    }
}

private struct PlanEditorContent: View {
    @State private var model: PlanEditorModel
    @State private var isConfirmingDiscard = false
    let onFinish: @MainActor (Plan?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(
        client: any ClientProtocol, mode: PlanEditorModel.Mode, plan: Plan?,
        onFinish: @escaping @MainActor (Plan?) -> Void
    ) {
        _model = State(initialValue: PlanEditorModel(client: client, mode: mode, plan: plan))
        self.onFinish = onFinish
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark", title: zh ? "找不到这个计划" : "Plan not found",
                        message: zh ? "它可能已经被删除了。" : "It may have been deleted.")
                } else if model.needsLoad {
                    if let error = model.loadError {
                        ErrorBanner(error) { Task { await model.load() } }
                    } else {
                        LoadingStateView()
                    }
                } else {
                    form
                }
            }
            .pageLayout()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .inlineNavigationTitle(
            model.isEditing ? AppRoute.editPlan("").title(language) : AppRoute.newPlan(instanceID: nil).title(language)
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") {
                    if model.hasChanges { isConfirmingDiscard = true } else { onFinish(nil) }
                }
                .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    Task {
                        if let saved = await model.save() { onFinish(saved) }
                    }
                }
                .disabled(!model.canSave || app.isOffline)
            }
        }
        .interactiveDismissDisabled(model.hasChanges || model.isSaving)
        .task { await model.load() }
        .confirmationDialog(
            zh ? "放弃修改？" : "Discard changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                onFinish(nil)
            } label: {
                Text(zh ? "放弃" : "Discard")
            }
            Button(role: .cancel) {
                isConfirmingDiscard = false
            } label: {
                Text(zh ? "继续编辑" : "Keep editing")
            }
        }
    }

    private var saveTitle: String {
        let zh = language == .chinese
        if model.isSaving { return zh ? "正在保存…" : "Saving…" }
        if model.isEditing { return zh ? "保存" : "Save" }
        return zh ? "创建" : "Create"
    }

    // MARK: 表单

    @ViewBuilder
    private var form: some View {
        let zh = language == .chinese
        let model = self.model
        if let error = model.saveError {
            if model.isPartiallySaved {
                InlineNotice(
                    systemImage: "exclamationmark.triangle", tone: .waiting,
                    text: zh
                        ? "一部分改动已经保存了，剩下的没存上。再点一次保存只做剩下的。"
                        : "Some changes were saved and some weren't. Saving again does only the rest.")
            }
            ErrorBanner(error, onDismiss: { model.clearSaveError() })
        }
        if let original = model.original, original.awaitingConfirmation {
            InlineNotice(
                systemImage: "hourglass", tone: .waiting,
                text: zh
                    ? "这个计划在等你确认。保存后回到确认页，按改好的内容确认。"
                    : "This plan is waiting for your review. After saving, confirm the updated version.")
        }
        instanceSection
        basicsSection
        triggersSection
        policySection
        catchUpSection
        if !model.steps.isEmpty {
            SectionHeader(title: zh ? "流水线" : "Pipeline")
            InlineNotice(
                systemImage: "point.3.connected.trianglepath.dotted", tone: .neutral,
                text: zh
                    ? "这个计划是 \(model.steps.count) 步的流水线。步骤在流水线编辑器里改，这里保存不会动它们。"
                    : "This plan is a \(model.steps.count)-step pipeline. Steps are edited in the pipeline editor; "
                        + "saving here leaves them as they are.")
        }
    }

    @ViewBuilder
    private var instanceSection: some View {
        let zh = language == .chinese
        let model = self.model
        SectionHeader(title: zh ? "在哪个实例上运行" : "Runs on")
        if model.isEditing {
            GroupedSection {
                ListRow(
                    systemImage: "cpu", title: instanceName(model.instanceID),
                    detail: zh ? "计划建好后不能换实例。" : "A plan's instance can't be changed.")
            }
        } else if app.instances.isEmpty {
            InlineNotice(
                systemImage: "exclamationmark.triangle", tone: .waiting,
                text: zh ? "还没有实例。先领养一个 agent。" : "You don't have any instances yet. Adopt an agent first.")
        } else {
            GroupedSection {
                ForEach(app.instances) { instance in
                    if instance.id != app.instances.first?.id { Divider() }
                    ChoiceRow(
                        title: instance.name, detail: AgentsText.displayName(agentID: instance.agentID),
                        isSelected: model.instanceID == instance.id
                    ) {
                        model.instanceID = instance.id
                    }
                }
            }
        }
    }

    private func instanceName(_ id: InstanceID?) -> String {
        guard let id else { return "" }
        return app.instances.first { $0.id == id }?.name ?? id.rawValue
    }

    @ViewBuilder
    private var basicsSection: some View {
        let zh = language == .chinese
        SectionHeader(title: zh ? "做什么" : "What it does")
        PlansTextField(
            title: zh ? "标题" : "Title", text: $model.title, prompt: zh ? "比如：每日新闻摘要" : "For example: Daily news digest",
            limit: Plan.maxTitleLength, count: model.titleLength,
            problem: model.title.isEmpty ? nil : model.titleProblem.map { PlanFormProblem.title($0).message(language) })
        PlansTextField(
            title: zh ? "目标" : "Goal", text: $model.goal,
            prompt: zh
                ? "每次触发时交给 agent 的任务，写清楚要做什么、结果放哪里。"
                : "The task the agent gets each time. Say what to do and where results go.",
            multiline: true, limit: Plan.maxGoalLength, count: model.goalLength,
            problem: model.goal.isEmpty ? nil : model.goalProblem.map { PlanFormProblem.goal($0).message(language) })
    }

    @ViewBuilder
    private var triggersSection: some View {
        let zh = language == .chinese
        let model = self.model
        SectionHeader(title: zh ? "什么时候运行" : "When it runs")
        GroupedSection {
            ForEach(model.triggers) { item in
                PlanEditorTriggerRow(item: item, draft: model.draft(for: item.id)) { schedule in
                    model.updateTrigger(item.id, to: schedule)
                } onDelete: {
                    model.removeTrigger(item.id)
                }
                Divider()
            }
            NavigationLink {
                TriggerEditorView(
                    draft: model.newTriggerDraft(), title: zh ? "添加触发规则" : "Add schedule", dismissOnSave: true
                ) { schedule in
                    model.addTrigger(schedule)
                }
            } label: {
                ListRow(
                    systemImage: "plus", title: zh ? "添加触发规则" : "Add schedule",
                    detail: model.canAddTrigger
                        ? nil : (zh ? "最多 \(Plan.maxTriggers) 条" : "Up to \(Plan.maxTriggers)"))
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddTrigger)
        }
        if model.triggersProblem == .noTriggers && model.hasChanges {
            Text(PlanFormProblem.noTriggers.message(language))
                .typography(.footnote)
                .foregroundStyle(StatusTone.failure.color)
                .padding(.horizontal, Metrics.Spacing.xs)
        }
    }

    @ViewBuilder
    private var policySection: some View {
        let zh = language == .chinese
        let model = self.model
        let policy = model.policy
        SectionHeader(title: zh ? "策略" : "Policy")
        GroupedSection {
            NavigationLink {
                PlanToolsPicker(policy: $model.policy)
            } label: {
                ListRow(
                    systemImage: "checkmark.shield", title: zh ? "预授权的工具" : "Pre-approved tools",
                    detail: PlansText.toolsSummary(policy.preauthorizedTools, language: language),
                    detailTone: policy.preauthorizedTools.contains(where: PlansText.isRiskyTool) ? .waiting : nil)
            }
            .buttonStyle(.plain)
            Divider()
            PlansMenuRow(
                systemImage: "hand.raised", title: zh ? "审批等多久" : "Approval wait",
                options: PlansText.presets(PlansText.timeoutPresets, including: policy.approvalTimeoutSecs),
                selection: $model.policy.approvalTimeoutSecs, name: { PlansText.duration($0, language: language) },
                detail: zh ? "agent 要用没预授权的工具时，等你批准多久。" : "How long an approval request waits for you.")
            Divider()
            PlansMenuRow(
                systemImage: "exclamationmark.arrow.circlepath", title: zh ? "超时后" : "After a timeout",
                options: timeoutActions(including: policy.onApprovalTimeout),
                selection: $model.policy.onApprovalTimeout,
                name: { PlansText.timeoutActionName($0, language: language) },
                detail: PlansText.timeoutActionDetail(policy.onApprovalTimeout, language: language))
            Divider()
            PlansMenuRow(
                systemImage: "hourglass", title: zh ? "等电脑、等 key 多久" : "Wait for a computer or key",
                options: PlansText.presets(PlansText.timeoutPresets, including: policy.waitTimeoutSecs),
                selection: $model.policy.waitTimeoutSecs, name: { PlansText.duration($0, language: language) })
        }
        SectionHeader(title: zh ? "每次运行的上限" : "Per-run limits")
        GroupedSection {
            PlansMenuRow(
                systemImage: "timer", title: zh ? "最长跑多久" : "Longest run",
                options: PlansText.presets(PlansText.durationPresets, including: policy.maxDurationSecs),
                selection: $model.policy.maxDurationSecs, name: { PlansText.duration($0, language: language) })
        }
        PlansTextField(
            title: zh ? "最多用多少 token" : "Token limit per run", text: $model.policy.maxTokens,
            prompt: zh ? "不限" : "No limit", problem: policy.problem(for: .maxTokens)?.message(language), numeric: true)
        PlansTextField(
            title: zh ? "最多几步（工具调用）" : "Step limit per run (tool calls)", text: $model.policy.maxSteps,
            prompt: zh ? "不限" : "No limit", problem: policy.problem(for: .maxSteps)?.message(language), numeric: true)
        PlansTextField(
            title: zh ? "每天最多用多少 token（整个计划）" : "Daily token limit (whole plan)",
            text: $model.policy.dailyTokenLimit, prompt: zh ? "不限" : "No limit",
            problem: policy.problem(for: .dailyTokenLimit)?.message(language),
            hint: zh ? "超过后当天不再运行。" : "Once reached, the plan doesn't run again that day.", numeric: true)
    }

    private func timeoutActions(including current: ApprovalTimeoutAction) -> [ApprovalTimeoutAction] {
        let known = ApprovalTimeoutAction.knownCases
        return known.contains(current) ? known : known + [current]
    }

    @ViewBuilder
    private var catchUpSection: some View {
        let zh = language == .chinese
        let model = self.model
        let options =
            CatchUp.knownCases.contains(model.catchUp) ? CatchUp.knownCases : CatchUp.knownCases + [model.catchUp]
        SectionHeader(title: zh ? "错过的怎么补（平台停机时）" : "Missed runs (during downtime)")
        GroupedSection {
            ForEach(options, id: \.self) { option in
                if option != options.first { Divider() }
                ChoiceRow(
                    title: PlansText.catchUpName(option, language: language),
                    detail: PlansText.catchUpDetail(option, language: language), isSelected: model.catchUp == option
                ) {
                    model.catchUp = option
                }
            }
        }
    }
}

/// 编辑器里的一条触发规则：描述、下一次（已有的看服务端的，新加的看本地预测），点开改，右边删。
private struct PlanEditorTriggerRow: View {
    let item: PlanTriggerItem
    let draft: TriggerDraft?
    let onChange: @MainActor (Schedule) -> Void
    let onDelete: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        HStack(spacing: Metrics.Spacing.xs) {
            NavigationLink {
                TriggerEditorView(
                    draft: draft ?? TriggerDraft(), title: zh ? "修改触发规则" : "Edit schedule", dismissOnSave: true,
                    onSave: onChange)
            } label: {
                ListRow(
                    systemImage: item.trigger?.isInvalid == true ? "exclamationmark.triangle" : "clock",
                    title: ScheduleDescription.describe(item.schedule, language: language), detail: detail,
                    detailTone: item.trigger?.isInvalid == true ? .failure : nil)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(StatusTone.failure.color)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(zh ? "删除这条规则" : "Remove this schedule"))
            .padding(.trailing, Metrics.Spacing.xs)
        }
    }

    private var detail: String? {
        let zh = language == .chinese
        if let trigger = item.trigger {
            if trigger.isInvalid { return zh ? "规则已失效，点开改一下" : "No longer valid; tap to change" }
            if let next = trigger.nextFireAt { return PlansText.nextFire(next, language: language) }
            return trigger.isEnabled ? nil : (zh ? "已停用" : "Turned off")
        }
        if let next = ScheduleForecast.nextFires(item.schedule, after: Date(), count: 1)?.first {
            return (zh ? "新加的 · " : "New · ") + PlansText.nextFire(next, language: language)
        }
        return zh ? "新加的" : "New"
    }
}

/// 预授权的工具种类：每种一个开关，有风险的（改文件、删文件、跑命令）标出来。认不出的种类照样列出来，可以关掉。
struct PlanToolsPicker: View {
    @Binding var policy: PlanPolicyDraft

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let kinds = PlansText.toolKinds + policy.preauthorizedTools.filter { !PlansText.toolKinds.contains($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                Text(
                    zh
                        ? "预授权的工具，agent 按时运行时用到不用等你审批。只给它需要的；会改文件、跑命令的要谨慎。"
                        : "Pre-approved tools don't need your approval during scheduled runs. Allow only what it needs; "
                            + "be careful with tools that change files or run commands."
                )
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                GroupedSection {
                    ForEach(kinds, id: \.self) { kind in
                        if kind != kinds.first { Divider() }
                        Toggle(isOn: binding(for: kind)) {
                            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                                Text(PlansText.toolName(kind, language: language))
                                    .typography(.body)
                                    .foregroundStyle(Theme.ink)
                                if PlansText.isRiskyTool(kind) {
                                    Text(zh ? "有风险" : "Risky")
                                        .typography(.caption)
                                        .foregroundStyle(StatusTone.waiting.color)
                                }
                            }
                        }
                        .padding(.horizontal, Metrics.Spacing.m)
                        .padding(.vertical, Metrics.Spacing.xs)
                        .frame(minHeight: Metrics.minTapTarget)
                    }
                }
                if let problem = policy.problems.first(where: {
                    if case .tooManyTools = $0 { return true }
                    return false
                }) {
                    Text(problem.message(language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                }
            }
            .pageLayout()
        }
        .background(Theme.paper)
        .inlineNavigationTitle(zh ? "预授权的工具" : "Pre-approved tools")
        .tint(Theme.accent)
    }

    private func binding(for kind: String) -> Binding<Bool> {
        Binding(
            get: { policy.allows(kind) },
            set: { policy.setTool(kind, allowed: $0) })
    }
}

#Preview("新建计划 · 浅色中文") {
    PlanEditorScreen(mode: .create(instanceID: DemoData.writerID)) { _ in }
        .previewShell()
}

#Preview("编辑计划 · 深色英文") {
    PlanEditorScreen(mode: .edit(DemoData.digestPlanID)) { _ in }
        .previewShell(.english, scheme: .dark)
}

#Preview("预授权的工具 · 浅色中文") {
    PlanToolsPicker(policy: .constant(PlanPolicyDraft(PlanPolicy(preauthorizedTools: ["read", "execute"]))))
        .previewShell()
}

#Preview("预授权的工具 · 深色英文") {
    PlanToolsPicker(policy: .constant(PlanPolicyDraft()))
        .previewShell(.english, scheme: .dark)
}
