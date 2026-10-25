import SwiftUI
import ThinktinKit

/// 审批中心（`.approvals`，抽屉里的“审批”，WBS 12.15）：所有实例等你处理的审批，快过期的在前。每张卡片：实例、agent 写的
/// 标题（AI 生成标识）、要执行的操作、剩余时间、选项（批准类先过本机验证，拒绝直接发）；点“详情”看完整内容。
/// 决定后从列表里拿掉，刷新抽屉的角标。离线策略是“没有缓存”：离线时显示已经拉到的。
struct ApprovalCenterScreen: View {
    @Environment(\.client) private var client
    @Environment(\.biometricGate) private var gate

    var body: some View {
        ApprovalCenterContent(
            model: ApprovalCenterModel(
                client: client, biometricGate: ConversationGate.resolve(gate, client: client)))
    }
}

private struct ApprovalCenterContent: View {
    @State private var model: ApprovalCenterModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: ApprovalCenterModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                AgentsPageHeader(title: AppRoute.approvals.title(language), message: ApprovalsText.intro(language))
                if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                }
                if let notice = model.notice {
                    NoticeText(text: ApprovalsText.notice(notice, language: language), tone: .success)
                        .onTapGesture { model.clearNotice() }
                }
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    let list = model.visible(now: context.date)
                    if list.isEmpty {
                        if model.hasLoaded {
                            EmptyStateView(
                                systemImage: "checkmark.shield", title: ApprovalsText.emptyTitle(language),
                                message: ApprovalsText.emptyMessage(language))
                        } else {
                            AgentsLoadingView()
                        }
                    } else {
                        VStack(spacing: Metrics.Spacing.s) {
                            ForEach(list) { approval in
                                ApprovalRequestCard(
                                    approval: approval, instanceName: model.instanceName(approval.instanceID),
                                    now: context.date, isDeciding: model.deciding.contains(approval.id),
                                    error: model.errors[approval.id], canWrite: !app.isOffline,
                                    onDecide: { option in
                                        Task {
                                            await model.decide(
                                                approval, option: option,
                                                reason: ConversationText.verificationReason(
                                                    title: approval.title, language: language))
                                            await app.refreshBadges()
                                        }
                                    },
                                    onClearError: { model.clearError(approval.id) },
                                    onOpen: { router.open(.approval(approval.id)) })
                            }
                        }
                    }
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.approvals.title(language))
        .refreshable { await model.load() }
        // 每次回到这一页都重新拉（详情页、对话里可能处理过）。
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }
}

/// 审批详情（`.approval(id)`：推送、深链、收件箱、对话里的审批卡片进来）：待处理的可以直接决定；已处理的显示结论。
/// 推送进来时已经处理过、过期了的显示结论，不报错。
struct ApprovalDetailScreen: View {
    let approvalID: ApprovalID

    @Environment(\.client) private var client
    @Environment(\.biometricGate) private var gate

    var body: some View {
        ApprovalDetailContent(
            model: ApprovalDetailModel(
                client: client, approvalID: approvalID, biometricGate: ConversationGate.resolve(gate, client: client)))
    }
}

