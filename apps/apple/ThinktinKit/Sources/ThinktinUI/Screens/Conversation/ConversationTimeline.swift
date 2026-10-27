import SwiftUI
import ThinktinKit

/// 运行时间线（对话页、运行详情的“只看本次过程”共用）：按运行分组，每组先是来源分隔头（计划、流水线、委派发起的），
/// 再是用户消息、agent 的输出和各种卡片，最后是运行状态行。往上翻有“加载更早的记录”。
///
/// 等审批时状态行上的“去审批”滚到这一组的审批卡片（`ScrollViewProxy`），等 key 去这个实例的模型路由，等子任务去运行树。
struct ConversationTimeline<Header: View>: View {
    let model: ConversationModel
    /// 实例状态（页头的“正在唤醒”、状态行上的说明）。
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
            ForEach(model.turns) { turn in
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

    /// 状态行上的一键跳转。
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

/// 一个运行那一组：来源分隔头、用户消息、agent 的输出和卡片；没有过程记录的运行（超过保留期、本机没缓存）在状态行前面
/// 补一句说明和结果（`Run.summary`）；最后是状态行。
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
        let entries = status == nil ? turn.items : Array(turn.items.dropLast())
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            if let run = turn.run, run.source != .user {
                SourceHeaderView(run: run, plan: model.plan(for: turn))
            }
            ForEach(entries) { item in
                itemView(item)
            }
            if let note = model.historyNote(for: turn) {
                HistoryRecordView(
                    note: note, summary: model.historySummary(for: turn), runID: turn.runID, onReport: onReport)
            }
            if let status {
                itemView(status)
            }
        }
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
            UserMessageView(message: message, isAIGenerated: promptIsAIGenerated, onSendAgain: sendAgain)
        case .assistantText(let text):
            AssistantTextView(item: item, text: text, blocks: model.markdownBlocks(for: item), onReport: onReport)
        case .thought(let thought):
            ThoughtView(item: item, thought: thought, onReport: onReport)
        case .toolCall(let card):
            ToolCallCardView(card: card)
        case .agentPlan(let card):
            AgentPlanCardView(card: card, item: item, onReport: onReport)
        case .approval(let card):
            ApprovalCardView(item: item, card: card, model: model)
        case .vaultRequest(let card):
            VaultRequestCardView(card: card, model: model)
        case .runStatus(let line):
            RunStatusLineView(
                runID: turn.runID, line: line, instanceState: instanceState, onAction: onStatusAction,
                onRetry: line.state == .failed || line.state == .cancelled ? sendAgain : nil)
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

    /// 再发一次这个任务（用户自己发的、已经结束的运行才有，`ConversationModel.canRetry`）。
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
