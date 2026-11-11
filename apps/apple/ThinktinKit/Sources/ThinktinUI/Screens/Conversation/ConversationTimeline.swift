import SwiftUI
import ThinktinKit

/// 运行时间线（对话页、运行详情的“只看本次过程”共用）：按运行分组，组前面按需要加居中的时间分隔（隔 15 分钟以上或跨天，
/// `ConversationTimeSeparator`，参考 02 的“星期二 02:22”），每组先是来源行（计划、流水线、委派发起的，居中的小灰字），
/// 再是用户消息（右边的气泡）、agent 的输出（左边的灰气泡）和各种卡片。往上翻有“加载更早的记录”。
///
/// 放哪些项看 `ConversationModel.showsInTimeline`：对话页照参考 02 不放工具调用卡片、审批卡片和运行状态行（用户 2026-11-06
/// 定的“参考里没有的删掉”），失败、取消的那一组最后只放一行居中的小灰字（`RunEndNotice`）；“只看本次过程”都放，每组最后是
/// 运行状态行。那里等审批时状态行上的“去审批”滚到这一组的审批卡片
/// （`ScrollViewProxy`；卡片已经在这一组里时状态行不放“去审批”，这时只剩卡片还没对上的情况，去审批中心），等 key 去这个实例的
/// 模型路由，等子任务去运行树。
struct ConversationTimeline<Header: View>: View {
    let model: ConversationModel
    /// 实例状态（页头的“正在唤醒”、“只看本次过程”的状态行上的说明）。
    let instanceState: InstanceState?
    let proxy: ScrollViewProxy
    let onReport: (ContentReportTarget) -> Void
    @ViewBuilder let header: () -> Header

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Metrics.Spacing.xl) {
            header()
            if model.canLoadOlder {
                Button {
                    Task { await model.loadOlder() }
                } label: {
                    HStack(spacing: Metrics.Spacing.xs) {
                        if model.isLoadingOlder {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle")
                                .accessibilityHidden(true)
                        }
                        Text(ConversationText.loadOlder(language))
                    }
                    .typography(.footnote)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isLoadingOlder)
            }
            if let error = model.olderError, !error.isOffline {
                ErrorBanner(error) { Task { await model.loadOlder() } }
            }
            let separators = model.timeSeparators(language: language)
            ForEach(model.turns) { turn in
                if let label = separators[turn.id] {
                    // 参考 02、118：时间离上一组约 25pt、离下面的气泡约 20pt（比组间距的 24pt 近）。负的下边距把下面那一组
                    // 往上拉 8pt：字的上面约 26pt、下面约 18pt。
                    TimeSeparatorView(text: label)
                        .padding(.bottom, -Metrics.Spacing.xs)
                }
                ConversationTurnView(
                    turn: turn, model: model, instanceState: instanceState, onReport: onReport,
                    onStatusAction: { action in perform(action, in: turn) })
            }
            Color.clear
                .frame(height: 1)
                .id(ConversationScroll.bottomID)
                .accessibilityHidden(true)
        }
        .conversationLinkHandling(router)
    }

    /// 状态行上的一键跳转（只有“只看本次过程”有状态行）。
    private func perform(_ action: RunStatusAction, in turn: ConversationTurn) {
        switch action {
        case .scrollToApproval:
            if let runID = turn.runID, let itemID = model.pendingApprovalItemID(in: runID) {
                withAnimation { proxy.scrollTo(itemID, anchor: .center) }
            } else {
                router.open(.approvals)
            }
        case .openModelRoutes:
            router.open(.modelRoutes(model.instanceID))
        case .openRunTree:
            if let runID = turn.runID { router.open(.runTree(runID)) }
        }
    }
}

/// 时间线里滚动用的锚点。
enum ConversationScroll {
    /// 时间线最底下（发消息、重置之后滚到底）。
    static let bottomID = "conversation-bottom"
}

/// 对话页上失败、取消的那一组最后一行（`RunEndNotice`）：和时间分隔一样居中、小号、三级灰（参考 02 的小灰字），后面跟
/// 强调色的“再发一次”（能再发时）。不是卡片、不带按钮底，原因去运行详情看。
struct RunEndNoticeView: View {
    let notice: RunEndNotice
    let onSendAgain: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            Text(verbatim: notice.text(language))
                .foregroundStyle(Theme.inkTertiary)
            if let onSendAgain {
                Text(verbatim: "·")
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
                Button(ConversationText.sendAgain(language)) { onSendAgain() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
        }
        .typography(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Spacing.xs)
    }
}

/// 运行之间居中的时间（参考 02 的“星期二 02:22”）：小号、三级灰，读屏当分组标题念。自己不带上下的空，离上下多远由
/// 放它的地方定（时间线、`ConversationWelcome`）。
struct TimeSeparatorView: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .typography(.footnote)
            .foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 一个运行那一组：来源分隔头、用户消息、agent 的输出和卡片；没有过程记录的运行（超过保留期、本机没缓存）在状态行前面
/// 补一句说明和结果（`Run.summary`）；最后是状态行。对话页不放的项（工具调用、审批卡片、状态行，
/// `ConversationModel.showsInTimeline`）跳过；对话页上失败、取消的那一组最后是“没做完”的小灰字（`RunEndNoticeView`）。
struct ConversationTurnView: View {
    let turn: ConversationTurn
    let model: ConversationModel
    let instanceState: InstanceState?
    let onReport: (ContentReportTarget) -> Void
    let onStatusAction: (RunStatusAction) -> Void

