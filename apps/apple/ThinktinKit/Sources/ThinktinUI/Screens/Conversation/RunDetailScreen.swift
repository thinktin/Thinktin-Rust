import SwiftUI
import ThinktinKit

/// 运行详情（`.run(id)`：状态行、收件箱、推送、计划的运行历史进来；对应 Claude Code 的会话详情）：
///
/// - 状态和说明（等待类给一键跳转）、任务（委派、流水线的带 AI 标识）、来源、所属计划、尝试次数、已用 token、时间；
/// - 等审批时，待处理的审批卡片直接放在状态下面（在这里就能批，“去审批”滚到它）；
/// - 摘要（Markdown，AI 生成标识）、失败原因（正文只说失败，英文诊断折起来）、最近一轮用量；
/// - 只看本次过程（同一个视图模型的时间线）、运行树（有子运行时）、产出物、打开对话、停止 / 停止整棵树、举报。
///
/// 状态跟着事件流变（`RunDetailModel.process` 订阅着实例的事件流），进后台停订阅、回前台续订。
struct RunDetailScreen: View {
    let runID: RunID

    @Environment(\.client) private var client
    @Environment(\.biometricGate) private var gate
    @Environment(AppModel.self) private var app

    var body: some View {
        RunDetailContent(
            client: client, runID: runID, instanceHints: app.instances.map(\.id),
            gate: ConversationGate.resolve(gate, client: client))
    }
}

