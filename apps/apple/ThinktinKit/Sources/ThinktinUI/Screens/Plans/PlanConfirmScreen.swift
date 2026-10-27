import SwiftUI
import ThinktinKit

/// agent 新建或修改的计划的确认页（`.confirmPlan(id)`：`plan_confirm` 推送、收件箱、对话里的待确认卡片、计划列表的
/// “待确认”分区进来）：
///
/// - 顶上说 agent 做了什么（新建 / 改了），有 App 见过的旧版本时列出改了什么（之前 → 现在），没有时请用户完整核对；
/// - 标题、目标（agent 写的，带 AI 生成标识）、实例、触发规则（说成人话，确认后的下一次在本地预测）、策略、流水线步骤，
///   改过的地方标“改过”；
/// - “确认生效”按看到的版本确认；确认时发现又被改过，换成最新的内容、标出改动，请用户再看一遍；流水线有步骤在已删除的
///   实例上时（11.9）说要先改步骤，不能确认；
/// - “修改后确认”打开编辑页，保存后回到这里按新版本确认；“删除”二次确认后删掉。
///
/// 等确认的计划不能用暂停 / 恢复绕过去，这一页没有那两个按钮。
struct PlanConfirmScreen: View {
    let planID: PlanID

    @Environment(\.client) private var client

    var body: some View {
        PlanConfirmContent(client: client, planID: planID)
    }
}

