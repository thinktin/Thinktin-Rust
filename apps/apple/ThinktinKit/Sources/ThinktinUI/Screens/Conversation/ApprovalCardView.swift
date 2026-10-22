import SwiftUI
import ThinktinKit

/// 对话里的审批卡片（12.15 的审批中心做完整的列表和详情，这里先做内嵌卡片）：
///
/// - 未决：agent 写的标题（带“AI 生成”标识）、要执行的工具调用、剩余时间、选项按钮（批准类的先过本机验证，拒绝直接发）；
///   还没对上审批记录的不能直接决定，给“在审批中心查看”。
/// - 已决：结论（你批准了 / 你拒绝了 / 按预授权 / 已过期 / 已作废，`ApprovalOutcome`）。
/// - 卡片出现时查一次审批记录（`checkApproval`），状态以记录为准。
struct ApprovalCardView: View {
    let item: ConversationItem
    let card: ApprovalCard
    let model: ConversationModel

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let record = model.approvalRecord(for: card)
        Card {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: card.isPending ? "hand.raised" : "checkmark.shield")
                    .foregroundStyle(card.isPending ? Theme.warning : Theme.inkSecondary)
                    .accessibilityHidden(true)
                Text(ConversationText.approvalHeader(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
                if card.isPending, let record {
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        Text(ConversationText.approvalExpiry(record.expiresAt, now: context.date, language: language))
                            .typography(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            if let title = card.title ?? record?.title, !title.isEmpty {
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
                    .lineLimit(3)
            }
            if let resolution = card.resolution {
                outcome(resolution)
            } else {
                pendingActions
            }
            if let error = model.approvalErrors[item.id] {
                errorView(error)
            }
            if let approvalID = card.approvalID {
                Button {
                    router.open(.approval(approvalID))
                } label: {
                    Text(ConversationText.openApprovals(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: Metrics.minTapTarget)
                }
                .buttonStyle(.plain)
            }
        }
        .task { await model.checkApproval(card) }
    }

    /// 工具调用的一句话摘要（命令、路径）。
    private var toolSummary: String? {
        guard let raw = card.toolCall else { return nil }
        let tool = ToolCallCard(
            toolCallID: raw["toolCallId"]?.stringValue ?? "", title: raw["title"]?.stringValue ?? "",
            kind: raw["kind"]?.stringValue, raw: raw)
        return ToolCallPresentation(tool, language: language).summary
    }

    @ViewBuilder
    private var pendingActions: some View {
        let deciding = model.decidingApprovals.contains(item.id)
        if card.approvalID == nil {
            HStack(spacing: Metrics.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(ConversationText.approvalLinking(language))
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: Metrics.Spacing.xs) {
                ForEach(card.options) { option in
                    PillButton(
                        option.name.isEmpty
                            ? ConversationText.approvalOptionName(option.kind, language: language) : option.name,
                        systemImage: option.kind.isAllow ? "checkmark" : "xmark",
                        kind: option.id == primaryOptionID ? .primary : .secondary
                    ) {
                        Task {
                            await model.decide(
                                item, option: option,
                                reason: ConversationText.verificationReason(title: card.title, language: language))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(deciding)
                }
            }
            .overlay {
                if deciding { ProgressView() }
            }
        }
    }

    /// 第一个批准类的选项是主按钮。
    private var primaryOptionID: String? {
        card.options.first { $0.kind.isAllow }?.id
    }

    private func outcome(_ resolution: ApprovalCard.Resolution) -> some View {
        let outcome = resolution.outcome
        let (symbol, color): (String, Color) =
            switch outcome {
            case .approvedByUser, .approvedByPolicy: ("checkmark.circle.fill", Theme.success)
            case .rejectedByUser, .rejectedByPolicy: ("xmark.circle.fill", Theme.danger)
            case .expired: ("clock.badge.xmark", Theme.inkTertiary)
            case .cancelled: ("minus.circle", Theme.inkTertiary)
            }
        return HStack(spacing: Metrics.Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(ConversationText.approvalOutcome(outcome, optionName: resolution.optionName, language: language))
                .typography(.subheadline)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func errorView(_ error: ConversationActionError) -> some View {
        switch error {
        case .client(let failure):
            ErrorBanner(failure, onDismiss: { model.clearApprovalError(item.id) })
        case .verificationFailed:
            NoticeText(text: ConversationText.verificationFailed(language), tone: .failure)
        case .notLinked:
            NoticeText(text: ConversationText.approvalNotLinked(language), tone: .waiting)
        }
    }
}

/// 一句带色调图标的提示（卡片里的行内提示）。
struct NoticeText: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
            Image(systemName: tone == .failure ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .typography(.footnote)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 保险箱填写请求卡片：agent 要的账号密码，填好只进保险箱（agent 只拿到名字）；也可以拒绝。已处理的显示结果。
struct VaultRequestCardView: View {
    let card: VaultRequestCard
    let model: ConversationModel

    @Environment(\.displayLanguage) private var language
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        let status = model.vaultStatus(for: card)
        let record = model.vaultRecord(for: card)
        let fields = card.fields.isEmpty ? (record?.fields ?? [.username, .password]) : card.fields
        let busy = model.busyVaultRequests.contains(card.requestID)
        Card {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: "key")
                    .foregroundStyle(status == .pending ? Theme.warning : Theme.inkSecondary)
                    .accessibilityHidden(true)
                Text(ConversationText.vaultRequestHeader(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
            Text(ConversationText.vaultItemName(card.name, language: language))
                .typography(.headline)
                .foregroundStyle(Theme.ink)
            let purpose = card.purpose.isEmpty ? (record?.purpose ?? "") : card.purpose
            if !purpose.isEmpty {
                Text(verbatim: purpose)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                AIGeneratedLabel()
            }
            if status == .pending {
                if fields.contains(.username) {
                    TextField(ConversationText.vaultField(.username, language: language), text: $username)
                        .textFieldStyle(.plain)
                        .vaultFieldStyle()
                        .usernameContentType()
                }
                SecureField(ConversationText.vaultField(.password, language: language), text: $password)
                    .textFieldStyle(.plain)
                    .vaultFieldStyle()
                    .passwordContentType()
                Text(ConversationText.vaultRequestNote(language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                HStack(spacing: Metrics.Spacing.xs) {
                    PillButton(ConversationText.vaultFulfill(language), systemImage: "lock", size: .compact) {
                        Task {
                            if await model.fulfillVaultRequest(card.requestID, username: username, password: password) {
                                password = ""
                            }
                        }
                    }
                    .disabled(password.isEmpty || busy)
                    PillButton(ConversationText.vaultDecline(language), kind: .secondary, size: .compact) {
                        Task { await model.declineVaultRequest(card.requestID) }
                    }
                    .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            } else {
                NoticeText(
                    text: ConversationText.vaultStatus(status, name: record?.name ?? card.name, language: language),
                    tone: status == .fulfilled ? .success : .muted)
            }
            if let error = model.vaultErrors[card.requestID] {
                ErrorBanner(error, onDismiss: { model.clearVaultError(card.requestID) })
            }
        }
    }
}

extension View {
    /// 卡片里的输入框：圆角、底色、一像素描边。
    func vaultFieldStyle() -> some View {
        modifier(VaultFieldStyle())
    }

    /// 账号输入框（系统的密码自动填充）。
    func usernameContentType() -> some View {
        textContentType(.username)
    }

    /// 密码输入框（系统的密码自动填充）。
    func passwordContentType() -> some View {
        textContentType(.password)
    }
}

private struct VaultFieldStyle: ViewModifier {
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        content
            .typography(.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .background(Theme.paper, in: shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
    }
}

#Preview("审批、保险箱卡片 · 浅色中文") {
    ConversationCardsPreview(instanceID: DemoData.writerID)
        .previewShell()
}

#Preview("审批、保险箱卡片 · 深色英文") {
    ConversationCardsPreview(instanceID: DemoData.reviewerID)
        .previewShell(.english, scheme: .dark)
}
