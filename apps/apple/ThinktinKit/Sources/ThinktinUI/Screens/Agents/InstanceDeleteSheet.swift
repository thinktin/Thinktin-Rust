import SwiftUI
import ThinktinKit

/// 删除实例的确认页（实例详情弹出，自带导航栈）：先查影响（`InstanceDetailModel.prepareDeletion()`），列出
///
/// - 会停掉的、还没结束的任务；
/// - 一起删掉的：这个实例自己的计划（agent 建的带 AI 生成标识）、产出物、模型路由、工作区和对话记录；
/// - 别的实例的流水线里在它上面的步骤（11.9）：步骤留着，正在生效的流水线暂停，改了步骤才能恢复、确认；
/// - 会从哪些团队里移除（是负责人的、删完团队没人了的单独提醒）。
///
/// “删除实例”之后还有一次系统确认框（二次确认）。删掉了就关掉，实例详情页负责离开、刷新实例列表。
struct InstanceDeleteSheet: View {
    let model: InstanceDetailModel
    let onClose: @MainActor () -> Void

    @State private var isConfirming = false

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let name = model.instance?.name ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    Image(systemName: "trash")
                        .font(Typography.title.font)
                        .foregroundStyle(StatusTone.failure.color)
                        .accessibilityHidden(true)
                    Text(zh ? "删除“\(name)”？" : "Delete “\(name)”?")
                        .typography(.title)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        zh
                            ? "删除后不能恢复。下面是会一起受影响的内容。"
                            : "This can't be undone. Here's what else is affected."
                    )
                    .typography(.body)
                    .foregroundStyle(Theme.inkSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Metrics.Spacing.xs)

                if let impact = model.deletionImpact {
                    InstanceDeletionImpactView(impact: impact)
                    if impact.isIncomplete {
                        AgentsNotice(
                            systemImage: "exclamationmark.triangle", tone: .waiting,
                            text: zh
                                ? "有些信息没查到，可能还有别的计划或团队受影响。可以重试，也可以照样删除。"
                                : "Some details couldn't be loaded, so other plans or teams may also be affected. "
                                    + "You can retry or delete anyway.")
                        if let error = model.impactError {
                            ErrorBanner(error) { Task { await model.prepareDeletion() } }
                        }
                    }
                } else if model.isCheckingImpact {
                    AgentsLoadingView()
                }

                if let error = model.deleteError {
                    ErrorBanner(error) { isConfirming = true }
                }

                PillButton(
                    model.isDeleting ? (zh ? "正在删除…" : "Deleting…") : (zh ? "删除实例" : "Delete instance"),
                    systemImage: model.isDeleting ? nil : "trash", kind: .destructive
                ) {
                    isConfirming = true
                }
                .disabled(model.isDeleting || model.isCheckingImpact || app.isOffline)
                .frame(maxWidth: .infinity)
                .padding(.top, Metrics.Spacing.s)
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(zh ? "删除实例" : "Delete instance")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(zh ? "取消" : "Cancel") { onClose() }
                    .disabled(model.isDeleting)
            }
        }
        .interactiveDismissDisabled(model.isDeleting)
        // 每次打开都重新查（计划、团队可能刚改过）；查的时候先显示上次的。
        .task { await model.prepareDeletion() }
        .confirmationDialog(
            zh ? "确定删除“\(name)”？" : "Delete “\(name)”?", isPresented: $isConfirming, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task {
                    if await model.delete() { onClose() }
                }
            } label: {
                Text(zh ? "删除，不能恢复" : "Delete permanently")
            }
            Button(role: .cancel) {
                isConfirming = false
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    /// 二次确认框里的一句话：有级联的再强调一遍。
    private var confirmationMessage: String {
        let zh = language == .chinese
        guard let impact = model.deletionImpact else {
            return zh ? "实例、它的计划和产出物都会删掉。" : "The instance, its plans and its artifacts will be deleted."
        }
        var parts: [String] = []
        if impact.activeRuns > 0 {
            parts.append(zh ? "停掉 \(impact.activeRuns) 个正在进行的任务" : "stop \(impact.activeRuns) running task(s)")
        }
        if !impact.pipelines.isEmpty {
            let count = impact.pipelines.count
            parts.append(zh ? "让 \(count) 条流水线停下来，等你改步骤" : "hold \(count) pipeline(s) until you change their steps")
        }
        if !impact.teams.isEmpty {
            parts.append(zh ? "从 \(impact.teams.count) 个团队里移除" : "remove it from \(impact.teams.count) team(s)")
        }
        guard !parts.isEmpty else {
            return zh ? "实例、它的计划和产出物都会删掉。" : "The instance, its plans and its artifacts will be deleted."
        }
        return zh
            ? "会" + AgentsText.list(parts, language: language) + "。"
            : "This will " + AgentsText.list(parts, language: language) + "."
    }
}