private struct PlanConfirmContent: View {
    @State private var model: PlanConfirmModel
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, planID: PlanID) {
        _model = State(initialValue: PlanConfirmModel(client: client, planID: planID))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = visibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let outcome = model.outcome {
                    outcomeView(outcome)
                } else if model.isMissing {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark", title: zh ? "这个计划已经不在了" : "This plan is gone",
                        message: zh
                            ? "可能被删除了，或者 agent 又把它取消了。" : "It may have been deleted, or the agent cancelled it.",
                        actionTitle: zh ? "看全部计划" : "All plans"
                    ) {
                        router.open(.plans)
                    }
                } else if let plan = model.plan {
                    review(plan)
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
        .inlineNavigationTitle(AppRoute.confirmPlan(model.planID).title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .onChange(of: model.outcome) {
            if model.outcome != nil { Task { await app.refreshBadges() } }
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
                    ? "不想要这个计划就删掉，agent 那边会知道它不在了。"
                    : "If you don't want this plan, delete it. The agent will see it's gone.")
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                PlanEditorScreen(mode: .edit(model.planID), plan: model.plan) { saved in
                    isEditing = false
                    if let saved { model.applyEdit(saved) }
                }
            }
            .shellEnvironment(app)
            .tint(Theme.accent)
        }
    }

    private var canWrite: Bool { !app.isOffline }

    private func instanceName(_ id: InstanceID) -> String {
        app.instances.first { $0.id == id }?.name ?? (language == .chinese ? "已删除的实例" : "Deleted instance")
    }

    // MARK: 核对

    @ViewBuilder
    private func review(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let kind = model.reviewKind
        PageHeader(
            title: PlansText.reviewHeadline(kind, language: language),
            message: PlansText.reviewMessage(kind, language: language))
        if let conflict = model.conflictChanges {
            InlineNotice(
                systemImage: "arrow.triangle.2.circlepath", tone: .waiting, text: PlansText.conflictMessage(language))
            if !conflict.isEmpty { changesCard(conflict, title: zh ? "刚才又改了" : "Just changed", plan: plan) }
        }
        if case .updated(let changes) = kind, !changes.isEmpty {
            changesCard(changes, title: zh ? "改了什么" : "What changed", plan: plan)
        }
        let blocked = blockedSteps(plan)
        if !blocked.isEmpty {
            InlineNotice(
                systemImage: "exclamationmark.triangle", tone: .waiting,
                text: PlanBlockedSteps.message(blocked, confirming: true, language: language))
        }
        if let error = model.actionError {
            ErrorBanner(error, onDismiss: { model.clearActionError() })
        }

        sectionTitle(zh ? "标题" : "Title", changed: model.isChanged(.title))
        Card {
            PlanTitleText(plan: plan)
            Text(zh ? "在 \(instanceName(plan.instanceID)) 上运行" : "Runs on \(instanceName(plan.instanceID))")
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
        }
        sectionTitle(zh ? "每次要做的事" : "What it does each time", changed: model.isChanged(.goal))
        PlanTextBlock(text: plan.goal, isAIGenerated: PlansText.isAIGenerated(.goal, in: plan))

        sectionTitle(zh ? "什么时候运行" : "When it runs", changed: model.isChanged(.triggers))
        GroupedSection {
            if plan.triggers.isEmpty {
                ListRow(
                    systemImage: "clock.badge.questionmark", title: zh ? "没有触发规则" : "No schedule",
                    detail: zh ? "确认了也不会自动运行。" : "It won't run on its own even after you confirm.")
            }
            ForEach(plan.triggers) { trigger in
                if trigger.id != plan.triggers.first?.id { Divider() }
                ListRow(
                    systemImage: "clock", title: ScheduleDescription.describe(trigger.schedule, language: language),
                    detail: firstFire(trigger.schedule))
            }
        }

        sectionTitle(zh ? "策略" : "Policy", changed: model.isChanged(.policy) || model.isChanged(.catchUp))
        PlanPolicyRows(plan: plan)
        if plan.policy.preauthorizedTools.contains(where: PlansText.isRiskyTool) {
            InlineNotice(
                systemImage: "exclamationmark.shield", tone: .waiting,
                text: zh
                    ? "预授权里有会改文件、删文件或跑命令的工具，按时运行时用到不会再问你。确认前想清楚。"
                    : "Pre-approved tools include ones that change or delete files or run commands; scheduled runs "
                        + "won't ask before using them. Think it over before confirming.")
        }
        if plan.isPipeline {
            sectionTitle(
                zh ? "流水线（\(plan.steps.count) 步）" : "Pipeline (\(plan.steps.count) steps)",
                changed: model.isChanged(.steps))
            PlanStepsView(plan: plan, instanceName: instanceName)
        }
        actions(plan)
    }

    /// 确认后的第一次（本地预测；等确认时服务端不给下一次）。
    private func firstFire(_ schedule: Schedule) -> String? {
        let zh = language == .chinese
        guard let next = ScheduleForecast.nextFires(schedule, after: Date(), count: 1) else { return nil }
        guard let first = next.first else { return zh ? "以后不会再触发" : "Won't fire again" }
        let when = Formatting.dateTime(first, language: language)
        return zh ? "确认后第一次：\(when)" : "First run after you confirm: \(when)"
    }

    private func sectionTitle(_ title: String, changed: Bool) -> some View {
        HStack(spacing: Metrics.Spacing.xs) {
            SectionHeader(title: title)
            if changed {
                PlanChangedTag()
                    .padding(.top, Metrics.Spacing.s)
            }
        }
    }

    /// 改动列表。标题、目标的新内容是 agent 写的（按规则表），后面带 AI 生成标识。
    private func changesCard(_ changes: [PlanChangeItem], title: String, plan: Plan) -> some View {
        let zh = language == .chinese
        return Card {
            Text(title)
                .typography(.headline)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                let line = PlansText.describe(change, language: language, instanceName: instanceName)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(line.label)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                    if let before = line.before {
                        Text((zh ? "之前：" : "Before: ") + before)
                            .typography(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(4)
                    }
                    if let after = line.after {
                        Text((zh ? "现在：" : "Now: ") + after)
                            .typography(.footnote)
                            .foregroundStyle(StatusTone.waiting.color)
                            .lineLimit(4)
                        if isAgentText(change, plan: plan) { AIGeneratedLabel() }
                    }
                }
                .padding(.top, Metrics.Spacing.xxs)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 这处改动的新内容是不是 agent 写的文字（标题、目标）。
    private func isAgentText(_ change: PlanChangeItem, plan: Plan) -> Bool {
        switch change {
        case .title: PlansText.isAIGenerated(.title, in: plan)
        case .goal: PlansText.isAIGenerated(.goal, in: plan)
        default: false
        }
    }

    /// 在已删除的实例上的步骤（11.9，确认会报 409）：确认报过冲突的用查到的；没有时按应用框架的实例列表看（拿到过才看）。
    private func blockedSteps(_ plan: Plan) -> [PlanStep] {
        if !model.blockedSteps.isEmpty { return model.blockedSteps }
        guard plan.isPipeline, app.hasLoadedInstances else { return [] }
        return PlanBlockedSteps.steps(in: plan, liveInstances: Set(app.instances.map(\.id)))
    }

    private func actions(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let model = self.model
        return VStack(spacing: Metrics.Spacing.s) {
            PillButton(
                model.isConfirming ? (zh ? "正在确认…" : "Confirming…") : (zh ? "确认生效" : "Confirm"),
                systemImage: "checkmark"
            ) {
                Task { await model.confirm() }
            }
            .disabled(!model.canConfirm || !canWrite || !blockedSteps(plan).isEmpty)
            PillButton(zh ? "修改后确认" : "Edit, then confirm", systemImage: "pencil", kind: .secondary) {
                isEditing = true
            }
            .disabled(!model.canConfirm || !canWrite)
            PillButton(zh ? "删除" : "Delete", systemImage: "trash", kind: .destructive) {
                isConfirmingDeletion = true
            }
            .disabled(model.isDeleting || model.isConfirming || !canWrite)
            Text(
                zh
                    ? "确认的是你现在看到的版本（第 \(plan.revision) 版）。"
                    : "You're confirming the version you see now (revision \(plan.revision))."
            )
            .typography(.footnote)
            .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Spacing.l)
    }

    // MARK: 结果

    @ViewBuilder
    private func outcomeView(_ outcome: PlanConfirmModel.Outcome) -> some View {
        let zh = language == .chinese
        switch outcome {
        case .confirmed(let plan):
            EmptyStateView(
                systemImage: "checkmark.seal", title: zh ? "已确认" : "Confirmed",
                message: plan.nextFireAt.map { PlansText.nextFire($0, language: language) }
                    ?? (zh ? "计划开始按时运行。" : "The plan now runs on schedule."),
                actionTitle: zh ? "查看计划" : "View plan"
            ) {
                showPlan(plan.id)
            }
        case .notAwaiting(let plan):
            EmptyStateView(
                systemImage: "checkmark.circle", title: zh ? "这个计划不用确认了" : "Nothing to review",
                message: zh ? "可能已经在别的设备上确认过了。" : "It may have been confirmed on another device.",
                actionTitle: zh ? "查看计划" : "View plan"
            ) {
                showPlan(plan.id)
            }
        case .deleted:
            EmptyStateView(
                systemImage: "trash", title: zh ? "已删除" : "Deleted", message: nil,
                actionTitle: zh ? "看全部计划" : "All plans"
            ) {
                router.path.removeAll { $0 == .confirmPlan(model.planID) || $0 == .plan(model.planID) }
                router.open(.plans)
            }
        }
    }

    /// 换成计划详情（确认页从返回栈里拿掉）。
    private func showPlan(_ id: PlanID) {
        router.path.removeAll { $0 == .confirmPlan(id) }
        router.open(.plan(id))
    }
}

#Preview("确认计划 · agent 新建 · 浅色中文") {
    PlanConfirmScreen(planID: DemoData.agentPlanID).previewShell()
}

#Preview("确认计划 · agent 新建 · 深色英文") {
    PlanConfirmScreen(planID: DemoData.agentPlanID).previewShell(.english, scheme: .dark)
}

#Preview("确认计划 · agent 改了用户的计划 · 浅色中文") {
    PlanConfirmScreen(planID: DemoData.digestPlanID).previewShell(client: PlansPreviewClients.agentEditedUserPlan())
}

#Preview("确认计划 · 不用确认 · 深色英文") {
    PlanConfirmScreen(planID: DemoData.digestPlanID).previewShell(.english, scheme: .dark)
}
