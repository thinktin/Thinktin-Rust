import SwiftUI
import ThinktinKit

/// 计划列表（`.plans(instanceID:)`，规范 4.5.1，参考 21）：工作台菜单的“计划”是全部的，Botin 资料的“计划”只看那个 Botin 的。
///
/// - 压栈页，inline 标题“计划”；insetGrouped 列表（`List`），右上玻璃“+”新建（预选这个 Botin 或当前的 Botin）。
/// - 全部的页面顶上一排按 Botin 筛选的胶囊（`FilterChipBar`，作为列表第一行，跟着内容滚）；只看一个 Botin 的页面不显示。
/// - Botin 建的、改的等确认的一组放最上面（点了进确认页），其余分“按时运行”“已暂停”两组；点一行进计划详情。
///   左滑：暂停 / 恢复、删除（二次确认）；长按是同样的系统菜单。
/// - 没有计划时屏幕正中一段说明（参考 21 只有这段字），ThinkTin 能手动新建，所以多一个“新建计划”。
///
/// 离线策略是“没有缓存”：离线时显示已经拉到的，没有就是空状态；写操作都禁用。
struct PlanListScreen: View {
    /// 只看这个 Botin 的计划（nil 是全部）。
    var instanceFilter: InstanceID?

    @Environment(\.client) private var client

    var body: some View {
        PlanListContent(client: client, instanceFilter: instanceFilter)
    }
}

