import SwiftUI
import ThinktinKit

/// 流水线编辑器（`.pipelineEditor(planID:teamID:)`，WBS 12.7）：每步一张卡片，键名、执行的实例、提示词、等哪几步做完；
/// 上下挪、删除，最多 20 步。问题在点保存后标在对应的地方（本地按服务端的规则查，`PipelineRules`）。
///
/// - 计划详情进来（`planID`）：只改步骤，保存后回到计划详情；
/// - 团队详情进来（`teamID`）：每个成员一步、负责人最后汇总，填标题、目标后创建，建好后去计划详情（加触发规则）。
///
/// 有没保存的改动时返回键换成“取消”，先问一句。
struct PipelineEditorScreen: View {
    let planID: PlanID?
    let teamID: TeamID?

    @Environment(\.client) private var client

    var body: some View {
        PipelineEditorContent(model: PipelineEditorModel(client: client, planID: planID, teamID: teamID))
    }
}

private struct PipelineEditorContent: View {
    @State private var model: PipelineEditorModel
    @State private var isConfirmingDiscard = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: PipelineEditorModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: model.isEditing
                            ? (zh ? "找不到这个计划" : "Plan not found") : (zh ? "找不到这个团队" : "Team not found"),
                        message: zh ? "可能已经删掉了。" : "It may have been deleted.")
                } else if model.hasLoaded {
                    form
                } else if let error = model.error {
                    ErrorBanner(error) { Task { await model.load() } }
                } else {
                    AgentsLoadingView()
                }
            }
            .agentsPageLayout()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.pipelineEditor(planID: model.planID, teamID: model.teamID).title(language))
        .navigationBarBackButtonHidden(model.hasChanges || model.isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.hasChanges || model.isSaving {
                    Button(zh ? "取消" : "Cancel") { isConfirmingDiscard = true }
                        .disabled(model.isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    Task {
                        guard let saved = await model.save() else { return }
                        router.pop()
                        if !model.isEditing { router.open(.plan(saved.id)) }
                    }
                }
                .disabled(
                    model.isSaving || !model.hasLoaded || app.isOffline || (model.isEditing && !model.hasChanges))
            }
        }
        .task { await model.load() }
        .confirmationDialog(
            zh ? "放弃修改？" : "Discard changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                router.pop()
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
        return model.isEditing ? (zh ? "保存" : "Save") : (zh ? "创建" : "Create")
    }

    @ViewBuilder
    private var form: some View {
        let zh = language == .chinese
        let model = self.model
        if let error = model.saveError {
            ErrorBanner(error, onDismiss: { model.clearSaveError() })
        }
        Text(TeamsText.pipelineIntro(language))
            .typography(.subheadline)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.Spacing.xs)
        if model.isEditing {
            if let plan = model.plan {
                AgentsGroup {
                    AgentsRow(
                        systemImage: "calendar", title: plan.title,
                        detail: model.instanceName(plan.instanceID).map { zh ? "挂在：\($0)" : "Runs on: \($0)" })
                }
            }
        } else {
            basics
        }
        AgentsSectionHeader(
            title: zh
                ? "步骤（\(model.steps.count)/\(PipelineRules.maxSteps)）"
                : "Steps (\(model.steps.count)/\(PipelineRules.maxSteps))")
        ForEach(model.generalProblems, id: \.self) { problem in
            problemText(TeamsText.stepProblem(problem, language: language))
        }
        if model.instances.isEmpty {
            AgentsNotice(
                systemImage: "exclamationmark.triangle", tone: .waiting,
                text: zh ? "还没有实例，先去 agent 目录领养。" : "No instances yet. Adopt one from the catalog first.")
        }
        ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
            PipelineStepCard(
                model: model, step: step, index: index, isFirst: index == 0, isLast: index == model.steps.count - 1)
        }
        PillButton(zh ? "加一步" : "Add a step", systemImage: "plus", kind: .secondary) {
            model.addStep()
        }
        .frame(maxWidth: .infinity)
        .disabled(!model.canAddStep || model.instances.isEmpty)
        if !model.canAddStep {
            Text(zh ? "最多 \(PipelineRules.maxSteps) 步。" : "Up to \(PipelineRules.maxSteps) steps.")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var basics: some View {
        let zh = language == .chinese
        let model = self.model
        AgentsSectionHeader(title: zh ? "计划" : "Plan")
        PlansTextField(
            title: zh ? "标题" : "Title", text: $model.title, prompt: zh ? "比如：每周竞品调研" : "For example: Weekly research",
            limit: Plan.maxTitleLength, count: PlanTextProblem.length(model.title),
            problem: model.showsProblems ? model.titleProblem.map { PlanFormProblem.title($0).message(language) } : nil)
        PlansTextField(
            title: zh ? "目标" : "Goal", text: $model.goal,
            prompt: zh ? "整条流水线要做成什么。" : "What the whole pipeline should achieve.", multiline: true,
            limit: Plan.maxGoalLength, count: PlanTextProblem.length(model.goal),
            problem: model.showsProblems ? model.goalProblem.map { PlanFormProblem.goal($0).message(language) } : nil)
        if let host = model.instanceName(model.hostInstanceID) {
            AgentsGroup {
                AgentsRow(
                    systemImage: "star", title: zh ? "挂在：\(host)" : "Runs on: \(host)",
                    detail: zh
                        ? "计划挂在这个实例上（团队的负责人），建好后不能换。"
                        : "The plan belongs to this instance (the team's lead). It can't be changed later.")
            }
        }
        AgentsNotice(systemImage: "clock", tone: .neutral, text: TeamsText.newPipelineNote(language))
    }

    private func problemText(_ text: String) -> some View {
        Text(text)
            .typography(.footnote)
            .foregroundStyle(StatusTone.failure.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.Spacing.xs)
    }
}

