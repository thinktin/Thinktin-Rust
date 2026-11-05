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
///
/// 改版（规范 2.5、2.6、4.9.6 的字段写法）：`Form`，左上 `CloseButton`、右上 `ConfirmButton("创建" / "保存")`；Botin、
/// 错过的怎么补是行内 `Picker(.inline)`（系统打勾），策略的几项是 `Picker(.menu)`，输入框标签在上（`FormTextField`），
/// 提示放在组里一行带色调图标的字，问题写在组脚注。
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
        Form {
            if !model.isMissing, !model.needsLoad {
                formSections
            } else if !model.isMissing, let error = model.loadError {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.isMissing {
                ContentUnavailableView {
                    Label(zh ? "找不到这个计划" : "Plan not found", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text(zh ? "它可能已经被删除了。" : "It may have been deleted.")
                }
            } else if model.needsLoad, model.loadError == nil {
                ProgressView()
            }
        }
        .inlineNavigationTitle(
            model.isEditing ? AppRoute.editPlan("").title(language) : AppRoute.newPlan(instanceID: nil).title(language)
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton {
                    if model.hasChanges { isConfirmingDiscard = true } else { onFinish(nil) }
                }
                .disabled(model.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(
                    model.isEditing ? (zh ? "保存" : "Save") : (zh ? "创建" : "Create"), isWorking: model.isSaving
                ) {
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

    // MARK: 表单

    @ViewBuilder
    private var formSections: some View {
        let zh = language == .chinese
        let model = self.model
        if let error = model.saveError {
            Section {
                if model.isPartiallySaved {
                    PlansNoticeRow(
                        systemImage: "exclamationmark.triangle", tone: .waiting,
                        text: zh
                            ? "一部分改动已经保存了，剩下的没存上。再点一次保存只做剩下的。"
                            : "Some changes were saved and some weren't. Saving again does only the rest.")
                }
                ErrorBanner(error, onDismiss: { model.clearSaveError() })
                    .clearListRow()
            }
        }
        if let original = model.original, original.awaitingConfirmation {
            Section {
                PlansNoticeRow(
                    systemImage: "hourglass", tone: .waiting,
                    text: zh
                        ? "这个计划在等你确认。保存后回到确认页，按改好的内容确认。"
                        : "This plan is waiting for your review. After saving, confirm the updated version.")
            }
            .themedRow()
        }
        instanceSection
        basicsSection
        triggersSection
        policySection
        catchUpSection
        if !model.steps.isEmpty {
            Section {
                PlansNoticeRow(
                    systemImage: "point.3.connected.trianglepath.dotted", tone: .neutral,
                    text: zh
                        ? "这个计划是 \(model.steps.count) 步的流水线。步骤在流水线编辑器里改，这里保存不会动它们。"
                        : "This plan is a \(model.steps.count)-step pipeline. Steps are edited in the pipeline editor; "
                            + "saving here leaves them as they are.")
            } header: {
                Text(zh ? "流水线" : "Pipeline").textCase(nil)
            }
            .themedRow()
        }
    }

    @ViewBuilder
    private var instanceSection: some View {
        let zh = language == .chinese
        let model = self.model
        Section {
            if model.isEditing {
                LabeledRow(
                    systemImage: "cpu", title: instanceName(model.instanceID),
                    detail: zh ? "计划建好后不能换 Botin。" : "A plan's Botin can't be changed.")
            } else if app.instances.isEmpty {
                PlansNoticeRow(
                    systemImage: "exclamationmark.triangle", tone: .waiting,
                    text: zh ? "还没有 Botin，先新建一个。" : "You don't have any Botins yet. Create one first.")
            } else {
                Picker(zh ? "在哪个 Botin 上运行" : "Runs on", selection: $model.instanceID) {
                    ForEach(app.instances) { instance in
                        PlansOptionLabel(
                            title: instance.name, detail: AgentsText.displayName(agentID: instance.agentID)
                        )
                        .tag(InstanceID?.some(instance.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } header: {
            Text(zh ? "在哪个 Botin 上运行" : "Runs on").textCase(nil)
        }
        .themedRow()
    }

    private func instanceName(_ id: InstanceID?) -> String {
        guard let id else { return "" }
        return app.instances.first { $0.id == id }?.name ?? id.rawValue
    }

    private var basicsSection: some View {
        let zh = language == .chinese
        return Section {
            FormTextField(
                title: zh ? "标题" : "Title", text: $model.title,
                prompt: zh ? "比如：每日新闻摘要" : "For example: Daily news digest",
                limit: Plan.maxTitleLength, count: model.titleLength,
                problem: model.title.isEmpty
                    ? nil : model.titleProblem.map { PlanFormProblem.title($0).message(language) })
            FormTextField(
                title: zh ? "目标" : "Goal", text: $model.goal,
                prompt: zh
                    ? "每次触发时交给 Botin 的任务，写清楚要做什么、结果放哪里。"
                    : "The task the Botin gets each time. Say what to do and where results go.",
                multiline: true, limit: Plan.maxGoalLength, count: model.goalLength,
                problem: model.goal.isEmpty
                    ? nil : model.goalProblem.map { PlanFormProblem.goal($0).message(language) })
        } header: {
            Text(zh ? "做什么" : "What it does").textCase(nil)
        }
        .themedRow()
    }

    private var triggersSection: some View {
        let zh = language == .chinese
        let model = self.model
        return Section {
            ForEach(model.triggers) { item in
                PlanEditorTriggerRow(item: item, draft: model.draft(for: item.id)) { schedule in
                    model.updateTrigger(item.id, to: schedule)
                } onDelete: {
                    model.removeTrigger(item.id)
                }
            }
            NavigationLink {
                TriggerEditorView(
                    draft: model.newTriggerDraft(), title: zh ? "添加触发规则" : "Add schedule", dismissOnSave: true
                ) { schedule in
                    model.addTrigger(schedule)
                }
            } label: {
                Label(zh ? "添加触发规则" : "Add schedule", systemImage: "plus")
            }
            .disabled(!model.canAddTrigger)
        } header: {
            Text(zh ? "什么时候运行" : "When it runs").textCase(nil)
        } footer: {
            if model.triggersProblem == .noTriggers && model.hasChanges {
                Text(PlanFormProblem.noTriggers.message(language))
                    .foregroundStyle(StatusTone.failure.color)
            } else if !model.canAddTrigger {
                Text(zh ? "最多 \(Plan.maxTriggers) 条" : "Up to \(Plan.maxTriggers)")
            }
        }
        .themedRow()
    }

    @ViewBuilder
    private var policySection: some View {
        let zh = language == .chinese
        let model = self.model
        let policy = model.policy
        Section {
            NavigationLink {
                PlanToolsPicker(policy: $model.policy)
            } label: {
                LabeledRow(
                    systemImage: "checkmark.shield", title: zh ? "预授权的工具" : "Pre-approved tools",
                    detail: PlansText.toolsSummary(policy.preauthorizedTools, language: language),
                    detailTone: policy.preauthorizedTools.contains(where: PlansText.isRiskyTool) ? .waiting : nil)
            }
            PlansMenuRow(
                systemImage: "hand.raised", title: zh ? "审批等多久" : "Approval wait",
                options: PlansText.presets(PlansText.timeoutPresets, including: policy.approvalTimeoutSecs),
                selection: $model.policy.approvalTimeoutSecs, name: { PlansText.duration($0, language: language) },
                detail: zh ? "Botin 要用没预授权的工具时，等你批准多久。" : "How long an approval request waits for you.")
            PlansMenuRow(
                systemImage: "exclamationmark.arrow.circlepath", title: zh ? "超时后" : "After a timeout",
                options: timeoutActions(including: policy.onApprovalTimeout),
                selection: $model.policy.onApprovalTimeout,
                name: { PlansText.timeoutActionName($0, language: language) },
                detail: PlansText.timeoutActionDetail(policy.onApprovalTimeout, language: language))
            PlansMenuRow(
                systemImage: "hourglass", title: zh ? "等电脑、等 key 多久" : "Wait for a computer or key",
                options: PlansText.presets(PlansText.timeoutPresets, including: policy.waitTimeoutSecs),
                selection: $model.policy.waitTimeoutSecs, name: { PlansText.duration($0, language: language) })
        } header: {
            Text(zh ? "策略" : "Policy").textCase(nil)
        }
        .themedRow()
        Section {
            PlansMenuRow(
                systemImage: "timer", title: zh ? "最长跑多久" : "Longest run",
                options: PlansText.presets(PlansText.durationPresets, including: policy.maxDurationSecs),
                selection: $model.policy.maxDurationSecs, name: { PlansText.duration($0, language: language) })
            FormTextField(
                title: zh ? "最多用多少 token" : "Token limit per run", text: $model.policy.maxTokens,
                prompt: zh ? "不限" : "No limit", problem: policy.problem(for: .maxTokens)?.message(language),
                numeric: true)
            FormTextField(
                title: zh ? "最多几步（工具调用）" : "Step limit per run (tool calls)", text: $model.policy.maxSteps,
                prompt: zh ? "不限" : "No limit", problem: policy.problem(for: .maxSteps)?.message(language),
                numeric: true)
            FormTextField(
                title: zh ? "每天最多用多少 token（整个计划）" : "Daily token limit (whole plan)",
                text: $model.policy.dailyTokenLimit, prompt: zh ? "不限" : "No limit",
                problem: policy.problem(for: .dailyTokenLimit)?.message(language),
                hint: zh ? "超过后当天不再运行。" : "Once reached, the plan doesn't run again that day.", numeric: true)
        } header: {
            Text(zh ? "每次运行的上限" : "Per-run limits").textCase(nil)
        }
        .themedRow()
    }

    private func timeoutActions(including current: ApprovalTimeoutAction) -> [ApprovalTimeoutAction] {
        let known = ApprovalTimeoutAction.knownCases
        return known.contains(current) ? known : known + [current]
    }

    private var catchUpSection: some View {
        let zh = language == .chinese
        let model = self.model
        let options =
            CatchUp.knownCases.contains(model.catchUp) ? CatchUp.knownCases : CatchUp.knownCases + [model.catchUp]
        return Section {
            Picker(zh ? "错过的怎么补" : "Missed runs", selection: $model.catchUp) {
                ForEach(options, id: \.self) { option in
                    PlansOptionLabel(
                        title: PlansText.catchUpName(option, language: language),
                        detail: PlansText.catchUpDetail(option, language: language)
                    )
                    .tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text(zh ? "错过的怎么补（平台停机时）" : "Missed runs (during downtime)").textCase(nil)
        }
        .themedRow()
    }
}

/// 编辑器里的一条触发规则：描述、下一次（已有的看服务端的，新加的看本地预测），点开改；右边红色减号或左滑删。
private struct PlanEditorTriggerRow: View {
    let item: PlanTriggerItem
    let draft: TriggerDraft?
    let onChange: @MainActor (Schedule) -> Void
    let onDelete: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        NavigationLink {
            TriggerEditorView(
                draft: draft ?? TriggerDraft(), title: zh ? "修改触发规则" : "Edit schedule", dismissOnSave: true,
                onSave: onChange)
        } label: {
            HStack(spacing: Metrics.Spacing.xs) {
                LabeledRow(
                    systemImage: item.trigger?.isInvalid == true ? "exclamationmark.triangle" : "clock",
                    title: ScheduleDescription.describe(item.schedule, language: language), detail: detail,
                    detailTone: item.trigger?.isInvalid == true ? .failure : nil)
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(StatusTone.failure.color)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(zh ? "删除这条规则" : "Remove this schedule"))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label(zh ? "删除" : "Delete", systemImage: "trash")
            }
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
        Form {
            Section {
                ForEach(kinds, id: \.self) { kind in
                    Toggle(isOn: binding(for: kind)) {
                        VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                            Text(PlansText.toolName(kind, language: language))
                                .typography(.body)
                                .foregroundStyle(Theme.ink)
                            if PlansText.isRiskyTool(kind) {
                                Text(zh ? "有风险" : "Risky")
                                    .typography(.subheadline)
                                    .foregroundStyle(StatusTone.waiting.color)
                            }
                        }
                    }
                }
            } header: {
                Text(
                    zh
                        ? "预授权的工具，Botin 按时运行时用到不用等你审批。只给它需要的；会改文件、跑命令的要谨慎。"
                        : "Pre-approved tools don't need your approval during scheduled runs. Allow only what it needs; "
                            + "be careful with tools that change files or run commands."
                )
                .textCase(nil)
            } footer: {
                if let problem = policy.problems.first(where: {
                    if case .tooManyTools = $0 { return true }
                    return false
                }) {
                    Text(problem.message(language))
                        .foregroundStyle(StatusTone.failure.color)
                }
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
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