private struct RunDetailContent: View {
    @State private var model: RunDetailModel
    @State private var isConfirmingStop = false
    @State private var stopsWholeTree = false
    @State private var reportRequest: ReportRequest?
    @State private var showsError = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.client) private var client
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayLanguage) private var language

    init(client: any ClientProtocol, runID: RunID, instanceHints: [InstanceID], gate: any BiometricGate) {
        _model = State(
            initialValue: RunDetailModel(
                client: client, runID: runID, instanceHints: instanceHints, biometricGate: gate))
    }

    var body: some View {
        let model = self.model
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Spacing.m) {
                    if let error = model.error, !error.isOffline {
                        ErrorBanner(error) { Task { await model.load() } }
                    }
                    if let run = model.run, !model.isMissing {
                        content(run, proxy: proxy)
                    } else if model.isMissing {
                        EmptyStateView(
                            systemImage: "questionmark.square.dashed", title: ConversationText.runMissing(language),
                            actionTitle: language == .chinese ? "返回" : "Go back"
                        ) {
                            router.pop()
                        }
                    } else {
                        ConversationLoadingView()
                    }
                }
                .padding(Metrics.Spacing.m)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
                .conversationLinkHandling(router)
            }
        }
        .background(Theme.paper)
        .navigationTitle(AppRoute.run(model.runID).title(language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.run != nil {
                    Menu {
                        Button(role: .destructive) {
                            reportRequest = ReportRequest(target: .run(model.runID))
                        } label: {
                            Label(ConversationText.report(language), systemImage: "flag")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel(Text(language == .chinese ? "更多操作" : "More"))
                    }
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background: model.process?.pause()
            case .active: Task { await model.process?.resume() }
            default: break
            }
        }
        .onChange(of: app.resubscribeRequest) { model.process?.resubscribe() }
        .confirmationDialog(
            stopsWholeTree
                ? ConversationText.detailLabel(.stopTree, language: language)
                : ConversationText.detailLabel(.stop, language: language),
            isPresented: $isConfirmingStop, titleVisibility: .visible
        ) {
            Button(
                stopsWholeTree
                    ? ConversationText.detailLabel(.stopTree, language: language)
                    : ConversationText.detailLabel(.stop, language: language), role: .destructive
            ) {
                Task { await model.stop(wholeTree: stopsWholeTree) }
            }
            Button(language == .chinese ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(
                stopsWholeTree
                    ? (language == .chinese
                        ? "这个运行和它的子运行（流水线步骤、委派）都会停下。" : "This run and all its sub-runs will stop.")
                    : (language == .chinese ? "停下这个运行，已经做完的不会撤销。" : "Stops this run. Work already done is kept."))
        }
        .sheet(item: $reportRequest) { request in
            ContentReportSheet(client: client, target: request.target)
        }
    }

    @ViewBuilder
    private func content(_ run: Run, proxy: ScrollViewProxy) -> some View {
        let model = self.model
        let pending = model.pendingApprovalItems
        if let line = model.statusLine {
            RunStatusLineView(runID: nil, line: line, instanceState: nil) { action in
                switch action {
                case .scrollToApproval:
                    // 待处理的审批卡片就在下面；还没对上（事件没到）时去对话里找。
                    if let first = pending.first {
                        withAnimation { proxy.scrollTo(first.id, anchor: .center) }
                    } else {
                        router.open(.conversation(run.instanceID))
                    }
                case .openModelRoutes: router.open(.modelRoutes(run.instanceID))
                case .openRunTree: router.open(.runTree(run.id))
                }
            }
        }
        // 实时活动（12.10，只在支持的设备上有）。
        if let live = app.liveActivities {
            LiveActivityRunButton(
                model: live, run: run, title: app.instances.first { $0.id == run.instanceID }?.name ?? AppInfo.appName)
        }
        if let process = model.process {
            ForEach(pending) { item in
                if case .approval(let card) = item.content {
                    ApprovalCardView(item: item, card: card, model: process)
                        .id(item.id)
                }
            }
        }
        VStack(alignment: .trailing, spacing: Metrics.Spacing.xxs) {
            Card(background: .bubble, bordered: false) {
                Text(ConversationText.detailLabel(.task, language: language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                Text(verbatim: run.prompt)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.promptIsAIGenerated { AIGeneratedLabel() }
        }
        infoCard(run)
        if let summary = run.summary, !summary.isEmpty {
            Card {
                Text(ConversationText.detailLabel(.summary, language: language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                MarkdownView(blocks: MarkdownParser.parse(summary))
                AIGeneratedLabel()
            }
            .contextMenu {
                MessageMenu(text: summary, target: .run(run.id)) { reportRequest = ReportRequest(target: $0) }
            }
        }
        if let error = run.error, !error.isEmpty, model.state == .failed {
            Card {
                Text(ConversationText.detailLabel(.error, language: language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                Text(language == .chinese ? "任务失败" : "The task failed")
                    .typography(.headline)
                    .foregroundStyle(Theme.danger)
                Button {
                    showsError.toggle()
                } label: {
                    Text(showsError ? ConversationText.hideDetails(language) : ConversationText.showDetails(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                if showsError {
                    Text(verbatim: error)
                        .font(Typography.caption.monospacedFont)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        actions(run)
        artifactsSection(run)
        if let error = model.detailsError, !error.isOffline {
            ErrorBanner(error) { Task { await model.load() } }
        }
    }

    private func infoCard(_ run: Run) -> some View {
        let model = self.model
        let instanceName = app.instances.first { $0.id == run.instanceID }?.name
        return Card {
            infoRow(.source, ConversationText.runSourceName(run.source, language: language))
            if let instanceName { infoRow(.instance, instanceName) }
            if let planID = run.planID {
                Button {
                    router.open(.plan(planID))
                } label: {
                    HStack {
                        infoRow(.plan, model.plan?.title ?? AppRoute.plan(planID).title(language))
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(Theme.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            infoRow(.attempts, String(run.attempt))
            infoRow(.tokens, ConversationText.tokens(run.tokensUsed, language: language))
            if let usage = model.lastUsage,
                let text = ConversationText.usageBreakdown(input: usage.input, output: usage.output, language: language)
            {
                infoRow(.usage, text)
            }
            infoRow(.created, Formatting.dateTime(run.createdAt, language: language))
            if let started = run.startedAt { infoRow(.started, Formatting.dateTime(started, language: language)) }
            if let finished = run.finishedAt { infoRow(.finished, Formatting.dateTime(finished, language: language)) }
            if let duration = model.duration {
                infoRow(.duration, Formatting.duration(duration, language: language))
            }
        }
    }

    private func infoRow(_ label: RunDetailLabel, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
            Text(ConversationText.detailLabel(label, language: language))
                .typography(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: Metrics.Spacing.s)
            Text(verbatim: value)
                .typography(.subheadline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ run: Run) -> some View {
        let model = self.model
        VStack(spacing: Metrics.Spacing.xs) {
            if let process = model.process {
                NavigationLink {
                    RunProcessScreen(model: process)
                } label: {
                    actionLabel(
                        ConversationText.detailLabel(.process, language: language), systemImage: "list.bullet.rectangle"
                    )
                }
                .buttonStyle(.plain)
            }
            if model.hasTree {
                Button {
                    router.open(.runTree(run.id))
                } label: {
                    actionLabel(
                        ConversationText.detailLabel(.runTree, language: language), systemImage: "arrow.triangle.branch"
                    )
                }
                .buttonStyle(.plain)
            }
            Button {
                router.open(.conversation(run.instanceID))
            } label: {
                actionLabel(
                    ConversationText.detailLabel(.openChat, language: language),
                    systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.plain)
            if model.canStop {
                HStack(spacing: Metrics.Spacing.xs) {
                    PillButton(
                        ConversationText.detailLabel(.stop, language: language), systemImage: "stop.fill",
                        kind: .destructive, size: .compact
                    ) {
                        stopsWholeTree = false
                        isConfirmingStop = true
                    }
                    if model.canStopTree {
                        PillButton(
                            ConversationText.detailLabel(.stopTree, language: language), systemImage: "stop.circle",
                            kind: .secondary, size: .compact
                        ) {
                            stopsWholeTree = true
                            isConfirmingStop = true
                        }
                    }
                    if model.isStopping { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }
                .disabled(model.isStopping)
            }
            if let error = model.stopError {
                ErrorBanner(error, onDismiss: { model.clearStopError() })
            }
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Metrics.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: Metrics.Spacing.l)
                .accessibilityHidden(true)
            Text(title)
                .typography(.body)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .frame(minHeight: Metrics.minTapTarget)
        .cardSurface()
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func artifactsSection(_ run: Run) -> some View {
        if let artifacts = model.artifacts {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                Text(ConversationText.detailLabel(.artifacts, language: language))
                    .typography(.title3)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if artifacts.isEmpty {
                    Text(ConversationText.detailLabel(.noArtifacts, language: language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                ForEach(artifacts) { artifact in
                    ArtifactCardView(
                        item: ConversationItem(
                            id: "artifact-\(artifact.id.rawValue)", runID: run.id, createdAt: artifact.createdAt,
                            content: .artifact(
                                ArtifactCard(
                                    artifactID: artifact.id, name: artifact.name, version: artifact.version,
                                    size: artifact.size))),
                        card: ArtifactCard(
                            artifactID: artifact.id, name: artifact.name, version: artifact.version, size: artifact.size
                        ),
                        instanceID: run.instanceID, onReport: { reportRequest = ReportRequest(target: $0) })
                }
            }
        }
    }
}

/// 只看本次过程：运行详情的视图模型里那个只归并这一个运行的时间线（没有输入框）。
struct RunProcessScreen: View {
    let model: ConversationModel

    @State private var reportRequest: ReportRequest?
    @Environment(\.client) private var client
    @Environment(\.displayLanguage) private var language

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ConversationTimeline(
                    model: model, instanceState: nil, proxy: proxy,
                    onReport: { reportRequest = ReportRequest(target: $0) }
                ) {
                    if model.isEmpty && model.hasLoaded {
                        EmptyStateView(
                            systemImage: "list.bullet.rectangle",
                            title: language == .chinese ? "这次没有过程记录" : "No steps recorded for this run")
                    }
                }
                .padding(Metrics.Spacing.m)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
        }
        .background(Theme.paper)
        .navigationTitle(ConversationText.detailLabel(.process, language: language))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.start() }
        .sheet(item: $reportRequest) { request in
            ContentReportSheet(client: client, target: request.target)
        }
    }
}

#Preview("运行详情 · 浅色中文") {
    RunDetailScreen(runID: DemoData.weeklyRunID).previewShell()
}

#Preview("运行详情 · 深色英文") {
    RunDetailScreen(runID: DemoData.reviewRunID).previewShell(.english, scheme: .dark)
}

#Preview("运行详情：等审批 · 浅色英文") {
    RunDetailScreen(runID: DemoData.postRunID).previewShell(.english)
}

#Preview("只看本次过程 · 浅色中文") {
    RunProcessScreen(
        model: ConversationModel(
            client: MockClient(autoReply: false), instanceID: DemoData.writerID, focusRunID: DemoData.weeklyRunID)
    )
    .previewShell()
}

#Preview("只看本次过程 · 深色英文") {
    RunProcessScreen(
        model: ConversationModel(
            client: MockClient(autoReply: false), instanceID: DemoData.writerID, focusRunID: DemoData.postRunID)
    )
    .previewShell(.english, scheme: .dark)
}