/// 影响清单。
struct InstanceDeletionImpactView: View {
    let impact: InstanceDeletionImpact

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            if impact.activeRuns > 0 {
                AgentsSectionHeader(title: zh ? "会停掉" : "Will be stopped")
                AgentsGroup {
                    AgentsRow(
                        systemImage: "stop.circle",
                        title: zh ? "\(impact.activeRuns) 个还没结束的任务" : "\(impact.activeRuns) unfinished task(s)",
                        detail: zh ? "正在跑的、排队的、等审批的都会取消。" : "Running, queued and waiting tasks are cancelled.",
                        detailTone: .waiting)
                }
            }

            AgentsSectionHeader(title: zh ? "会一起删掉" : "Will be deleted")
            AgentsGroup {
                ForEach(impact.ownPlans) { plan in
                    AgentsRow(
                        systemImage: "calendar", title: plan.title, detail: zh ? "这个实例的计划" : "This instance's plan",
                        accessory: {
                            if AgentsText.isAIGenerated(plan) { AIGeneratedLabel() }
                        })
                    Divider()
                }
                if let count = impact.artifactCount, count > 0 {
                    // 只数到接口的上限，到了上限写“500+”。
                    let countText = count >= InstanceDeletionImpact.artifactsToCheck ? "\(count)+" : "\(count)"
                    AgentsRow(
                        systemImage: "doc.on.doc", title: zh ? "\(countText) 个产出物" : "\(countText) artifact(s)")
                    Divider()
                }
                AgentsRow(
                    systemImage: "shippingbox",
                    title: zh ? "沙箱、工作区和对话记录" : "The sandbox, its workspace and chat history",
                    detail: zh ? "模型路由也会一起删掉；你的模型 key 不受影响。" : "Its model routes go too; your model keys stay.")
            }

            if !impact.pipelines.isEmpty {
                AgentsSectionHeader(title: zh ? "这些流水线有步骤在它上面" : "Pipelines with steps on it")
                AgentsGroup {
                    ForEach(impact.pipelines) { pipeline in
                        if pipeline.id != impact.pipelines.first?.id { Divider() }
                        InstancePipelineImpactRow(pipeline: pipeline)
                    }
                }
            }

            if !impact.teams.isEmpty {
                AgentsSectionHeader(title: zh ? "会从这些团队里移除" : "Will be removed from these teams")
                AgentsGroup {
                    ForEach(impact.teams) { team in
                        if team.id != impact.teams.first?.id { Divider() }
                        AgentsRow(
                            systemImage: "person.3", title: team.teamName, detail: teamDetail(team),
                            detailTone: team.isLead || team.remainingMembers == 0 ? .waiting : nil)
                    }
                }
            }
        }
    }

    private func teamDetail(_ team: InstanceDeletionImpact.TeamImpact) -> String {
        let zh = language == .chinese
        var parts: [String] = []
        if team.isLead { parts.append(zh ? "它是负责人，删掉后团队没有负责人" : "It's the lead; the team will have no lead") }
        if team.remainingMembers == 0 {
            parts.append(zh ? "删掉后团队里没有成员了" : "The team will have no members left")
        } else if !team.isLead {
            parts.append(zh ? "还剩 \(team.remainingMembers) 个成员" : "\(team.remainingMembers) member(s) left")
        }
        return parts.joined(separator: zh ? "；" : "; ")
    }
}

/// 一条流水线：在这个实例上的步骤，删除后流水线怎样（11.9：步骤留着，改到别的实例上之前恢复、确认都不行）。
private struct InstancePipelineImpactRow: View {
    let pipeline: InstanceDeletionImpact.PipelineImpact

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let steps = AgentsText.list(pipeline.stepsOnInstance.map(\.key), language: language)
        AgentsRow(
            systemImage: pipeline.willPause ? "pause.circle" : "flowchart",
            title: pipeline.plan.title,
            detail: zh ? "在它上面的步骤：\(steps)" : "Steps on it: \(steps)",
            accessory: {
                if AgentsText.isAIGenerated(pipeline.plan) { AIGeneratedLabel() }
                Text(pipeline.effect.message(language))
                    .typography(.footnote)
                    .foregroundStyle(StatusTone.waiting.color)
                    .fixedSize(horizontal: false, vertical: true)
            })
    }
}

#Preview("删除实例 · 浅色中文") {
    InstanceDeletePreview(instanceID: DemoData.reviewerID).previewShell(client: AgentsPreviewClients.withPipeline())
}

#Preview("删除实例 · 深色英文") {
    InstanceDeletePreview(instanceID: DemoData.writerID)
        .previewShell(.english, scheme: .dark, client: AgentsPreviewClients.withPipeline())
}
