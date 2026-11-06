import SwiftUI
import ThinktinKit

/// 删除实例的确认页（自带导航栈）。2026-11-06 资料页“…”和首页长按“更多”里的删除照参考去掉了（参考里没有删除 Bot，
/// 规范 1.5），这一页现在没有入口，等用户定删除放哪；放回来时 sheet 弹它，关掉后删成了调
/// `InstanceDetailScreen.leaveDeletedInstance`。先查影响（`InstanceDetailModel.prepareDeletion()`），列出
///
/// - 会停掉的、还没结束的任务；
/// - 一起删掉的：这个实例自己的计划（agent 建的带 AI 生成标识）、产出物、模型路由、工作区和对话记录；
/// - 别的实例的流水线里在它上面的步骤（11.9）：步骤留着，正在生效的流水线暂停，改了步骤才能恢复、确认；
/// - 会从哪些团队里移除（是负责人的、删完团队没人了的单独提醒）。
///
/// “删除这个 Botin”之后还有一次系统确认框（二次确认）。删掉了就关掉，弹它的页面负责离开、刷新实例列表。
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
        List {
            Section {
                VStack(spacing: Metrics.Spacing.xs) {
                    Image(systemName: "trash")
                        .font(Typography.title.font)
                        .foregroundStyle(StatusTone.failure.color)
                        .accessibilityHidden(true)
                    Text(zh ? "删除“\(name)”？" : "Delete “\(name)”?")
                        .font(Font.title2.bold())
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(zh ? "删除后不能恢复。下面是会一起受影响的内容。" : "This can't be undone. Here's what else is affected.")
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.Spacing.s)
                .clearListRow()
            }
            if let impact = model.deletionImpact {
                InstanceDeletionImpactView(impact: impact)
                if impact.isIncomplete {
                    Section {
                        NoticeRow(
                            systemImage: "exclamationmark.triangle", tone: .waiting,
                            text: zh
                                ? "有些信息没查到，可能还有别的计划或团队受影响。可以重试，也可以照样删除。"
                                : "Some details couldn't be loaded, so other plans or teams may also be affected. "
                                    + "You can retry or delete anyway.")
                        if let error = model.impactError {
                            ErrorBanner(error) { Task { await model.prepareDeletion() } }
                        }
                    }
                    .clearListRow()
                }
            } else if model.isCheckingImpact {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .clearListRow()
                }
            }
            if let error = model.deleteError {
                Section {
                    ErrorBanner(error) { isConfirming = true }
                        .clearListRow()
                }
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .floatingBar(edge: .bottom) {
            Button(role: .destructive) {
                isConfirming = true
            } label: {
                ZStack {
                    Text(zh ? "删除这个 Botin" : "Delete this Botin")
                        .opacity(model.isDeleting ? 0 : 1)
                    if model.isDeleting {
                        ProgressView()
                    }
                }
                .font(Font.headline)
                .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(.prominent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(StatusTone.failure.color)
            .disabled(model.isDeleting || model.isCheckingImpact || app.isOffline)
            .accessibilityLabel(
                Text(model.isDeleting ? (zh ? "正在删除" : "Deleting") : (zh ? "删除这个 Botin" : "Delete this Botin"))
            )
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(maxWidth: Metrics.readableWidth)
        }
        .inlineNavigationTitle(zh ? "删除这个 Botin" : "Delete this Botin")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { onClose() }
                    .disabled(model.isDeleting)
            }
        }
        .interactiveDismissDisabled(model.isDeleting)
        // 每次打开都重新查（计划、团队可能刚改过）；查的时候先显示上次的。
        .task { await model.prepareDeletion() }
        .confirmationDialog(
            zh ? "确定删除“\(name)”？" : "Delete “\(name)”?", isPresented: $isConfirming, titleVisibility: .visible
        ) {
            Button(zh ? "删除，不能恢复" : "Delete permanently", role: .destructive) {
                Task {
                    if await model.delete() { onClose() }
                }
            }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    /// 二次确认框里的一句话：有级联的再强调一遍。
    private var confirmationMessage: String {
        let zh = language == .chinese
        guard let impact = model.deletionImpact else {
            return zh ? "这个 Botin、它的计划和产出物都会删掉。" : "This Botin, its plans and its artifacts will be deleted."
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
            return zh ? "这个 Botin、它的计划和产出物都会删掉。" : "This Botin, its plans and its artifacts will be deleted."
        }
        return zh
            ? "会" + AgentsText.list(parts, language: language) + "。"
            : "This will " + AgentsText.list(parts, language: language) + "."
    }
}

/// 影响清单：分组列表的几组（放在 `List` 里；单独画时一组一组竖着排）。
struct InstanceDeletionImpactView: View {
    let impact: InstanceDeletionImpact

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        if impact.activeRuns > 0 {
            Section {
                ImpactRow(
                    systemImage: "stop.circle",
                    title: zh ? "\(impact.activeRuns) 个还没结束的任务" : "\(impact.activeRuns) unfinished task(s)",
                    detail: zh ? "正在跑的、排队的、等审批的都会取消。" : "Running, queued and waiting tasks are cancelled.",
                    detailTone: .waiting)
            } header: {
                Text(zh ? "会停掉" : "Will be stopped").groupHeader()
            }
            .themedRow()
        }

        Section {
            ForEach(impact.ownPlans) { plan in
                ImpactRow(
                    systemImage: "calendar", title: plan.title, detail: zh ? "这个 Botin 的计划" : "This Botin's plan",
                    showsAILabel: AgentsText.isAIGenerated(plan))
            }
            if let count = impact.artifactCount, count > 0 {
                // 只数到接口的上限，到了上限写“500+”。
                let countText = count >= InstanceDeletionImpact.artifactsToCheck ? "\(count)+" : "\(count)"
                ImpactRow(systemImage: "doc.on.doc", title: zh ? "\(countText) 个产出物" : "\(countText) artifact(s)")
            }
            ImpactRow(
                systemImage: "shippingbox",
                title: zh ? "沙箱、工作区和对话记录" : "The sandbox, its workspace and chat history",
                detail: zh ? "模型路由也会一起删掉；你的模型 key 不受影响。" : "Its model routes go too; your model keys stay.")
        } header: {
            Text(zh ? "会一起删掉" : "Will be deleted").groupHeader()
        }
        .themedRow()

        if !impact.pipelines.isEmpty {
            Section {
                ForEach(impact.pipelines) { pipeline in
                    InstancePipelineImpactRow(pipeline: pipeline)
                }
            } header: {
                Text(zh ? "这些流水线有步骤在它上面" : "Pipelines with steps on it").groupHeader()
            }
            .themedRow()
        }

        if !impact.teams.isEmpty {
            Section {
                ForEach(impact.teams) { team in
                    ImpactRow(
                        systemImage: "person.3", title: team.teamName, detail: teamDetail(team),
                        detailTone: team.isLead || team.remainingMembers == 0 ? .waiting : nil)
                }
            } header: {
                Text(zh ? "会从这些团队里移除" : "Will be removed from these teams").groupHeader()
            }
            .themedRow()
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

/// 影响清单的一行：图标、标题、灰字说明（警告的用警告色）、可选的 AI 生成标识和第二行说明。
private struct ImpactRow: View {
    let systemImage: String
    let title: String
    var detail: String?
    var detailTone: StatusTone?
    var showsAILabel = false
    var note: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                Text(title)
                    .foregroundStyle(Theme.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .typography(.subheadline)
                        .foregroundStyle(detailTone?.color ?? Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsAILabel { AIGeneratedLabel() }
                if let note {
                    Text(note)
                        .typography(.footnote)
                        .foregroundStyle(StatusTone.waiting.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一条流水线：在这个实例上的步骤，删除后流水线怎样（11.9：步骤留着，改到别的实例上之前恢复、确认都不行）。
private struct InstancePipelineImpactRow: View {
    let pipeline: InstanceDeletionImpact.PipelineImpact

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        let steps = AgentsText.list(pipeline.stepsOnInstance.map(\.key), language: language)
        ImpactRow(
            systemImage: pipeline.willPause ? "pause.circle" : "flowchart", title: pipeline.plan.title,
            detail: zh ? "在它上面的步骤：\(steps)" : "Steps on it: \(steps)",
            showsAILabel: AgentsText.isAIGenerated(pipeline.plan), note: pipeline.effect.message(language))
    }
}

#Preview("删除实例 · 浅色中文") {
    InstanceDeletePreview(instanceID: DemoData.reviewerID).previewShell(client: AgentsPreviewClients.withPipeline())
}

#Preview("删除实例 · 深色英文") {
    InstanceDeletePreview(instanceID: DemoData.writerID)
        .previewShell(.english, scheme: .dark, client: AgentsPreviewClients.withPipeline())
}
