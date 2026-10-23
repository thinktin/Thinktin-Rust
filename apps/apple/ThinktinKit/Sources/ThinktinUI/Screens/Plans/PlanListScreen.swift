import SwiftUI
import ThinktinKit

/// 计划列表（`.plans`，抽屉里的“计划”）：
///
/// - 顶上一排筛选（全部、各个实例，流水线有一步在这个实例上的也算）；
/// - agent 建的、改的等确认的置顶，带角标，卡片上直接“查看并确认”或删除（等确认的不能直接恢复）；
/// - 其余分“按时运行”（下一次触发早的在前，规则失效的标红）和“已暂停”两组，每行的“更多”里暂停 / 恢复、删除；
/// - 右上角新建计划（预选当前筛选的实例）。
///
/// 离线策略是“没有缓存”：离线时显示已经拉到的，没有就是空状态；写操作都禁用。
struct PlanListScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        PlanListContent(client: client)
    }
}

private struct PlanListContent: View {
    @State private var model: PlanListModel
    /// 等二次确认要删的计划。
    @State private var pendingDeletion: Plan?
    @State private var isConfirmingDeletion = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: PlanListModel(client: client))
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let sections = model.sections
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                AgentsPageHeader(
                    title: AppRoute.plans.title(language),
                    message: zh
                        ? "让 agent 按时干活。agent 自己安排的计划要你确认后才会运行。"
                        : "Have agents work on a schedule. Plans an agent sets up run only after you confirm them.")
                if !model.plans.isEmpty { filterBar }
                if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let error = model.actionError {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                }
                if !sections.awaiting.isEmpty { awaitingSection(sections.awaiting) }
                if !sections.active.isEmpty {
                    planSection(title: zh ? "按时运行" : "Active", plans: sections.active)
                }
                if !sections.paused.isEmpty {
                    planSection(title: zh ? "已暂停" : "Paused", plans: sections.paused)
                }
                if sections.isEmpty { emptyState }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.plans.title(language))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.open(.newPlan(instanceID: model.instanceFilter ?? app.currentInstance?.id))
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(app.isOffline || app.instances.isEmpty)
                .accessibilityLabel(Text(AppRoute.newPlan(instanceID: nil).title(language)))
            }
        }
        .refreshable { await model.load() }
        // 每次回到这一页（从详情、确认页回来，新建的 sheet 关掉）都重新拉：别处可能改过。
        .task { await model.load() }
        .onChange(of: router.sheet) {
            if router.sheet == nil { Task { await model.load() } }
        }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
        .confirmationDialog(
            zh ? "删除“\(pendingDeletion?.title ?? "")”？" : "Delete “\(pendingDeletion?.title ?? "")”?",
            isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let plan = pendingDeletion {
                    Task {
                        if await model.delete(plan.id) { await app.refreshBadges() }
                    }
                }
            } label: {
                Text(zh ? "删除计划" : "Delete plan")
            }
            Button(role: .cancel) {
                pendingDeletion = nil
            } label: {
                Text(zh ? "取消" : "Cancel")
            }
        } message: {
            Text(
                zh
                    ? "删除后不再运行，运行授权一起吊销。已经跑过的运行记录还在。"
                    : "It stops running and its run grant is revoked. Past runs stay in history.")
        }
    }

    /// 离线时不能改。
    private var canWrite: Bool { !app.isOffline }

    // MARK: 筛选

    private var filterBar: some View {
        let zh = language == .chinese
        let ids = model.filterInstances(app.instances)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.Spacing.xs) {
                PlansFilterChip(
                    title: zh ? "全部" : "All", count: model.count(for: nil), isSelected: model.instanceFilter == nil
                ) {
                    model.instanceFilter = nil
                }
                ForEach(ids, id: \.self) { id in
                    PlansFilterChip(
                        title: instanceName(id), count: model.count(for: id), isSelected: model.instanceFilter == id
                    ) {
                        model.instanceFilter = id
                    }
                }
            }
            .padding(.horizontal, Metrics.Spacing.xxs)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(zh ? "按实例筛选" : "Filter by instance"))
    }

    private func instanceName(_ id: InstanceID) -> String {
        app.instances.first { $0.id == id }?.name ?? (language == .chinese ? "已删除的实例" : "Deleted instance")
    }

    // MARK: 分组

    private func awaitingSection(_ plans: [Plan]) -> some View {
        let zh = language == .chinese
        return VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            HStack(spacing: Metrics.Spacing.xs) {
                AgentsSectionHeader(title: zh ? "待确认" : "Needs review")
                PlansCountBadge(count: plans.count)
                    .padding(.top, Metrics.Spacing.s)
            }
            ForEach(plans) { plan in
                PlanAwaitingCard(
                    plan: plan, instanceName: instanceName(plan.instanceID),
                    isBusy: model.busyPlanIDs.contains(plan.id), canWrite: canWrite,
                    onReview: { router.open(.confirmPlan(plan.id)) },
                    onDelete: {
                        pendingDeletion = plan
                        isConfirmingDeletion = true
                    })
            }
        }
    }

    private func planSection(title: String, plans: [Plan]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            AgentsSectionHeader(title: title)
            AgentsGroup {
                ForEach(plans) { plan in
                    if plan.id != plans.first?.id { Divider() }
                    PlanListRow(
                        plan: plan, instanceName: instanceName(plan.instanceID),
                        isBusy: model.busyPlanIDs.contains(plan.id), canWrite: canWrite,
                        onOpen: { router.open(.plan(plan.id)) },
                        onSetPaused: { paused in
                            Task { await model.setPaused(plan.id, paused: paused) }
                        },
                        onDelete: {
                            pendingDeletion = plan
                            isConfirmingDeletion = true
                        })
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let zh = language == .chinese
        if !model.hasLoaded && model.isLoading {
            AgentsLoadingView()
        } else if model.plans.isEmpty && model.error != nil {
            EmptyStateView(
                systemImage: model.error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle",
                title: zh ? "暂时拉不到计划" : "Couldn't load plans",
                message: model.error?.isOffline == true
                    ? (zh ? "联网后会自动刷新。" : "It refreshes once you're back online.") : nil)
        } else if model.instanceFilter != nil && !model.plans.isEmpty {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: zh ? "这个实例还没有计划" : "No plans for this instance",
                message: PlansText.emptyMessage(language), actionTitle: zh ? "看全部" : "Show all"
            ) {
                model.instanceFilter = nil
            }
        } else if model.hasLoaded {
            EmptyStateView(
                systemImage: "calendar.badge.clock", title: zh ? "还没有计划" : "No plans yet",
                message: PlansText.emptyMessage(language),
                actionTitle: app.instances.isEmpty || !canWrite
                    ? nil : AppRoute.newPlan(instanceID: nil).title(language)
            ) {
                router.open(.newPlan(instanceID: app.currentInstance?.id))
            }
        }
    }
}

