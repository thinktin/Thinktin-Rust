import SwiftUI
import ThinktinKit

/// 运行详情（`.run(id)`：状态行、收件箱、推送、计划的运行历史进来；对应 Claude Code 的会话详情）：
///
/// insetGrouped 列表（和计划详情、审批、进行中一套样子，2026-11-05 截图审查前是自己画的卡片）：
///
/// - 居中的头部（`RunDetailHeader`：状态图标、状态、用时 · token，等待类给一键跳转）；
/// - 等审批时，待处理的审批卡片直接放在头部下面（在这里就能批，“去审批”滚到它）；
/// - 任务（用户气泡的灰，委派、流水线的带 AI 标识），来源、Botin、所属计划、尝试次数、token、时间（`LabeledContent`）；
/// - 摘要（Markdown，AI 生成标识）、失败原因（正文只说失败，英文诊断折起来）；
/// - 一组：只看本次过程（同一个视图模型的时间线）、运行树（有子运行时）、打开对话，能停时停止 / 停止整棵树；
/// - 产出物（和产出物库同一种行）；右上 `ellipsis` 菜单里举报。
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
            List {
                if let error = model.error, !error.isOffline {
                    Section {
                        ErrorBanner(error) { Task { await model.load() } }
                            .clearListRow()
                    }
                }
                if let run = model.run, !model.isMissing {
                    content(run, proxy: proxy)
                }
            }
            .insetGroupedList()
            .compactGroupedList()
            .themedGroupedBackground()
            .conversationLinkHandling(router)
            .overlay {
                if model.isMissing {
                    ContentUnavailableView {
                        Label(ConversationText.runMissing(language), systemImage: "questionmark.square.dashed")
                    } actions: {
                        Button(language == .chinese ? "返回" : "Go back") { router.pop() }
                            .glassButtonStyle()
                    }
                } else if model.run == nil {
                    ConversationLoadingView()
                }
            }
        }
        .inlineNavigationTitle(AppRoute.run(model.runID).title(language))
        .toolbar {
            if model.run != nil {
                ToolbarItem(placement: ToolbarSlot.trailing) {
                    Menu {
                        Button(role: .destructive) {
                            reportRequest = ReportRequest(target: .run(model.runID))
                        } label: {
                            Label(ConversationText.report(language), systemImage: "flag")
                        }
                    } label: {
                        // 规范 2.6：`ellipsis`，玻璃圆由系统画（以前的 `ellipsis.circle` 是圆里套圆）。
                        Label(language == .chinese ? "更多操作" : "More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .neutralTint()
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
        Section {
            VStack(spacing: 0) {
                RunDetailHeader(line: model.statusLine, fallbackState: model.state ?? run.state) { action in
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
                // 实时活动（12.10，只在支持的设备上有）。
                if let live = app.liveActivities {
                    LiveActivityRunButton(
                        model: live, run: run,
                        title: app.instances.first { $0.id == run.instanceID }?.name ?? AppInfo.appName
                    )
                    .padding(.bottom, Metrics.Spacing.s)
                }
            }
            .clearListRow()
        }
        if let process = model.process {
            ForEach(pending) { item in
                if case .approval(let card) = item.content {
                    Section {
                        // 对话里的审批卡片（自己画的卡片底），在这里就能批。
                        ApprovalCardView(item: item, card: card, model: process)
                            .clearListRow()
                            .id(item.id)
                    }
                }
            }
        }
        taskSection(run)
        infoSection(run)
        if let summary = run.summary, !summary.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    MarkdownView(blocks: MarkdownParser.parse(summary))
                    AIGeneratedLabel()
                }
                .padding(.vertical, Metrics.Spacing.xxs)
                .messageMenu(
                    .agentOutput(summary, runID: run.id, target: .run(run.id)) {
                        reportRequest = ReportRequest(target: $0)
                    })
            } header: {
                Text(ConversationText.detailLabel(.summary, language: language)).groupHeader()
            }
            .themedRow()
        }
        if let error = run.error, !error.isEmpty, model.state == .failed {
            errorSection(error)
        }
        actionsSection(run)
        artifactsSection(run)
        if let error = model.detailsError, !error.isOffline {
            Section {
                ErrorBanner(error) { Task { await model.load() } }
                    .clearListRow()
            }
        }
    }

    /// 任务：和对话里自己发的那条一样是用户气泡的灰（引用回复画成一小块）。
    private func taskSection(_ run: Run) -> some View {
        let parts = MessageQuote.split(run.prompt)
        return Section {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                if let quote = parts.quote {
                    QuotedBlock(quote: quote)
                }
                Text(verbatim: parts.body)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if model.promptIsAIGenerated { AIGeneratedLabel() }
            }
            .padding(.vertical, Metrics.Spacing.xxs)
            .listRowBackground(Theme.userBubble)
        } header: {
            Text(ConversationText.detailLabel(.task, language: language)).groupHeader()
        }
    }

    /// 来源、Botin、计划（能点）、尝试次数、token、用量、时间：系统的 `LabeledContent` 行（灰标题、右边的值，系统画分隔线）。
    private func infoSection(_ run: Run) -> some View {
        let model = self.model
        let instanceName = app.instances.first { $0.id == run.instanceID }?.name
        return Section {
            infoRow(.source, ConversationText.runSourceName(run.source, language: language))
            if let instanceName { infoRow(.instance, instanceName) }
            if let planID = run.planID {
                NavigationLink(value: AppRoute.plan(planID)) {
                    infoRow(.plan, model.plan?.title ?? AppRoute.plan(planID).title(language))
                }
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
        .themedRow()
    }

    private func infoRow(_ label: RunDetailLabel, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(ConversationText.detailLabel(label, language: language))
                .foregroundStyle(Theme.ink)
        }
    }

    private func errorSection(_ error: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
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
                .buttonStyle(.borderless)
                if showsError {
                    Text(verbatim: error)
                        .font(Typography.caption.monospacedFont)
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Metrics.Spacing.xxs)
        } header: {
            Text(ConversationText.detailLabel(.error, language: language)).groupHeader()
        }
        .themedRow()
    }

    /// 只看本次过程、运行树、打开对话一组（系统的行和 chevron），能停的时候再加一行停止的按钮。
    private func actionsSection(_ run: Run) -> some View {
        let model = self.model
        return Section {
            if let process = model.process {
                NavigationLink {
                    RunProcessScreen(model: process)
                } label: {
                    RowLabel(
                        ConversationText.detailLabel(.process, language: language), systemImage: "list.bullet.rectangle"
                    )
                }
            }
            if model.hasTree {
                NavigationLink(value: AppRoute.runTree(run.id)) {
                    RowLabel(
                        ConversationText.detailLabel(.runTree, language: language), systemImage: "arrow.triangle.branch"
                    )
                }
            }
            // 回首页再进对话（`router.open`，不压在这一页上），所以是按钮；样子和上面的 `NavigationLink` 一样（墨色的字、
            // 行尾灰箭头），和审批详情的“去对话”同一个写法。
            Button {
                router.open(.conversation(run.instanceID))
            } label: {
                HStack {
                    RowLabel(
                        ConversationText.detailLabel(.openChat, language: language),
                        systemImage: "bubble.left.and.text.bubble.right")
                    Spacer(minLength: Metrics.Spacing.xs)
                    Image(systemName: "chevron.right")
                        .font(Typography.footnote.font.weight(.semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.ink)
                .contentShape(Rectangle())
            }
            if model.canStop {
                AdaptiveRow {
                    Button(role: .destructive) {
                        stopsWholeTree = false
                        isConfirmingStop = true
                    } label: {
                        Label(ConversationText.detailLabel(.stop, language: language), systemImage: "stop.fill")
                    }
                    // 写在样式前面：次按钮默认是中性色（`glassButtonStyle`），停止要红色。
                    .tint(StatusTone.failure.color)
                    .smallCapsuleButton()
                    if model.canStopTree {
                        Button {
                            stopsWholeTree = true
                            isConfirmingStop = true
                        } label: {
                            Label(
                                ConversationText.detailLabel(.stopTree, language: language), systemImage: "stop.circle")
                        }
                        .smallCapsuleButton()
                    }
                    if model.isStopping { ProgressView().controlSize(.small) }
                }
                .disabled(model.isStopping)
            }
            if let error = model.stopError {
                ErrorBanner(error, onDismiss: { model.clearStopError() })
                    .clearListRow()
            }
        }
        .themedRow()
    }

    /// 产出物：和产出物库同一种行（`ArtifactRow`：28pt 图标、名字、灰色副标题、行尾 AI 生成标识），点了进产出物详情，
    /// 长按举报（以前是对话里的产出物卡片，同一个文件在两页长得不一样）。
    @ViewBuilder
    private func artifactsSection(_ run: Run) -> some View {
        if let artifacts = model.artifacts {
            Section {
                if artifacts.isEmpty {
                    Text(ConversationText.detailLabel(.noArtifacts, language: language))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                }
                ForEach(artifacts) { artifact in
                    Button {
                        router.open(.artifact(artifact.id, runID: run.id))
                    } label: {
                        ArtifactRow(artifact: artifact, instanceName: nil)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            reportRequest = ReportRequest(target: .artifact(runID: run.id, artifactID: artifact.id))
                        } label: {
                            Label(ConversationText.report(language), systemImage: "flag")
                        }
                    }
                }
            } header: {
                Text(ConversationText.detailLabel(.artifacts, language: language)).groupHeader()
            }
            .themedRow()
        }
    }
}

/// 运行详情的头部（计划详情、Botin 资料那样居中）：44pt 的状态图标、状态（`.title2` 粗体）、一行灰色说明（用时 · token、
/// 等什么），等待类的再给一个跳转的小胶囊（去审批、模型路由、运行树）；有原文（agent 写的审批标题、英文诊断）时可以展开。
struct RunDetailHeader: View {
    let line: RunStatusLine?
    /// 还没有状态行时（事件没到）用运行自己的状态。
    let fallbackState: RunState
    let onAction: (RunStatusAction) -> Void

    @Environment(\.displayLanguage) private var language
    @State private var showsReason = false

    var body: some View {
        let state = line?.state ?? fallbackState
        let p = line.map { RunStatusPresentation(line: $0, language: language) }
        let tone = state.statusAppearance.tone
        VStack(spacing: Metrics.Spacing.xs) {
            Image(systemName: Self.systemImage(state))
                .font(.system(size: 44))
                .foregroundStyle(tone == .neutral || tone == .muted ? Theme.inkSecondary : tone.color)
                .accessibilityHidden(true)
            Text(verbatim: p?.headline ?? state.localizedName(language))
                .font(Font.title2.bold())
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail = p?.detail {
                Text(verbatim: detail)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = p?.action, let title = p?.actionTitle {
                Button(title) { onAction(action) }
                    .smallCapsuleButton()
            }
            if let reason = p?.reason {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsReason.toggle() }
                } label: {
                    Text(showsReason ? ConversationText.hideDetails(language) : ConversationText.showDetails(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.borderless)
                if showsReason {
                    VStack(spacing: Metrics.Spacing.xxs) {
                        Text(verbatim: reason)
                            .font(
                                p?.reasonIsAIGenerated == true
                                    ? Typography.footnote.font : Typography.caption.monospacedFont
                            )
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if p?.reasonIsAIGenerated == true { AIGeneratedLabel() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Spacing.xs)
        .padding(.bottom, Metrics.Spacing.m)
    }

    /// 状态的图标（颜色按状态的色调）。
    static func systemImage(_ state: RunState) -> String {
        switch state {
        case .queued: "clock"
        case .starting: "hourglass"
        case .running: "play.circle"
        case .waitingApproval: "hand.raised.circle"
        case .waitingDevice: "iphone.radiowaves.left.and.right"
        case .waitingQuota: "key"
        case .waitingChildren: "arrow.triangle.branch"
        case .backoff: "arrow.clockwise.circle"
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .cancelled: "stop.circle"
        case .unknown: "questionmark.circle"
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
                        ContentUnavailableView(
                            language == .chinese ? "这次没有过程记录" : "No steps recorded for this run",
                            systemImage: "list.bullet.rectangle")
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