private struct ApprovalDetailContent: View {
    @State private var model: ApprovalDetailModel

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    init(model: ApprovalDetailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let model = self.model
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                if model.isMissing {
                    EmptyStateView(
                        systemImage: "questionmark.circle", title: ApprovalsText.missingTitle(language),
                        message: ApprovalsText.missingMessage(language))
                } else if let approval = model.approval {
                    if model.handledElsewhere {
                        NoticeText(text: ApprovalsText.handledElsewhere(language), tone: .waiting)
                    }
                    TimelineView(.periodic(from: Date(), by: 30)) { context in
                        ApprovalRequestCard(
                            approval: approval, instanceName: model.instanceName, now: context.date,
                            isDeciding: model.isDeciding, error: model.decideError, canWrite: !app.isOffline,
                            showsDetails: true,
                            onDecide: { option in
                                Task {
                                    await model.decide(
                                        option: option,
                                        reason: ConversationText.verificationReason(
                                            title: approval.title, language: language))
                                    await app.refreshBadges()
                                }
                            },
                            onClearError: { model.clearDecideError() }, onOpen: nil)
                    }
                    links(approval)
                } else if let error = agentsVisibleError(model.error) {
                    ErrorBanner(error) { Task { await model.load() } }
                } else {
                    AgentsLoadingView()
                }
            }
            .agentsPageLayout()
        }
        .background(Theme.paper)
        .agentsNavigationTitle(AppRoute.approval(model.approvalID).title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private func links(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            Button {
                router.open(.run(approval.runID))
            } label: {
                Label(ApprovalsText.openRun(language), systemImage: "list.bullet.rectangle")
                    .typography(.subheadline)
                    .frame(minHeight: Metrics.minTapTarget)
            }
            if model.instanceName != nil {
                Button {
                    router.open(.conversation(approval.instanceID))
                } label: {
                    Label(ApprovalsText.openConversation(language), systemImage: "bubble.left.and.bubble.right")
                        .typography(.subheadline)
                        .frame(minHeight: Metrics.minTapTarget)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }
}

/// 一条审批（审批中心的卡片、详情页的主体）：实例、标题（AI 生成标识）、要执行的操作、剩余时间或结论、选项。
struct ApprovalRequestCard: View {
    let approval: Approval
    let instanceName: String?
    let now: Date
    let isDeciding: Bool
    let error: ConversationActionError?
    let canWrite: Bool
    /// 详情页：显示请求 / 处理时间和工具调用的原始内容。
    var showsDetails = false
    let onDecide: (ApprovalOption) -> Void
    let onClearError: () -> Void
    /// 审批中心的“详情”；详情页为 nil。
    let onOpen: (() -> Void)?

    @Environment(\.displayLanguage) private var language
    @State private var showsRaw = false

    var body: some View {
        let pending = approval.isPending && !approval.isExpired(now: now)
        Card {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: pending ? "hand.raised" : "checkmark.shield")
                    .foregroundStyle(pending ? Theme.warning : Theme.inkSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: instanceName ?? ApprovalsText.deletedInstance(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pending {
                    Text(ConversationText.approvalExpiry(approval.expiresAt, now: now, language: language))
                        .typography(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            if let title = approval.title, !title.isEmpty {
                Text(verbatim: title)
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                AIGeneratedLabel()
            }
            if let summary = toolSummary {
                Text(verbatim: summary)
                    .font(Typography.footnote.monospacedFont)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(showsDetails ? nil : 3)
            }
            if showsDetails { details }
            if pending {
                options
            } else if let outcome = outcome {
                NoticeText(
                    text: ConversationText.approvalOutcome(
                        outcome, optionName: approval.decidedOptionInfo?.name, language: language),
                    tone: outcome == .approvedByUser ? .success : .muted)
            }
            if let error { errorView(error) }
            if let onOpen {
                Button {
                    onOpen()
                } label: {
                    Text(ApprovalsText.viewDetails(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: Metrics.minTapTarget)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var outcome: ApprovalOutcome? {
        if approval.isPending { return approval.isExpired(now: now) ? .expired : nil }
        return ApprovalDetailModel.recordOutcome(of: approval)
    }

    /// 工具调用的一句话摘要（命令、路径）。
    private var toolSummary: String? {
        guard let payload = approval.toolCall else { return nil }
        let tool = ToolCallCard(
            toolCallID: payload.toolCallID, title: payload.title ?? "", kind: payload.kind, raw: payload.raw)
        return ToolCallPresentation(tool, language: language).summary
    }

    @ViewBuilder
    private var details: some View {
        Text(ApprovalsText.requestedAt(approval.createdAt, language: language))
            .typography(.caption)
            .foregroundStyle(Theme.inkSecondary)
        if let decidedAt = approval.decidedAt {
            Text(ApprovalsText.decidedAt(decidedAt, language: language))
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
        if approval.toolCall != nil {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsRaw.toggle() }
            } label: {
                HStack(spacing: Metrics.Spacing.xs) {
                    Text(ApprovalsText.rawDetails(language))
                        .typography(.footnote)
                    Image(systemName: showsRaw ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.inkSecondary)
                .frame(minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                Text(showsRaw ? ConversationText.hideDetails(language) : ConversationText.showDetails(language)))
            if showsRaw {
                Text(verbatim: approval.toolCallJSON)
                    .font(Typography.footnote.monospacedFont)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var options: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            ForEach(approval.options) { option in
                PillButton(
                    option.name.isEmpty
                        ? ConversationText.approvalOptionName(option.kind, language: language) : option.name,
                    systemImage: option.kind.isReject ? "xmark" : "checkmark",
                    kind: option.id == primaryOptionID ? .primary : .secondary
                ) {
                    onDecide(option)
                }
                .frame(maxWidth: .infinity)
                .disabled(isDeciding || !canWrite)
            }
        }
        .overlay {
            if isDeciding { ProgressView() }
        }
    }

    /// 第一个批准类的选项是主按钮。
    private var primaryOptionID: String? {
        approval.options.first { $0.kind.isAllow }?.id
    }

    @ViewBuilder
    private func errorView(_ error: ConversationActionError) -> some View {
        switch error {
        case .client(let failure):
            ErrorBanner(failure, onDismiss: { onClearError() })
        case .verificationFailed:
            NoticeText(text: ConversationText.verificationFailed(language), tone: .failure)
        case .notLinked:
            NoticeText(text: ConversationText.approvalNotLinked(language), tone: .waiting)
        }
    }
}