/// 等确认的计划：标题（AI 生成标识）、实例、规则、一句说明，“查看并确认”和“删除”。
struct PlanAwaitingCard: View {
    let plan: Plan
    let instanceName: String
    let isBusy: Bool
    let canWrite: Bool
    let onReview: @MainActor () -> Void
    let onDelete: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let zh = language == .chinese
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            PlanTitleText(plan: plan)
            Text(instanceName + " · " + PlansText.scheduleSummary(plan, language: language))
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                plan.createdBy == .agent
                    ? (zh ? "agent 安排的计划，确认后才会运行。" : "An agent set this up. It runs only after you confirm.")
                    : (zh
                        ? "agent 改了这个计划，确认后才按新的内容运行。"
                        : "An agent changed this plan. It runs again only after you confirm.")
            )
            .typography(.footnote)
            .foregroundStyle(StatusTone.waiting.color)
            .fixedSize(horizontal: false, vertical: true)
            PlansButtonRow {
                PillButton(zh ? "查看并确认" : "Review", systemImage: "checkmark.seal", size: .compact, action: onReview)
                PillButton(zh ? "删除" : "Delete", kind: .secondary, size: .compact, action: onDelete)
                    .disabled(!canWrite || isBusy)
                if isBusy { ProgressView() }
            }
            .padding(.top, Metrics.Spacing.xxs)
        }
        .padding(Metrics.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paperElevated, in: shape)
        .overlay {
            shape.strokeBorder(StatusTone.waiting.color.opacity(0.5), lineWidth: Metrics.hairline(scale: displayScale))
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("计划列表 · 浅色中文") {
    PlanListScreen().previewShell(client: PlansPreviewClients.withPlans())
}

#Preview("计划列表 · 深色英文") {
    PlanListScreen().previewShell(.english, scheme: .dark, client: PlansPreviewClients.withPlans())
}

#Preview("计划列表 · 没有计划") {
    PlanListScreen().previewShell(client: PlansPreviewClients.empty())
}

#Preview("计划列表 · 没有计划 · 深色英文") {
    PlanListScreen().previewShell(.english, scheme: .dark, client: PlansPreviewClients.empty())
}
