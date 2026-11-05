import SwiftUI
import ThinktinKit

/// 审批中心（`.approvals`，工作台菜单和设置里的“审批”，WBS 12.15）。参考里没有这一页，照第 2 节的视觉语言排（规范 1.3、2.5）：
///
/// - 压栈页，inline 标题“审批”；insetGrouped 列表，顶上一句灰色说明。
/// - 电脑发来的高危操作一组（12.9，`ComputerApprovalsSection`），然后每个等你处理的审批一张分组卡片（快过期的在前）：
///   Botin 头像和名字、剩余时间，Botin 写的标题（AI 生成标识），要执行的操作，选项是玻璃胶囊（批准类先过本机验证，拒绝直接发），
///   最后一行“查看详情”。
/// - 决定后从列表里拿掉，刷新工作台的角标。没有审批时 `ContentUnavailableView`。
///
/// 离线策略是“没有缓存”：离线时显示已经拉到的，选项都禁用。
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
        // 剩余时间每 30 秒换一次；过期的从列表里拿掉。
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let list = model.visible(now: context.date)
            List {
                Section {
                    Text(ApprovalsText.intro(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, Metrics.Spacing.m)
                        .clearListRow()
                }
                if let error = visibleError(model.error) {
                    Section {
                        ErrorBanner(error) { Task { await model.load() } }
                            .clearListRow()
                    }
                }
                if let notice = model.notice {
                    Section {
                        Button {
                            model.clearNotice()
                        } label: {
                            NoticeText(text: ApprovalsText.notice(notice, language: language), tone: .success)
                        }
                        .buttonStyle(.plain)
                    }
                    .themedRow()
                }
                // 电脑发来的高危操作（12.9，经设备中继，要手机签名批准；只在能签名的设备上有）。
                ComputerApprovalsSection()
                ForEach(list) { approval in
                    Section {
                        ApprovalRequestCard(
                            approval: approval, instanceName: model.instanceName(approval.instanceID),
                            appearance: app.appearances.resolved(for: approval.instanceID),
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
                    .themedRow()
                }
            }
            .insetGroupedList()
            .themedGroupedBackground()
            .overlay {
                if list.isEmpty {
                    if model.hasLoaded {
                        ContentUnavailableView {
                            Label(ApprovalsText.emptyTitle(language), systemImage: "checkmark.shield")
                        } description: {
                            Text(ApprovalsText.emptyMessage(language))
                        }
                    } else if visibleError(model.error) == nil {
                        ProgressView()
                    }
                }
            }
        }
        .inlineNavigationTitle(AppRoute.approvals.title(language))
        .refreshable { await model.load() }
        // 每次回到这一页都重新拉（详情页、对话里可能处理过）。
        .task { await model.load() }
        .onChange(of: app.isOffline) {
            if !app.isOffline { Task { await model.load() } }
        }
    }
}

/// 审批详情（`.approval(id)`：推送、深链、收件箱、对话里的审批卡片进来）：待处理的可以直接决定；已处理的显示结论。
/// 推送进来时已经处理过、过期了的显示结论，不报错。insetGrouped 列表：审批这一组，下面一组“查看这次运行”“去对话”。
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
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            List {
                if let approval = model.approval, !model.isMissing {
                    if model.handledElsewhere {
                        Section {
                            NoticeText(text: ApprovalsText.handledElsewhere(language), tone: .waiting)
                        }
                        .themedRow()
                    }
                    Section {
                        ApprovalRequestCard(
                            approval: approval, instanceName: model.instanceName,
                            appearance: app.appearances.resolved(for: approval.instanceID), now: context.date,
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
                    .themedRow()
                    Section {
                        NavigationLink(value: AppRoute.run(approval.runID)) {
                            Label(ApprovalsText.openRun(language), systemImage: "list.bullet.rectangle")
                        }
                        if model.instanceName != nil {
                            Button {
                                router.open(.conversation(approval.instanceID))
                            } label: {
                                Label(
                                    ApprovalsText.openConversation(language),
                                    systemImage: "bubble.left.and.bubble.right")
                            }
                        }
                    }
                    .themedRow()
                } else if !model.isMissing, let error = visibleError(model.error) {
                    Section {
                        ErrorBanner(error) { Task { await model.load() } }
                            .clearListRow()
                    }
                }
            }
            .insetGroupedList()
            .themedGroupedBackground()
            .overlay {
                if model.isMissing {
                    ContentUnavailableView {
                        Label(ApprovalsText.missingTitle(language), systemImage: "questionmark.circle")
                    } description: {
                        Text(ApprovalsText.missingMessage(language))
                    }
                } else if model.approval == nil, visibleError(model.error) == nil {
                    ProgressView()
                }
            }
        }
        .inlineNavigationTitle(AppRoute.approval(model.approvalID).title(language))
        .refreshable { await model.load() }
        .task { await model.load() }
    }
}

/// 一条审批，是分组列表里的一行（审批中心的卡片、详情页的主体）：Botin 头像和名字、剩余时间或结论，标题（AI 生成标识），
/// 要执行的操作，选项（玻璃胶囊，第一个批准类的是突出的那种）；审批中心的最后一行“查看详情”。
struct ApprovalRequestCard: View {
    let approval: Approval
    let instanceName: String?
    /// Botin 头像的形状和颜色；nil 是默认的。
    var appearance: InstanceAppearance? = nil
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
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HStack(spacing: Metrics.Spacing.xs) {
                if let instanceName {
                    InstanceAvatar(instanceName, appearance: appearance, size: Metrics.Avatar.title)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityHidden(true)
                }
                Text(verbatim: instanceName ?? ApprovalsText.deletedInstance(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pending {
                    Text(ConversationText.approvalExpiry(approval.expiresAt, now: now, language: language))
                        .typography(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.warning)
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
                    .padding(.top, Metrics.Spacing.xxs)
            } else if let outcome = outcome {
                NoticeText(
                    text: ConversationText.approvalOutcome(
                        outcome, optionName: approval.decidedOptionInfo?.name, language: language),
                    tone: outcome == .approvedByUser ? .success : .muted)
            }
            if let error { errorView(error) }
            if let onOpen {
                Divider()
                    .padding(.top, Metrics.Spacing.xxs)
                Button {
                    onOpen()
                } label: {
                    HStack {
                        Text(ApprovalsText.viewDetails(language))
                            .typography(.subheadline)
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
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

    /// 选项：全宽的玻璃胶囊，一个一行（选项的名字是服务端给的，可能很长）。
    private var options: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            ForEach(approval.options) { option in
                Button {
                    onDecide(option)
                } label: {
                    Label(
                        option.name.isEmpty
                            ? ConversationText.approvalOptionName(option.kind, language: language) : option.name,
                        systemImage: option.kind.isReject ? "xmark" : "checkmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(option.id == primaryOptionID ? .prominent : .regular)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
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
