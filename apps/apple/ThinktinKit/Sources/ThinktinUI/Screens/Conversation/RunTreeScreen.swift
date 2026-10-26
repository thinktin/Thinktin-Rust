import SwiftUI
import ThinktinKit

/// 运行树（`.runTree(id)`：流水线、委派的子运行）：深度优先排开、按层缩进，每个节点是状态点、标题（步骤名或任务的第一行，
/// 委派的任务带 AI 标识）、所在的实例；打开时指定的那个高亮。点节点进运行详情。
///
/// 12.7 补上：没结束的节点右边有停止键，右上角“停止整棵树”（都先问一句）；子步骤在等你审批、等 key、等电脑时顶上冒一条，
/// 点了去它的运行详情；还有没结束的运行时每 5 秒刷新一次。
struct RunTreeScreen: View {
    let runID: RunID

    @Environment(\.client) private var client

    var body: some View {
        RunTreeContent(client: client, runID: runID)
    }
}

private struct RunTreeContent: View {
    /// 要停的：一个节点，或者整棵树。
    private enum StopTarget: Hashable {
        case node(RunID)
        case tree
    }

    @State private var model: RunTreeModel
    @State private var stopTarget: StopTarget?

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, runID: RunID) {
        _model = State(initialValue: RunTreeModel(client: client, runID: runID))
    }

    var body: some View {
        let model = self.model
        let canStop = model.hasActiveRuns
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                if let error = model.error, !error.isOffline {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let error = model.stopError {
                    ErrorBanner(error, onDismiss: { model.clearStopError() })
                }
                if let run = model.attention {
                    attentionBanner(run)
                }
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.square.dashed", title: ConversationText.runMissing(language))
                } else if !model.hasLoaded {
                    ConversationLoadingView()
                }
                ForEach(model.nodes) { node in
                    HStack(spacing: Metrics.Spacing.xxs) {
                        Button {
                            router.open(.run(node.id))
                        } label: {
                            RunTreeRow(
                                node: node, instanceName: app.instances.first { $0.id == node.run.instanceID }?.name)
                        }
                        .buttonStyle(.plain)
                        if canStop { stopButton(node) }
                    }
                }
            }
            .padding(Metrics.Spacing.m)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .navigationTitle(AppRoute.runTree(model.runID).title(language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if canStop {
                    Button(role: .destructive) {
                        stopTarget = .tree
                    } label: {
                        Label(ConversationText.detailLabel(.stopTree, language: language), systemImage: "stop.circle")
                    }
                    .disabled(app.isOffline || !model.stopping.isEmpty)
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .task(id: canStop) { await model.refreshWhileActive() }
        .confirmationDialog(
            stopTitle, isPresented: Binding(get: { stopTarget != nil }, set: { if !$0 { stopTarget = nil } }),
            titleVisibility: .visible, presenting: stopTarget
        ) { target in
            Button(stopTitle, role: .destructive) {
                Task {
                    switch target {
                    case .node(let id): await model.stop(id)
                    case .tree: await model.stopTree()
                    }
                }
            }
            Button(language == .chinese ? "取消" : "Cancel", role: .cancel) {}
        } message: { target in
            Text(
                target == .tree
                    ? (language == .chinese
                        ? "整棵树的运行（流水线步骤、委派）都会停下。" : "Every run in this tree (pipeline steps, delegations) will stop.")
                    : (language == .chinese ? "停下这个运行，已经做完的不会撤销。" : "Stops this run. Work already done is kept."))
        }
    }

    private var stopTitle: String {
        stopTarget == .tree
            ? ConversationText.detailLabel(.stopTree, language: language)
            : ConversationText.detailLabel(.stop, language: language)
    }

    /// 节点右边的停止键；已经结束的留空，好让各行对齐。
    @ViewBuilder
    private func stopButton(_ node: RunTreeNode) -> some View {
        let zh = language == .chinese
        if model.stopping.contains(node.id) {
            ProgressView()
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
        } else if node.run.state.isActive {
            Button {
                stopTarget = .node(node.id)
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(StatusTone.failure.color)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(app.isOffline)
            .accessibilityLabel(Text(zh ? "停止“\(node.title)”" : "Stop “\(node.title)”"))
        } else {
            Color.clear
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                .accessibilityHidden(true)
        }
    }

    /// 子步骤在等你：点了去它的运行详情处理。
    private func attentionBanner(_ run: Run) -> some View {
        Button {
            router.open(.run(run.id))
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(StatusTone.waiting.color)
                    .accessibilityHidden(true)
                Text(TeamsText.attention(run, language: language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(Metrics.Spacing.s)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
            .background(
                Theme.paperElevated, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 运行树的一个节点。
struct RunTreeRow: View {
    let node: RunTreeNode
    let instanceName: String?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            StatusDot(node.run.state)
            VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                Text(verbatim: node.title.isEmpty ? AppRoute.run(node.id).title(language) : node.title)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Metrics.Spacing.xs) {
                    Text(node.run.state.localizedName(language))
                    if let instanceName { Text(verbatim: instanceName) }
                    if node.childCount > 0 {
                        Text(language == .chinese ? "\(node.childCount) 个子运行" : "\(node.childCount) sub-runs")
                    }
                }
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
                if node.titleIsAIGenerated { AIGeneratedLabel() }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(Metrics.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            node.isFocus ? Theme.userBubble : Theme.paperElevated,
            in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        )
        .padding(.leading, CGFloat(min(node.depth, 6)) * Metrics.Spacing.l)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(node.isFocus ? .isSelected : [])
    }
}

/// 进行中（`.activeRuns`）：跨实例、还没结束的运行，等你处理的在前。点开进运行详情。
struct ActiveRunsScreen: View {
    @Environment(\.client) private var client

    var body: some View {
        ActiveRunsContent(client: client)
    }
}

private struct ActiveRunsContent: View {
    @State private var model: ActiveRunsModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol) {
        _model = State(initialValue: ActiveRunsModel(client: client))
    }

    var body: some View {
        let model = self.model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if let error = model.error, !error.isOffline {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if model.hasLoaded && model.runs.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.circle", title: ConversationText.activeRunsEmpty(language),
                        message: ConversationText.activeRunsEmptyMessage(language))
                } else if !model.hasLoaded {
                    ConversationLoadingView()
                }
                if !model.waiting.isEmpty {
                    sectionHeader(ConversationText.needsYou(language))
                    ForEach(model.waiting) { run in row(run) }
                }
                if !model.others.isEmpty {
                    sectionHeader(AppRoute.activeRuns.title(language))
                    ForEach(model.others) { run in row(run) }
                }
                if model.hasMore {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        HStack(spacing: Metrics.Spacing.xs) {
                            if model.isLoadingMore { ProgressView().controlSize(.small) }
                            Text(ConversationText.loadMore(language))
                        }
                        .typography(.footnote)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoadingMore)
                }
            }
            .padding(Metrics.Spacing.m)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .navigationTitle(AppRoute.activeRuns.title(language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .typography(.title3)
            .foregroundStyle(Theme.ink)
            .padding(.top, Metrics.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ run: Run) -> some View {
        Button {
            router.open(.run(run.id))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                StatusDot(run.state)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: run.prompt)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: Metrics.Spacing.xs) {
                        Text(run.state.localizedName(language))
                        if let name = app.instances.first(where: { $0.id == run.instanceID })?.name {
                            Text(verbatim: name)
                        }
                        Text(Formatting.relativeTime(run.createdAt, language: language))
                    }
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    if AIGeneratedField.prompt(of: run).isAIGenerated { AIGeneratedLabel() }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(Metrics.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// 首页（`.home`：还没有实例、或者还没选中实例时导航栈的根）：衬线的问候语，去 agent 目录领养（12.17 再做完整的引导）。
struct ConversationHomeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.Spacing.l) {
                Text(Greeting.text(name: app.user?.nameForDisplay, language: language))
                    .typography(.largeTitle)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, Metrics.Spacing.xxxl)
                    .accessibilityAddTraits(.isHeader)
                EmptyStateView(
                    systemImage: "square.stack.3d.up", title: ConversationText.homeTitle(language),
                    message: ConversationText.homeMessage(language),
                    actionTitle: ConversationText.browseCatalog(language)
                ) {
                    router.open(.agentCatalog)
                }
            }
            .padding(Metrics.Spacing.m)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }
}

#Preview("运行树 · 浅色中文") {
    RunTreeScreen(runID: ConversationPreviewClients.childRunID)
        .previewShell(client: ConversationPreviewClients.delegated())
}

#Preview("运行树 · 深色英文") {
    RunTreeScreen(runID: DemoData.publishRunID)
        .previewShell(.english, scheme: .dark, client: ConversationPreviewClients.delegated())
}

#Preview("进行中 · 浅色中文") {
    ActiveRunsScreen().previewShell()
}

#Preview("进行中 · 深色英文") {
    ActiveRunsScreen().previewShell(.english, scheme: .dark)
}

#Preview("首页 · 浅色中文") {
    ConversationHomeScreen().previewShell(client: ShellPreviewClients.empty())
}

#Preview("首页 · 深色英文") {
    ConversationHomeScreen().previewShell(.english, scheme: .dark, client: ShellPreviewClients.empty())
}
