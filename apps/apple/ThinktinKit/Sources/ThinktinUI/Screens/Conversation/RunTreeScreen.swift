import SwiftUI
import ThinktinKit

/// 运行树（`.runTree(id)`：流水线、委派的子运行）。参考里没有这一页，照第 2 节排成分组列表：深度优先排开、按层缩进，
/// 每个节点一行（状态点、标题——步骤名或任务的第一行，委派的任务带 AI 标识——、状态和所在的 Botin），打开时指定的那个行底高亮。
/// 点节点进运行详情（`NavigationLink`，系统画 chevron）。
///
/// 12.7 补上：没结束的节点右边有停止键，也能左滑、长按停止；右上“停止整棵树”（都先问一句）；子步骤在等你审批、等 key、
/// 等电脑时顶上一组提示，点了去它的运行详情；还有没结束的运行时每 5 秒刷新一次。
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
        List {
            if let error = model.error, !error.isOffline {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if let error = model.stopError {
                Section {
                    ErrorBanner(error, onDismiss: { model.clearStopError() })
                        .clearListRow()
                }
            }
            if let run = model.attention {
                Section {
                    NavigationLink(value: AppRoute.run(run.id)) {
                        Label {
                            Text(TeamsText.attention(run, language: language))
                                .typography(.subheadline)
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.bubble")
                                .foregroundStyle(StatusTone.waiting.color)
                        }
                    }
                }
                .themedRow()
            }
            if !model.nodes.isEmpty {
                Section {
                    ForEach(model.nodes) { node in
                        nodeRow(node, canStop: canStop)
                    }
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.isMissing {
                ContentUnavailableView(
                    ConversationText.runMissing(language), systemImage: "questionmark.square.dashed")
            } else if !model.hasLoaded {
                ConversationLoadingView()
            }
        }
        .inlineNavigationTitle(AppRoute.runTree(model.runID).title(language))
        .toolbar {
            if canStop {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    Button(role: .destructive) {
                        stopTarget = .tree
                    } label: {
                        Label(ConversationText.detailLabel(.stopTree, language: language), systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
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

    /// 一个节点：`NavigationLink` 进运行详情，没结束的右边停止键（也能左滑、长按停止）；打开时指定的那个行底高亮。
    private func nodeRow(_ node: RunTreeNode, canStop: Bool) -> some View {
        let zh = language == .chinese
        let canStopNode = canStop && node.run.state.isActive && !app.isOffline
        return NavigationLink(value: AppRoute.run(node.id)) {
            HStack(spacing: Metrics.Spacing.xs) {
                RunTreeRow(node: node, instanceName: app.instances.first { $0.id == node.run.instanceID }?.name)
                if canStop { stopButton(node) }
            }
        }
        .listRowBackground(node.isFocus ? Theme.userBubble : Theme.paperElevated)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canStopNode {
                // 只弹确认、停了行也还在：不用 `.destructive`，不然系统先把行收走。
                Button {
                    stopTarget = .node(node.id)
                } label: {
                    Label(ConversationText.detailLabel(.stop, language: language), systemImage: "stop.fill")
                }
                .tint(StatusTone.failure.color)
            }
        }
        .contextMenu {
            Button {
                router.open(.run(node.id))
            } label: {
                Label(AppRoute.run(node.id).title(language), systemImage: "list.bullet.rectangle")
            }
            if canStopNode {
                Button(role: .destructive) {
                    stopTarget = .node(node.id)
                } label: {
                    Label(zh ? "停止“\(node.title)”" : "Stop “\(node.title)”", systemImage: "stop.fill")
                }
            }
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
                .controlSize(.small)
        } else if node.run.state.isActive {
            Button {
                stopTarget = .node(node.id)
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(StatusTone.failure.color)
            }
            .buttonStyle(.borderless)
            .disabled(app.isOffline)
            .accessibilityLabel(Text(zh ? "停止“\(node.title)”" : "Stop “\(node.title)”"))
        }
    }
}

/// 运行树的一个节点（行的内容）：状态点、标题、状态 · Botin · 子运行数、AI 标识；按层缩进。
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
        }
        .padding(.vertical, Metrics.Spacing.xxs)
        .padding(.leading, CGFloat(min(node.depth, 6)) * Metrics.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(node.isFocus ? .isSelected : [])
    }
}

/// 进行中（`.activeRuns`，深链、小组件进来）。参考里没有这一页，照第 2 节排成分组列表：跨 Botin、还没结束的运行，
/// “等你处理”一组在前，其余一组；一行是 Botin 头像（带运行状态角标）、任务（两行）、状态 · Botin · 时间、AI 标识，
/// `NavigationLink` 进运行详情。还有更多时最后一行“加载更多”。没有时 `ContentUnavailableView`。
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
        List {
            if let error = model.error, !error.isOffline {
                Section {
                    ErrorBanner(error) { Task { await model.load() } }
                        .clearListRow()
                }
            }
            if !model.waiting.isEmpty {
                Section {
                    ForEach(model.waiting) { run in row(run) }
                } header: {
                    Text(ConversationText.needsYou(language)).groupHeader()
                }
                .themedRow()
            }
            if !model.others.isEmpty {
                Section {
                    ForEach(model.others) { run in row(run) }
                } header: {
                    Text(AppRoute.activeRuns.title(language)).groupHeader()
                }
                .themedRow()
            }
            if model.hasMore {
                Section {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        HStack(spacing: Metrics.Spacing.xs) {
                            if model.isLoadingMore { ProgressView().controlSize(.small) }
                            Text(ConversationText.loadMore(language))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isLoadingMore)
                }
                .themedRow()
            }
        }
        .insetGroupedList()
        .compactGroupedList()
        .themedGroupedBackground()
        .overlay {
            if model.hasLoaded && model.runs.isEmpty {
                ContentUnavailableView(
                    ConversationText.activeRunsEmpty(language), systemImage: "checkmark.circle",
                    description: Text(ConversationText.activeRunsEmptyMessage(language)))
            } else if !model.hasLoaded {
                ConversationLoadingView()
            }
        }
        .inlineNavigationTitle(AppRoute.activeRuns.title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private func row(_ run: Run) -> some View {
        let instance = app.instances.first { $0.id == run.instanceID }
        return NavigationLink(value: AppRoute.run(run.id)) {
            // 头像用规范 2.4 的尺寸（搜索结果、选择器那一档 40pt），和首页、搜索里同一个 Botin 看着一样大（以前是 32）。
            HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                if let instance {
                    InstanceAvatar(
                        instance.name, appearance: app.appearances.resolved(for: instance.id),
                        size: Metrics.Avatar.search, badge: .run(run.state)
                    )
                    .accessibilityHidden(true)
                } else {
                    StatusDot(run.state)
                        .frame(width: Metrics.Avatar.search, height: Metrics.Avatar.search)
                }
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(verbatim: MessageQuote.body(run.prompt))
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(
                        verbatim: [
                            run.state.localizedName(language), instance?.name,
                            Formatting.relativeTime(run.createdAt, language: language),
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    if AIGeneratedField.prompt(of: run).isAIGenerated { AIGeneratedLabel() }
                }
            }
            .padding(.vertical, Metrics.Spacing.unit / 2)
            .accessibilityElement(children: .combine)
        }
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