    var body: some View {
        // 状态行总是这一组的最后一项（`ConversationReducer`）。
        let status = turn.items.last.flatMap { item -> ConversationItem? in
            if case .runStatus = item.content { return item }
            return nil
        }
        let entries = (status == nil ? turn.items : Array(turn.items.dropLast())).filter { model.showsInTimeline($0) }
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            if let run = turn.run, run.source != .user {
                SourceHeaderView(run: run, plan: model.plan(for: turn))
            }
            ForEach(entries) { item in
                itemView(item)
            }
            if let note = model.historyNote(for: turn) {
                let summaryID = ConversationFindTarget.summaryID(turnID: turn.id)
                HistoryRecordView(
                    note: note, summary: model.historySummary(for: turn), runID: turn.runID, onReport: onReport,
                    onQuote: quote, highlight: model.find.highlight(for: summaryID),
                    reactions: model.canReact ? model.reactions(for: summaryID) : nil,
                    onReact: { model.toggleReaction($0, on: summaryID) }
                )
                .id(summaryID)
            }
            if let status, model.showsInTimeline(status) {
                itemView(status)
            }
            if let notice = model.endNotice(for: turn) {
                RunEndNoticeView(notice: notice, onSendAgain: sendAgain)
            }
        }
    }

    /// “没做完”那一行后面的“再发一次”（和用户消息长按里的一样，`ConversationModel.canRetry`）。
    private var sendAgain: (@MainActor () -> Void)? {
        guard let runID = turn.runID, model.canRetry(turn) else { return nil }
        let model = self.model
        return { Task { await model.retry(runID) } }
    }

    /// 引用回复：有输入框的对话页才有。
    private var quote: (@MainActor (String) -> Void)? {
        guard model.focusRunID == nil, !model.isMissing else { return nil }
        let model = self.model
        return { model.setQuote($0) }
    }

    private func itemView(_ item: ConversationItem) -> some View {
        ConversationItemView(
            item: item, turn: turn, model: model, instanceState: instanceState, onReport: onReport,
            onStatusAction: onStatusAction
        )
        .id(item.id)
    }
}

/// 时间线里的一项：按种类分派到对应的视图。
struct ConversationItemView: View {
    let item: ConversationItem
    let turn: ConversationTurn
    let model: ConversationModel
    let instanceState: InstanceState?
    let onReport: (ContentReportTarget) -> Void
    let onStatusAction: (RunStatusAction) -> Void

    var body: some View {
        switch item.content {
        case .userMessage(let message):
            UserMessageView(
                message: message, isAIGenerated: promptIsAIGenerated, runID: turn.runID, onSendAgain: sendAgain,
                onQuote: quote, highlight: model.find.highlight(for: item.id), reactions: reactions, onReact: react)
        case .assistantText(let text):
            AssistantTextView(
                item: item, text: text, blocks: model.markdownBlocks(for: item), onReport: onReport, onQuote: quote,
                highlight: model.find.highlight(for: item.id), reactions: reactions, onReact: react)
        case .thought(let thought):
            ThoughtView(item: item, thought: thought, onReport: onReport, onQuote: quote)
        case .toolCall(let card):
            ToolCallCardView(card: card)
        case .agentPlan(let card):
            AgentPlanCardView(card: card, item: item, onReport: onReport, onQuote: quote)
        case .approval(let card):
            ApprovalCardView(item: item, card: card, model: model)
        case .vaultRequest(let card):
            VaultRequestCardView(card: card, model: model)
        case .runStatus(let line):
            RunStatusLineView(
                runID: turn.runID, line: line, instanceState: instanceState,
                approvalCardShown: turn.pendingApprovalItemID != nil, onAction: onStatusAction)
        case .artifact(let card):
            ArtifactCardView(item: item, card: card, instanceID: model.instanceID, onReport: onReport)
        case .childRun(let card):
            ChildRunCardView(card: card)
        case .planActivity(let card):
            PlanActivityCardView(card: card)
        case .systemNotice(let notice):
            SystemNoticeView(notice: notice)
        }
    }

    /// 引用回复（长按菜单的第一项）：有输入框的对话页才有，“只看本次过程”没有。
    private var quote: (@MainActor (String) -> Void)? {
        guard model.focusRunID == nil, !model.isMissing else { return nil }
        let model = self.model
        return { model.setQuote($0) }
    }

    /// 这条消息的表情回应（只在这台设备上，`MessageReactionStore`）；Botin 不在了是 nil（不能回应）。
    private var reactions: [String]? {
        model.canReact ? model.reactions(for: item.id) : nil
    }

    private var react: @MainActor (String) -> Void {
        let model = self.model
        let id = item.id
        return { model.toggleReaction($0, on: id) }
    }

    /// 再发一次这个任务（用户消息长按菜单里的“再发一次”；用户自己发的、已经结束的运行才有，`ConversationModel.canRetry`）。
    private var sendAgain: (@MainActor () -> Void)? {
        guard let runID = turn.runID, model.canRetry(turn) else { return nil }
        let model = self.model
        return { Task { await model.retry(runID) } }
    }

    /// 任务要不要带“AI 生成”标识（委派、流水线步骤、agent 建的计划触发的）。
    private var promptIsAIGenerated: Bool {
        guard let run = turn.run else { return false }
        return AIGeneratedField.prompt(of: run, planAuthor: model.plan(for: turn)?.createdBy).isAIGenerated
    }
}