/// 一步的卡片：键名、实例、提示词、依赖；右上角上移、下移、删除。
struct PipelineStepCard: View {
    let model: PipelineEditorModel
    let step: StepDraft
    let index: Int
    let isFirst: Bool
    let isLast: Bool

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let step = self.step
        let problems = model.problems(of: step.id)
        let others = model.steps.filter { $0.id != step.id }
        let keys = Set(others.map { $0.key.trimmingCharacters(in: .whitespaces) })
        let unknown = step.dependsOn.filter { !keys.contains($0) }
        AgentsGroup {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                HStack(spacing: Metrics.Spacing.xxs) {
                    Text(zh ? "第 \(index + 1) 步" : "Step \(index + 1)")
                        .typography(.headline)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    iconButton("arrow.up", label: zh ? "上移" : "Move up") { model.moveStep(step.id, by: -1) }
                        .disabled(isFirst)
                    iconButton("arrow.down", label: zh ? "下移" : "Move down") { model.moveStep(step.id, by: 1) }
                        .disabled(isLast)
                    iconButton("trash", label: zh ? "删除这一步" : "Remove this step", tint: StatusTone.failure.color) {
                        model.removeStep(step.id)
                    }
                }
                PlansTextField(
                    title: zh ? "键名" : "Key",
                    text: Binding(get: { step.key }, set: { model.setKey(step.id, $0) }), prompt: "step1",
                    problem: message(
                        problems, matching: { [.badKey(stepID: step.id), .duplicateKey(stepID: step.id)].contains($0) }),
                    hint: zh ? "别的步骤用它来等这一步。" : "Other steps use it to wait for this one.", monospaced: true)
                instancePicker(
                    problem: message(problems) {
                        $0 == .noInstance(stepID: step.id) || $0 == .deletedInstance(stepID: step.id)
                    })
                PlansTextField(
                    title: zh ? "这一步做什么" : "What this step does",
                    text: Binding(get: { step.prompt }, set: { model.setPrompt(step.id, $0) }),
                    prompt: zh ? "写给这个实例的任务。" : "The task for this instance.", multiline: true,
                    limit: PipelineRules.maxPrompt, count: PlanTextProblem.length(step.prompt),
                    problem: message(problems) {
                        $0 == .emptyPrompt(stepID: step.id) || $0 == .promptTooLong(stepID: step.id)
                    })
                if !others.isEmpty || !unknown.isEmpty {
                    dependencies(others: others, unknown: unknown, problems: problems)
                }
            }
            .padding(Metrics.Spacing.m)
        }
    }

    private func message(_ problems: [StepProblem], matching: (StepProblem) -> Bool) -> String? {
        problems.first(where: matching).map { TeamsText.stepProblem($0, language: language) }
    }

    private func iconButton(
        _ systemImage: String, label: String, tint: Color = Theme.inkSecondary, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func instancePicker(problem: String?) -> some View {
        let zh = language == .chinese
        let model = self.model
        let step = self.step
        let name = model.instanceName(step.instanceID)
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(zh ? "执行的实例" : "Instance")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            Menu {
                ForEach(model.instances) { instance in
                    Button {
                        model.setInstance(step.id, instance.id)
                    } label: {
                        if instance.id == step.instanceID {
                            Label(instance.name, systemImage: "checkmark")
                        } else {
                            Text(verbatim: instance.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: Metrics.Spacing.xs) {
                    Text(
                        name
                            ?? (step.instanceID == nil
                                ? (zh ? "选一个实例" : "Pick an instance") : (zh ? "已删除的实例" : "Deleted instance"))
                    )
                    .typography(.body)
                    .foregroundStyle(name == nil ? Theme.inkTertiary : Theme.ink)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Metrics.Spacing.s)
                .frame(minHeight: Metrics.minTapTarget)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(zh ? "执行的实例" : "Instance"))
            .accessibilityValue(Text(verbatim: name ?? ""))
            if let problem {
                Text(problem)
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dependencies(others: [StepDraft], unknown: [String], problems: [StepProblem]) -> some View {
        let zh = language == .chinese
        let model = self.model
        let step = self.step
        let problem = message(problems) {
            if case .unknownDependency = $0 { return true }
            return $0 == .selfDependency(stepID: step.id)
        }
        return VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(zh ? "等这几步做完再开始" : "Start after these steps")
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(others) { other in
                let key = other.key.trimmingCharacters(in: .whitespaces)
                dependencyRow(
                    title: key.isEmpty ? (zh ? "（没有键名）" : "(no key)") : key,
                    detail: model.instanceName(other.instanceID), isOn: step.dependsOn.contains(key)
                ) {
                    model.toggleDependency(step.id, on: key)
                }
                .disabled(key.isEmpty)
            }
            ForEach(unknown, id: \.self) { key in
                dependencyRow(title: key, detail: zh ? "不在了，点掉" : "Gone. Tap to remove", isOn: true) {
                    model.toggleDependency(step.id, on: key)
                }
            }
            if let problem {
                Text(problem)
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.failure.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dependencyRow(
        title: String, detail: String?, isOn: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Theme.accent : Theme.inkTertiary)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(Typography.subheadline.monospacedFont)
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(verbatim: detail)
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("流水线编辑器 · 浅色中文") {
    PipelineEditorScreen(planID: nil, teamID: DemoData.releaseTeamID).previewShell()
}

#Preview("流水线编辑器 · 深色英文") {
    PipelineEditorScreen(planID: nil, teamID: DemoData.releaseTeamID).previewShell(.english, scheme: .dark)
}
