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
        Form {
            if model.hasLoaded, !model.isMissing {
                formSections
            } else if !model.isMissing, let error = model.error {
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
                    Label(
                        model.isEditing
                            ? (zh ? "找不到这个计划" : "Plan not found") : (zh ? "找不到这个团队" : "Team not found"),
                        systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text(zh ? "可能已经删掉了。" : "It may have been deleted.")
                }
            } else if !model.hasLoaded, model.error == nil {
                ProgressView()
            }
        }
        .inlineNavigationTitle(AppRoute.pipelineEditor(planID: model.planID, teamID: model.teamID).title(language))
        .navigationBarBackButtonHidden(model.hasChanges || model.isSaving)
        .toolbar {
            if model.hasChanges || model.isSaving {
                ToolbarItem(placement: .cancellationAction) {
                    Button(zh ? "取消" : "Cancel") { isConfirmingDiscard = true }
                        .disabled(model.isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(
                    model.isEditing ? (zh ? "保存" : "Save") : (zh ? "创建" : "Create"), isWorking: model.isSaving
                ) {
                    Task {
                        guard let saved = await model.save() else { return }
                        router.pop()
                        if !model.isEditing { router.open(.plan(saved.id)) }
                    }
                }
                .disabled(!model.hasLoaded || app.isOffline || (model.isEditing && !model.hasChanges))
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

    @ViewBuilder
    private var formSections: some View {
        let zh = language == .chinese
        let model = self.model
        if let error = model.saveError {
            Section {
                ErrorBanner(error, onDismiss: { model.clearSaveError() })
                    .clearListRow()
            }
        }
        Section {
            Text(TeamsText.pipelineIntro(language))
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.Spacing.m)
                .clearListRow()
        }
        if model.isEditing {
            if let plan = model.plan {
                Section {
                    LabeledRow(
                        systemImage: "calendar", title: plan.title,
                        detail: model.instanceName(plan.instanceID).map { zh ? "挂在：\($0)" : "Runs on: \($0)" })
                } header: {
                    Text(zh ? "计划" : "Plan").textCase(nil)
                }
                .themedRow()
            }
        } else {
            basics
        }
        if model.instances.isEmpty || !model.generalProblems.isEmpty {
            Section {
                if model.instances.isEmpty {
                    Text(zh ? "还没有 Botin，先新建一个。" : "No Botins yet. Create one first.")
                        .typography(.body)
                        .foregroundStyle(Theme.inkTertiary)
                }
                ForEach(model.generalProblems, id: \.self) { problem in
                    Text(TeamsText.stepProblem(problem, language: language))
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.failure.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .themedRow()
        }
        ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
            PipelineStepCard(
                model: model, step: step, index: index, isFirst: index == 0, isLast: index == model.steps.count - 1)
        }
        Section {
            Button {
                model.addStep()
            } label: {
                Label(zh ? "加一步" : "Add a step", systemImage: "plus")
            }
            .disabled(!model.canAddStep || model.instances.isEmpty)
        } footer: {
            Text(
                zh
                    ? "共 \(model.steps.count) 步，最多 \(PipelineRules.maxSteps) 步。"
                    : "\(model.steps.count) of up to \(PipelineRules.maxSteps) steps.")
        }
        .themedRow()
    }

    @ViewBuilder
    private var basics: some View {
        let zh = language == .chinese
        @Bindable var bindable = model
        Section {
            FormTextField(
                title: zh ? "标题" : "Title", text: $bindable.title,
                prompt: zh ? "比如：每周竞品调研" : "For example: Weekly research",
                limit: Plan.maxTitleLength, count: PlanTextProblem.length(model.title),
                problem: model.showsProblems
                    ? model.titleProblem.map { PlanFormProblem.title($0).message(language) } : nil)
            FormTextField(
                title: zh ? "目标" : "Goal", text: $bindable.goal,
                prompt: zh ? "整条流水线要做成什么。" : "What the whole pipeline should achieve.", multiline: true,
                limit: Plan.maxGoalLength, count: PlanTextProblem.length(model.goal),
                problem: model.showsProblems
                    ? model.goalProblem.map { PlanFormProblem.goal($0).message(language) } : nil)
            if let host = model.instanceName(model.hostInstanceID) {
                LabeledRow(
                    systemImage: "star", title: zh ? "挂在：\(host)" : "Runs on: \(host)",
                    detail: zh
                        ? "计划挂在这个 Botin 上（团队的负责人），建好后不能换。"
                        : "The plan belongs to this Botin (the team's lead). It can't be changed later.")
            }
        } header: {
            Text(zh ? "计划" : "Plan").textCase(nil)
        } footer: {
            Text(TeamsText.newPipelineNote(language))
        }
        .themedRow()
    }
}

/// 一步是表单里的一组：组标题“第 N 步”，右边 `ellipsis` 菜单（上移、下移、删除）；键名、执行的 Botin（`Picker(.menu)`）、
/// 这一步做什么，等哪几步做完（一行一步，选中的右边系统勾）；问题写在组的脚注里。
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
        let instanceProblem = message(problems) {
            $0 == .noInstance(stepID: step.id) || $0 == .deletedInstance(stepID: step.id)
        }
        let dependencyProblem = message(problems) {
            if case .unknownDependency = $0 { return true }
            return $0 == .selfDependency(stepID: step.id)
        }
        Section {
            FormTextField(
                title: zh ? "键名" : "Key",
                text: Binding(get: { step.key }, set: { model.setKey(step.id, $0) }), prompt: "step1",
                problem: message(
                    problems, matching: { [.badKey(stepID: step.id), .duplicateKey(stepID: step.id)].contains($0) }),
                hint: zh ? "别的步骤用它来等这一步。" : "Other steps use it to wait for this one.", monospaced: true)
            Picker(zh ? "执行的 Botin" : "Botin", selection: instanceBinding) {
                if step.instanceID == nil || model.instanceName(step.instanceID) == nil {
                    Text(
                        step.instanceID == nil
                            ? (zh ? "选一个 Botin" : "Pick a Botin") : (zh ? "已删除的 Botin" : "Deleted Botin")
                    )
                    .tag(step.instanceID)
                }
                ForEach(model.instances) { instance in
                    Text(verbatim: instance.name).tag(InstanceID?.some(instance.id))
                }
            }
            .pickerStyle(.menu)
            FormTextField(
                title: zh ? "这一步做什么" : "What this step does",
                text: Binding(get: { step.prompt }, set: { model.setPrompt(step.id, $0) }),
                prompt: zh ? "写给这个 Botin 的任务。" : "The task for this Botin.", multiline: true,
                limit: PipelineRules.maxPrompt, count: PlanTextProblem.length(step.prompt),
                problem: message(problems) {
                    $0 == .emptyPrompt(stepID: step.id) || $0 == .promptTooLong(stepID: step.id)
                })
            if !others.isEmpty || !unknown.isEmpty {
                Text(zh ? "等这几步做完再开始" : "Start after these steps")
                    .font(.footnote)
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
            }
        } header: {
            HStack {
                Text(zh ? "第 \(index + 1) 步" : "Step \(index + 1)")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Menu {
                    Button {
                        model.moveStep(step.id, by: -1)
                    } label: {
                        Label(zh ? "上移" : "Move up", systemImage: "arrow.up")
                    }
                    .disabled(isFirst)
                    Button {
                        model.moveStep(step.id, by: 1)
                    } label: {
                        Label(zh ? "下移" : "Move down", systemImage: "arrow.down")
                    }
                    .disabled(isLast)
                    Button(role: .destructive) {
                        model.removeStep(step.id)
                    } label: {
                        Label(zh ? "删除这一步" : "Remove this step", systemImage: "trash")
                    }
                } label: {
                    Label(zh ? "第 \(index + 1) 步的操作" : "Actions for step \(index + 1)", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.iconButton)
                }
            }
            .textCase(nil)
        } footer: {
            let footnotes = [instanceProblem, dependencyProblem].compactMap { $0 }
            if !footnotes.isEmpty {
                Text(footnotes.joined(separator: "\n"))
                    .foregroundStyle(StatusTone.failure.color)
            }
        }
        .themedRow()
    }

    private var instanceBinding: Binding<InstanceID?> {
        let model = self.model
        let id = step.id
        return Binding(
            get: { step.instanceID },
            set: { value in
                if let value { model.setInstance(id, value) }
            })
    }

    private func message(_ problems: [StepProblem], matching: (StepProblem) -> Bool) -> String? {
        problems.first(where: matching).map { TeamsText.stepProblem($0, language: language) }
    }

    /// 一行可选的上游步骤：键名（等宽）、执行它的 Botin，选中的右边系统勾。
    private func dependencyRow(
        title: String, detail: String?, isOn: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.Spacing.xs) {
                Text(verbatim: title)
                    .font(Typography.body.monospacedFont)
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(verbatim: detail)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
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