private struct PlanListContent: View {
    @State private var model: PlanListModel
    /// 等二次确认要删的计划。
    @State private var pendingDeletion: Plan?
    @State private var isConfirmingDeletion = false
    /// 这一页的路由（回到最前面时刷新用）。
    private let route: AppRoute

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, instanceFilter: InstanceID?) {
        _model = State(initialValue: PlanListModel(client: client, instanceFilter: instanceFilter))
        route = .plans(instanceID: instanceFilter)
    }

    var body: some View {
        let zh = language == .chinese
        let model = self.model
        let sections = model.sections
        List {
            if model.showsInstanceFilter {
                Section {
                    filterBar
                        .clearListRow()
                }
            }
            if let error = visibleError(model.error) {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let error = model.actionError {
                Section {
                    ErrorBanner(error, onDismiss: { model.clearActionError() })
                        .clearListRow()
                }
            }
            if !sections.awaiting.isEmpty {
                Section {
                    rows(sections.awaiting, awaiting: true)
                } header: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(zh ? "待确认" : "Needs review")
                        PlansCountBadge(count: sections.awaiting.count)
                    }
                    .textCase(nil)
                } footer: {
                    Text(PlansText.awaitingFooter(language))
                }
                .themedRow()
            }
            if !sections.active.isEmpty {
                Section {
                    rows(sections.active, awaiting: false)
                } header: {
                    Text(zh ? "按时运行" : "Active").textCase(nil)
                }
                .themedRow()
            }
            if !sections.paused.isEmpty {
                Section {
                    rows(sections.paused, awaiting: false)
                } header: {
                    Text(zh ? "已暂停" : "Paused").textCase(nil)
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay { placeholder }
        .inlineNavigationTitle(route.title(language))
        .toolbar {
            ToolbarItem(placement: ToolbarSlot.trailing) {
                Button {
                    router.open(
                        .newPlan(instanceID: model.scopeInstanceID ?? model.instanceFilter ?? app.currentInstance?.id))
                } label: {
                    Label(AppRoute.newPlan(instanceID: nil).title(language), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canCreate)
            }
        }
        .refreshable { await model.load() }
        // 每次回到这一页（从详情、确认页回来，新建的 sheet 关掉）都重新拉：别处可能改过。
        .task { await model.load() }
        .onChange(of: router.visibleRoute) {
            if router.visibleRoute == route { Task { await model.load() } }
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

    /// 能新建：联网、账号里有 Botin。
    private var canCreate: Bool { canWrite && !app.instances.isEmpty }

    // MARK: 筛选

    private var filterBar: some View {
        @Bindable var model = model
        let zh = language == .chinese
        let options: [FilterChipBar<InstanceID?>.Option] =
            [.init(value: nil, title: zh ? "全部" : "All", count: model.count(for: nil))]
            + model.filterInstances(app.instances).map {
                .init(value: $0, title: instanceName($0), count: model.count(for: $0))
            }
        return FilterChipBar(options, selection: $model.instanceFilter, horizontalInset: 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(zh ? "按 Botin 筛选" : "Filter by Botin"))
    }

    private func instanceName(_ id: InstanceID) -> String {
        app.instances.first { $0.id == id }?.name ?? (language == .chinese ? "已删除的 Botin" : "Deleted Botin")
    }

    // MARK: 行

    private func rows(_ plans: [Plan], awaiting: Bool) -> some View {
        ForEach(plans) { plan in
            NavigationLink(value: awaiting ? AppRoute.confirmPlan(plan.id) : AppRoute.plan(plan.id)) {
                PlanRow(
                    plan: plan, instanceName: model.scopeInstanceID == nil ? instanceName(plan.instanceID) : nil,
                    isBusy: model.busyPlanIDs.contains(plan.id))
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 只弹确认、不直接删：`.destructive` 的左滑按钮系统会先把行收走，取消后又跳回来。
                Button {
                    confirmDeletion(plan)
                } label: {
                    Label(language == .chinese ? "删除" : "Delete", systemImage: "trash")
                }
                .tint(StatusTone.failure.color)
                .disabled(!canWrite)
                if let paused = pauseTarget(plan) {
                    Button {
                        setPaused(plan, paused)
                    } label: {
                        pauseLabel(paused)
                    }
                    .tint(paused ? StatusTone.muted.color : Theme.accent)
                    .disabled(!canWrite)
                }
            }
            .contextMenu {
                Section {
                    Button {
                        router.open(awaiting ? .confirmPlan(plan.id) : .plan(plan.id))
                    } label: {
                        Label(
                            awaiting
                                ? (language == .chinese ? "查看并确认" : "Review")
                                : (language == .chinese ? "打开" : "Open"),
                            systemImage: awaiting ? "checkmark.seal" : "doc.text")
                    }
                    if let paused = pauseTarget(plan) {
                        Button {
                            setPaused(plan, paused)
                        } label: {
                            pauseLabel(paused)
                        }
                        .disabled(!canWrite)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmDeletion(plan)
                    } label: {
                        Label(language == .chinese ? "删除" : "Delete", systemImage: "trash")
                    }
                    .disabled(!canWrite)
                }
            }
        }
    }

    /// 能暂停就是 true、能恢复就是 false；等确认的不能直接恢复也不用暂停（要去确认页），为 nil。
    private func pauseTarget(_ plan: Plan) -> Bool? {
        guard !plan.awaitingConfirmation else { return nil }
        return !plan.isPaused
    }

    private func pauseLabel(_ paused: Bool) -> some View {
        let zh = language == .chinese
        return paused
            ? Label(zh ? "暂停" : "Pause", systemImage: "pause") : Label(zh ? "恢复" : "Resume", systemImage: "play")
    }

    private func setPaused(_ plan: Plan, _ paused: Bool) {
        let model = self.model
        Task { await model.setPaused(plan.id, paused: paused) }
    }

    private func confirmDeletion(_ plan: Plan) {
        pendingDeletion = plan
        isConfirmingDeletion = true
    }

    // MARK: 空状态

    @ViewBuilder
    private var placeholder: some View {
        let zh = language == .chinese
        switch model.placeholder {
        case .loading:
            ProgressView()
        case .unavailable(let offline):
            ContentUnavailableView {
                Label(
                    zh ? "暂时拉不到计划" : "Couldn't load plans",
                    systemImage: offline ? "wifi.slash" : "exclamationmark.triangle")
            } description: {
                if offline { Text(zh ? "联网后会自动刷新。" : "It refreshes once you're back online.") }
            } actions: {
                Button(zh ? "重试" : "Try again") { Task { await model.load() } }
                    .glassButtonStyle()
            }
        case .noneForFilter:
            ContentUnavailableView {
                Label(zh ? "这个 Botin 还没有计划" : "No plans for this Botin", systemImage: "clock")
            } description: {
                Text(PlansText.listEmptyMessage(language))
            } actions: {
                Button(zh ? "看全部" : "Show all") { model.instanceFilter = nil }
                    .glassButtonStyle()
            }
        case .empty:
            // 参考 21：正中一段说明，没有图标和标题。
            ContentUnavailableView {
                EmptyView()
            } description: {
                Text(PlansText.listEmptyMessage(language))
            } actions: {
                if canCreate {
                    Button(AppRoute.newPlan(instanceID: nil).title(language)) {
                        router.open(.newPlan(instanceID: model.scopeInstanceID ?? app.currentInstance?.id))
                    }
                    .glassButtonStyle(.prominent)
                }
            }
        case nil:
            EmptyView()
        }
    }
}

/// 计划列表的一行（规范 4.5.1）：左边状态图标，标题（单行，Botin 写的带 AI 生成标识），灰色副标题（规则摘要，全部的页面带
/// Botin 名），一行状态（待确认 / 下一次 / 暂停 / 规则失效）。正在暂停、删除时右边转圈。
struct PlanRow: View {
    let plan: Plan
    /// 全部计划的页面显示 Botin 名；只看一个 Botin 的为 nil。
    let instanceName: String?
    var isBusy = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let status = plan.status
        HStack(spacing: Metrics.Spacing.s) {
            Image(systemName: status.systemImage)
                .font(Typography.title3.font)
                .foregroundStyle(status.tone.color)
                .frame(width: Metrics.Spacing.xl)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(plan.title)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(PlansText.rowSubtitle(plan, instanceName: instanceName, language: language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                PlanMetaLine(plan: plan, instanceName: nil)
                if PlansText.isAIGenerated(.title, in: plan) { AIGeneratedLabel() }
            }
            Spacer(minLength: 0)
            if isBusy { ProgressView() }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

#Preview("计划列表 · 浅色中文") {
    PlanListScreen().previewShell(client: PlansPreviewClients.withPlans())
}

#Preview("计划列表 · 深色英文") {
    PlanListScreen().previewShell(.english, scheme: .dark, client: PlansPreviewClients.withPlans())
}

#Preview("一个 Botin 的计划") {
    PlanListScreen(instanceFilter: DemoData.writerID).previewShell(client: PlansPreviewClients.withPlans())
}

#Preview("计划列表 · 没有计划") {
    PlanListScreen().previewShell(client: PlansPreviewClients.empty())
}

#Preview("计划列表 · 没有计划 · 深色英文") {
    PlanListScreen().previewShell(.english, scheme: .dark, client: PlansPreviewClients.empty())
}
