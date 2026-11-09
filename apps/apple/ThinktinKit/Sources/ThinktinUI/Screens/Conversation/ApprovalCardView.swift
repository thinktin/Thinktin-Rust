import SwiftUI
import ThinktinKit

/// 内嵌的审批卡片（运行详情头部下面、“只看本次过程”的时间线里；12.15 的审批中心做完整的列表和详情）。对话页 2026-11-06 起
/// 不放（用户定的“参考里没有的删掉”，`ConversationItem.Content.showsInConversation`），在对话里不能直接批：去审批中心、通知、
/// 运行详情。
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
        BubbleCard {
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 点按区域照样 44pt 高，但不占版面：往上伸到和上一项的间距（8）为止、往下伸进卡片的内边距（12），字上下就
                // 和卡片顶上一样宽（不然字下面空出约 30pt，卡片头轻脚重，2026-11-05 对截图）。
                .padding(.top, -Metrics.Spacing.xs)
                .padding(.bottom, -Metrics.Spacing.s)
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
                    Button {
                        Task {
                            await model.decide(
                                item, option: option,
                                reason: ConversationText.verificationReason(title: card.title, language: language))
                        }
                    } label: {
                        ApprovalOptionLabel(option: option, prominent: option.id == primaryOptionID)
                    }
                    .glassButtonStyle(option.id == primaryOptionID ? .prominent : .regular)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
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

/// 审批选项按钮上的字（运行详情里的审批卡片、审批中心和详情页共用）：勾 / 叉 + 选项名，撑满按钮的宽。自己排、不用 `Label`：
/// 放进 `List` 的行里时，系统把 `Label` 的图标挪到行首那一栏、涂成强调色——突出的“允许一次”上就是橙底橙勾，看不见，
/// 别的选项图标和字也隔得很开（2026-11-05 对截图）。图标跟着按钮的前景色（突出的按钮上是白的），读屏只念名字。
struct ApprovalOptionLabel: View {
    let option: ApprovalOption
    /// 放在突出的（强调色填充的）胶囊里：图标再显式写成白色。只靠按钮的前景色时，`List` 行里的图标一旦被染成强调色就和底色
    /// 一样看不见（2026-11-05 审查又提了一次审批中心的“允许一次”），写死了不怕行的 tint。
    var prominent = false

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(spacing: Metrics.Spacing.xs) {
            let icon = Image(systemName: option.kind.isReject ? "xmark" : "checkmark")
            if prominent {
                icon
                    .foregroundStyle(Theme.onAccent)
                    .accessibilityHidden(true)
            } else {
                icon
                    .accessibilityHidden(true)
            }
            Text(
                verbatim: option.name.isEmpty
                    ? ConversationText.approvalOptionName(option.kind, language: language) : option.name)
        }
        .frame(maxWidth: .infinity)
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
        BubbleCard {
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
                    Button {
                        Task {
                            if await model.fulfillVaultRequest(card.requestID, username: username, password: password) {
                                password = ""
                            }
                        }
                    } label: {
                        Label(ConversationText.vaultFulfill(language), systemImage: "lock")
                    }
                    .smallCapsuleButton(.prominent)
                    .disabled(password.isEmpty || busy)
                    Button(ConversationText.vaultDecline(language)) {
                        Task { await model.declineVaultRequest(card.requestID) }
                    }
                    .smallCapsuleButton()
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
    /// 卡片里的输入框：圆角、比卡片深一档的底色（不画描边，规范 2.1）。
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
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        content
            .typography(.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .background(Theme.paper, in: shape)
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
