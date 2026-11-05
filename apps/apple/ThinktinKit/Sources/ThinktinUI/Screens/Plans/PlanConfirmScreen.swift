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
///
/// 改版（参考里没有这一页，照计划详情排，规范 2.5、2.7）：分组列表，居中的大标题和说明，改动、标题、目标、触发规则、策略、
/// 流水线各一组（改过的组标题后面标“改过”）；“确认生效”是底部浮动的全宽胶囊，“修改后确认”、红字“删除”在最后一组；
/// 结果（已确认、不用确认、已删除）和找不到是 `ContentUnavailableView`。
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
        let reviewing = model.outcome == nil && !model.isMissing ? model.plan : nil
        List {
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let plan = reviewing {
                review(plan)
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if let outcome = model.outcome {
                outcomeView(outcome)
            } else if model.isMissing {
                ContentUnavailableView {
                    Label(zh ? "这个计划已经不在了" : "This plan is gone", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text(zh ? "可能被删除了，或者 Botin 又把它取消了。" : "It may have been deleted, or the Botin cancelled it.")
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
        .floatingBar(edge: .bottom) {
            if let plan = reviewing {
                Button {
                    Task { await model.confirm() }
                } label: {
                    ZStack {
                        Text(zh ? "确认生效" : "Confirm")
                            .opacity(model.isConfirming ? 0 : 1)
                        if model.isConfirming { ProgressView() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(.prominent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!model.canConfirm || !canWrite || !blockedSteps(plan).isEmpty)
                .accessibilityLabel(
                    Text(model.isConfirming ? (zh ? "正在确认" : "Confirming") : (zh ? "确认生效" : "Confirm"))
                )
                .padding(.horizontal, Metrics.Spacing.m)
                .padding(.vertical, Metrics.Spacing.s)
                .frame(maxWidth: Metrics.readableWidth)
            }
        }
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
                    ? "不想要这个计划就删掉，Botin 那边会知道它不在了。"
                    : "If you don't want this plan, delete it. The Botin will see it's gone.")
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
        app.instances.first { $0.id == id }?.name ?? (language == .chinese ? "已删除的 Botin" : "Deleted Botin")
    }

    // MARK: 核对

    @ViewBuilder
    private func review(_ plan: Plan) -> some View {
        let zh = language == .chinese
        let kind = model.reviewKind
        Section {
            VStack(spacing: Metrics.Spacing.xs) {
                Text(PlansText.reviewHeadline(kind, language: language))
                    .font(.title2.bold())
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(PlansText.reviewMessage(kind, language: language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.Spacing.s)
            .clearListRow()
        }
        if let conflict = model.conflictChanges {
            Section {
                PlansNoticeRow(
                    systemImage: "arrow.triangle.2.circlepath", tone: .waiting,
                    text: PlansText.conflictMessage(language))
                changeRows(conflict, plan: plan)
            } header: {
                if !conflict.isEmpty { Text(zh ? "刚才又改了" : "Just changed").textCase(nil) }
            }
            .themedRow()
        }
        if case .updated(let changes) = kind, !changes.isEmpty {
            Section {
                changeRows(changes, plan: plan)
            } header: {
                Text(zh ? "改了什么" : "What changed").textCase(nil)
            }
            .themedRow()
        }
        let blocked = blockedSteps(plan)
        if !blocked.isEmpty {
            Section {
                PlansNoticeRow(
                    systemImage: "exclamationmark.triangle", tone: .waiting,
                    text: PlanBlockedSteps.message(blocked, confirming: true, language: language))
            }
            .themedRow()
        }
        if let error = model.actionError {
            Section {
                ErrorBanner(error, onDismiss: { model.clearActionError() })
                    .clearListRow()
            }
        }
        Section {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                PlanTitleText(plan: plan)
                Text(zh ? "在 \(instanceName(plan.instanceID)) 上运行" : "Runs on \(instanceName(plan.instanceID))")
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.vertical, Metrics.Spacing.xxs)
        } header: {
            sectionTitle(zh ? "标题" : "Title", changed: model.isChanged(.title))
        }
        .themedRow()
        Section {
            PlanTextBlock(text: plan.goal, isAIGenerated: PlansText.isAIGenerated(.goal, in: plan))
        } header: {
            sectionTitle(zh ? "每次要做的事" : "What it does each time", changed: model.isChanged(.goal))
        }
        .themedRow()
        Section {
            if plan.triggers.isEmpty {
                LabeledRow(
                    systemImage: "clock.badge.questionmark", title: zh ? "没有触发规则" : "No schedule",
                    detail: zh ? "确认了也不会自动运行。" : "It won't run on its own even after you confirm.")
            }
            ForEach(plan.triggers) { trigger in
                LabeledRow(
                    systemImage: "clock", title: ScheduleDescription.describe(trigger.schedule, language: language),
                    detail: firstFire(trigger.schedule))
            }
        } header: {
            sectionTitle(zh ? "什么时候运行" : "When it runs", changed: model.isChanged(.triggers))
        }
        .themedRow()
        Section {
            PlanPolicyRows(plan: plan)
            if plan.policy.preauthorizedTools.contains(where: PlansText.isRiskyTool) {
                PlansNoticeRow(
                    systemImage: "exclamationmark.shield", tone: .waiting,
                    text: zh
                        ? "预授权里有会改文件、删文件或跑命令的工具，按时运行时用到不会再问你。确认前想清楚。"
                        : "Pre-approved tools include ones that change or delete files or run commands; scheduled runs "
                            + "won't ask before using them. Think it over before confirming.")
            }
        } header: {
            sectionTitle(zh ? "策略" : "Policy", changed: model.isChanged(.policy) || model.isChanged(.catchUp))
        } footer: {
            if let detail = PlansText.catchUpDetail(plan.catchUp, language: language) { Text(detail) }
        }
        .themedRow()
        if plan.isPipeline {
            Section {
                PlanStepsView(plan: plan, instanceName: instanceName)
            } header: {
                sectionTitle(
                    zh ? "流水线（\(plan.steps.count) 步）" : "Pipeline (\(plan.steps.count) steps)",
                    changed: model.isChanged(.steps))
            }
            .themedRow()
        }
        Section {
            Button {
                isEditing = true
            } label: {
                Label(zh ? "修改后确认" : "Edit, then confirm", systemImage: "pencil")
            }
            .disabled(!model.canConfirm || !canWrite)
            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                Label(zh ? "删除" : "Delete", systemImage: "trash")
            }
            .disabled(model.isDeleting || model.isConfirming || !canWrite)
        } footer: {
            Text(
                zh
                    ? "确认的是你现在看到的版本（第 \(plan.revision) 版）。"
                    : "You're confirming the version you see now (revision \(plan.revision)).")
        }
        .themedRow()
    }

    /// 确认后的第一次（本地预测；等确认时服务端不给下一次）。
    private func firstFire(_ schedule: Schedule) -> String? {
        let zh = language == .chinese
        guard let next = ScheduleForecast.nextFires(schedule, after: Date(), count: 1) else { return nil }
        guard let first = next.first else { return zh ? "以后不会再触发" : "Won't fire again" }
        let when = Formatting.dateTime(first, language: language)
        return zh ? "确认后第一次：\(when)" : "First run after you confirm: \(when)"
    }

    /// 组标题，改过的后面标“改过”。
    private func sectionTitle(_ title: String, changed: Bool) -> some View {
        HStack(spacing: Metrics.Spacing.xs) {
            Text(title)
            if changed { PlanChangedTag() }
        }
        .textCase(nil)
    }

    /// 改动列表，一处一行（之前 → 现在）。标题、目标的新内容是 agent 写的（按规则表），后面带 AI 生成标识。
    private func changeRows(_ changes: [PlanChangeItem], plan: Plan) -> some View {
        let zh = language == .chinese
        return ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
            let line = PlansText.describe(change, language: language, instanceName: instanceName)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(line.label)
                    .typography(.body)
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
            .padding(.vertical, Metrics.Spacing.unit / 2)
            .accessibilityElement(children: .combine)
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

    // MARK: 结果

    @ViewBuilder
    private func outcomeView(_ outcome: PlanConfirmModel.Outcome) -> some View {
        let zh = language == .chinese
        switch outcome {
        case .confirmed(let plan):
            ContentUnavailableView {
                Label(zh ? "已确认" : "Confirmed", systemImage: "checkmark.seal")
            } description: {
                Text(
                    plan.nextFireAt.map { PlansText.nextFire($0, language: language) }
                        ?? (zh ? "计划开始按时运行。" : "The plan now runs on schedule."))
            } actions: {
                Button(zh ? "查看计划" : "View plan") { showPlan(plan.id) }
                    .glassButtonStyle(.prominent)
            }
        case .notAwaiting(let plan):
            ContentUnavailableView {
                Label(zh ? "这个计划不用确认了" : "Nothing to review", systemImage: "checkmark.circle")
            } description: {
                Text(zh ? "可能已经在别的设备上确认过了。" : "It may have been confirmed on another device.")
            } actions: {
                Button(zh ? "查看计划" : "View plan") { showPlan(plan.id) }
                    .glassButtonStyle()
            }
        case .deleted:
            ContentUnavailableView {
                Label(zh ? "已删除" : "Deleted", systemImage: "trash")
            } actions: {
                Button(zh ? "看全部计划" : "All plans") {
                    router.removeRoutes { $0 == .confirmPlan(model.planID) || $0 == .plan(model.planID) }
                    router.open(.plans(instanceID: nil))
                }
                .glassButtonStyle()
            }
        }
    }

    /// 换成计划详情（确认页从它所在的那层栈里拿掉）。
    private func showPlan(_ id: PlanID) {
        router.removeRoutes { $0 == .confirmPlan(id) }
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
