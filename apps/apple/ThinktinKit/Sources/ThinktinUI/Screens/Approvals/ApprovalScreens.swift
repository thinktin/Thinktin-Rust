import SwiftUI
import ThinktinKit

/// 审批中心（`.approvals`，工作台菜单和设置里的“审批”，WBS 12.15）。参考里没有这一页，照第 2 节的视觉语言排（规范 1.3、2.5）：
///
/// - 压栈页，inline 标题“审批”；insetGrouped 列表，紧贴导航栏（`compactGroupedList`），说明放在第一个审批的脚注里
///   （导航栏下面不放说明段落，和计划、产出物一样，规范 4.5.1、4.5.2）。
/// - 电脑发来的高危操作一组（12.9，`ComputerApprovalsSection`），然后每个等你处理的审批一组（快过期的在前）：一行卡片
///   （Botin 头像和名字、剩余时间，Botin 写的标题和 AI 生成标识，要执行的操作，选项是普通大小的玻璃胶囊；批准类先过本机验证，
///   拒绝直接发），下面一行系统的“详情”（`NavigationLink`，系统画分隔线和 chevron）。
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
                            onClearError: { model.clearError(approval.id) })
                        NavigationLink(value: AppRoute.approval(approval.id)) {
                            Text(ApprovalsText.viewDetails(language))
                                .foregroundStyle(Theme.ink)
                        }
                    } footer: {
                        if approval.id == list.first?.id {
                            Text(ApprovalsText.intro(language))
                        }
                    }
                    .themedRow()
                }
            }
            .insetGroupedList()
            .compactGroupedList()
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
                            onClearError: { model.clearDecideError() })
                    }
                    .themedRow()
                    Section {
                        NavigationLink(value: AppRoute.run(approval.runID)) {
                            Label(ApprovalsText.openRun(language), systemImage: "list.bullet.rectangle")
                        }
                        if model.instanceName != nil {
                            // 回首页再进对话（`router.open`，不压在这一页上），所以是按钮；样子和上面的 `NavigationLink`
                            // 一样：墨色的字、行尾灰箭头（规范 2.5，Botin 资料页的行也是这样），不是强调色的按钮字。
                            Button {
                                router.open(.conversation(approval.instanceID))
                            } label: {
                                HStack {
                                    Label {
                                        Text(ApprovalsText.openConversation(language))
                                            .foregroundStyle(Theme.ink)
                                    } icon: {
                                        Image(systemName: "bubble.left.and.bubble.right")
                                    }
                                    Spacer(minLength: Metrics.Spacing.xs)
                                    Image(systemName: "chevron.right")
                                        .font(Typography.footnote.font.weight(.semibold))
                                        .foregroundStyle(Theme.inkTertiary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
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
/// 要执行的操作，选项（普通大小的玻璃胶囊，第一个批准类的是突出的那种）。审批中心在它下面另放一行“详情”。
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
                    // 和对话里的审批卡片一样是次要的灰：剩余时间是说明，不是状态（`warning` 只给状态用，规范 2.2）。
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
                    .padding(.top, Metrics.Spacing.xxs)
            } else if let outcome = outcome {
                NoticeText(
                    text: ConversationText.approvalOutcome(
                        outcome, optionName: approval.decidedOptionInfo?.name, language: language),
                    tone: outcome == .approvedByUser ? .success : .muted)
            }
            if let error { errorView(error) }
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

    /// 选项：全宽的玻璃胶囊，一个一行（选项的名字是服务端给的，可能很长）。普通大小（`.large` 三个摞起来一条审批占半屏，
    /// 2026-11-05 截图审查；对话里只有一张卡片，那里照旧 `.large`）。
    private var options: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            ForEach(approval.options) { option in
                let prominent = option.id == primaryOptionID
                Button {
                    onDecide(option)
                } label: {
                    ApprovalOptionLabel(option: option, prominent: prominent)
                }
                .glassButtonStyle(prominent ? .prominent : .regular)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
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
