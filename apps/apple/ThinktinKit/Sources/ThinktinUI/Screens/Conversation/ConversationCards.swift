import SwiftUI
import ThinktinKit

/// 产出物卡片：名字（agent 起的，带“AI 生成”标识）、版本和大小；点开去产出物详情（12.18：预览、分享、删除），长按举报。
struct ArtifactCardView: View {
    let item: ConversationItem
    let card: ArtifactCard
    let instanceID: InstanceID
    let onReport: (ContentReportTarget) -> Void

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        Button {
            // 卡片都在某个运行里；万一没有运行就去这个实例的产出物库。
            if let runID = item.runID {
                router.open(.artifact(card.artifactID, runID: runID))
            } else {
                router.open(.artifacts(instanceID: instanceID))
            }
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                Image(systemName: card.name.hasSuffix(".png") || card.name.hasSuffix(".jpg") ? "photo" : "doc.richtext")
                    .font(Typography.title3.font)
                    .foregroundStyle(Theme.accent)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .background(
                        Theme.userBubble, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: card.name)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(
                        ConversationText.artifactLabel(language) + " · "
                            + ConversationText.artifactMeta(version: card.version, size: card.size, language: language)
                    )
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    AIGeneratedLabel()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(Metrics.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let target = ContentReportTarget(item: item) {
                Button(role: .destructive) {
                    onReport(target)
                } label: {
                    Label(ConversationText.report(language), systemImage: "flag")
                }
            }
        }
    }
}

/// 子运行卡片（流水线的一步、委派给另一个实例）：点开去运行树。委派的标题是 agent 写的，带标识。
struct ChildRunCardView: View {
    let card: ChildRunCard

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let isDelegate: Bool = {
            if case .delegate = card.origin { return true }
            return false
        }()
        Button {
            router.open(.runTree(card.runID))
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                Image(systemName: isDelegate ? "person.2" : "arrow.triangle.branch")
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Metrics.Spacing.l)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(ConversationText.childRunTitle(card.origin, language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    Text(verbatim: card.title)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if isDelegate && AIGeneratedField.delegateTitle.isAIGenerated { AIGeneratedLabel() }
                }
                Spacer(minLength: 0)
                Text(ConversationText.openRunTree(language))
                    .typography(.caption)
                    .foregroundStyle(Theme.accent)
            }
            .padding(Metrics.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// agent 对计划的改动：新建 / 修改了等确认（跳到计划确认页），取消了（跳到计划）。计划标题是 agent 写的，带标识。
struct PlanActivityCardView: View {
    let card: PlanActivityCard

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        let needsConfirmation: Bool = {
            if case .needsConfirmation = card.activity { return true }
            return false
        }()
        Button {
            router.open(needsConfirmation ? .confirmPlan(card.planID) : .plan(card.planID))
        } label: {
            HStack(spacing: Metrics.Spacing.s) {
                Image(systemName: needsConfirmation ? "calendar.badge.exclamationmark" : "calendar.badge.minus")
                    .foregroundStyle(needsConfirmation ? Theme.warning : Theme.inkSecondary)
                    .frame(width: Metrics.Spacing.l)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(ConversationText.planActivity(card.activity, language: language))
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    Text(verbatim: card.title)
                        .typography(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    AIGeneratedLabel()
                }
                Spacer(minLength: 0)
                Text(needsConfirmation ? ConversationText.confirmPlan(language) : ConversationText.viewPlan(language))
                    .typography(.caption)
                    .foregroundStyle(Theme.accent)
            }
            .padding(Metrics.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 系统提示行（灰色小字，agent 出错用危险色）。英文原文（给开发者看的）放进可以展开的详情。
struct SystemNoticeView: View {
    let notice: SystemNotice

    @Environment(\.displayLanguage) private var language
    @State private var showsDetails = false

    var body: some View {
        let isError = notice.kind == .agentError
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                Image(systemName: Self.symbol(notice.kind))
                    .imageScale(.small)
                    .foregroundStyle(isError ? Theme.danger : Theme.inkTertiary)
                    .accessibilityHidden(true)
                Text(ConversationText.systemNotice(notice.kind, language: language))
                    .typography(.footnote)
                    .foregroundStyle(isError ? Theme.danger : Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = notice.message, !message.isEmpty {
                    Button {
                        showsDetails.toggle()
                    } label: {
                        Text(
                            showsDetails
                                ? ConversationText.hideDetails(language) : ConversationText.showDetails(language)
                        )
                        .typography(.footnote)
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if showsDetails, let message = notice.message {
                Text(verbatim: message)
                    .font(Typography.caption.monospacedFont)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func symbol(_ kind: SystemNotice.Kind) -> String {
        switch kind {
        case .agentError: "exclamationmark.triangle"
        case .sessionLost: "arrow.uturn.backward"
        case .agentExited: "power"
        case .logTruncated: "scissors"
        case .vaultUsed: "key"
        case .turnStopped: "stop.circle"
        }
    }
}

/// 运行状态行：状态点、本地化的主文案、说明；等待类状态给一键跳转（去审批、去处理 key、看运行树），失败、取消的
/// 给“重试”（`onRetry` 不为 nil 时）。点主文案进运行详情。agent 写的审批标题、英文诊断放进可以展开的详情
/// （`RunStatusPresentation`）。
struct RunStatusLineView: View {
    let runID: RunID?
    let line: RunStatusLine
    let instanceState: InstanceState?
    let onAction: (RunStatusAction) -> Void
    var onRetry: (@MainActor () -> Void)? = nil

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language
    @State private var showsReason = false

    var body: some View {
        let p = RunStatusPresentation(line: line, instanceState: instanceState, language: language)
        let tone = line.state.statusAppearance.tone
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            HStack(alignment: .center, spacing: Metrics.Spacing.xs) {
                Button {
                    if let runID { router.open(.run(runID)) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                        StatusDot(line.state)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.headline)
                                .font(Typography.footnote.font.weight(.medium))
                                .foregroundStyle(tone == .neutral || tone == .muted ? Theme.inkSecondary : tone.color)
                                .multilineTextAlignment(.leading)
                            if let detail = p.detail {
                                Text(verbatim: detail)
                                    .typography(.caption)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(language == .chinese ? "打开运行详情" : "Opens run details"))
                Spacer(minLength: 0)
                if let action = p.action, let title = p.actionTitle {
                    Button(title) { onAction(action) }
                        .smallCapsuleButton()
                }
                if let onRetry {
                    Button(action: onRetry) {
                        Label(ConversationText.retry(language), systemImage: "arrow.clockwise")
                    }
                    .smallCapsuleButton()
                }
                if p.reason != nil {
                    Button {
                        showsReason.toggle()
                    } label: {
                        Image(systemName: showsReason ? "chevron.up" : "info.circle")
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(
                            showsReason
                                ? ConversationText.hideDetails(language) : ConversationText.showDetails(language)))
                }
            }
            if showsReason, let reason = p.reason {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                    Text(verbatim: reason)
                        .font(p.reasonIsAIGenerated ? Typography.footnote.font : Typography.caption.monospacedFont)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if p.reasonIsAIGenerated { AIGeneratedLabel() }
                }
                .padding(.leading, Metrics.Spacing.l)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 计划、流水线、委派发起的运行上面的来源行（计划触发 · 标题）：居中的小灰字和图标（规范 4.3.1，参考 02 里通话记录那种
/// 居中的一行）。点开去计划；agent 建的计划带标识。
struct SourceHeaderView: View {
    let run: Run
    let plan: Plan?

    @Environment(Router.self) private var router
    @Environment(\.displayLanguage) private var language

    var body: some View {
        if let text = ConversationText.sourceHeader(
            source: run.source, planTitle: plan?.title, stepKey: run.stepKey, language: language)
        {
            HStack(spacing: Metrics.Spacing.xxs) {
                Image(systemName: Self.symbol(run.source))
                    .imageScale(.small)
                    .accessibilityHidden(true)
                if let planID = run.planID {
                    Button {
                        router.open(.plan(planID))
                    } label: {
                        Text(verbatim: text)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(verbatim: text)
                        .lineLimit(1)
                }
                if let plan, AIGeneratedField.planTitle(createdBy: plan.createdBy).isAIGenerated { AIGeneratedLabel() }
            }
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Metrics.Spacing.l)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    static func symbol(_ source: RunSource) -> String {
        switch source {
        case .plan: "calendar"
        case .pipeline: "arrow.triangle.branch"
        case .delegate: "person.2"
        case .user, .unknown: "person"
        }
    }
}

/// 没有过程记录的运行旁边的说明。
struct HistoryNoteView: View {
    let note: TurnHistoryNote

    @Environment(\.displayLanguage) private var language

    var body: some View {
        NoticeText(text: ConversationText.historyNote(note, language: language), tone: .muted)
    }
}

/// 没有过程记录的运行（超过保留期、本机没缓存）：说明，加上结果（`Run.summary`，agent 最后的回答，Markdown，画成和回复
/// 一样的灰气泡，下面带“AI 生成”标识）。长按结果：和回复一样（引用回复、复制、选择文本、复制运行 ID、分享、举报这次运行）。
struct HistoryRecordView: View {
    let note: TurnHistoryNote
    let summary: String?
    let runID: RunID?
    let onReport: (ContentReportTarget) -> Void
    var onQuote: (@MainActor (String) -> Void)? = nil
    /// 对话内查找的高亮（结果这一段）。
    var highlight: ConversationFindHighlight? = nil
    /// 表情回应（只在这台设备上）；nil 是这里不能回应。
    var reactions: [String]? = nil
    var onReact: (@MainActor (String) -> Void)? = nil

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            HistoryNoteView(note: note)
            if let summary {
                Text(ConversationText.resultLabel(language))
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.leading, Metrics.Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 0) {
                    MarkdownView(blocks: MarkdownParser.parse(summary), highlight: highlight)
                        .padding(.horizontal, Metrics.Spacing.m)
                        .padding(.vertical, Metrics.Spacing.s)
                        .background(Theme.agentBubble, in: messageBubbleShape)
                        .messageMenu(
                            .agentOutput(
                                summary, runID: runID, target: runID.map(ContentReportTarget.run), onReport: onReport,
                                onQuote: onQuote
                            )
                            .reacting(reactions ?? [], onReact: reactions == nil ? nil : onReact))
                    Spacer(minLength: messageBubbleGutter)
                }
                ReactionChips(reactions: reactions ?? [], alignment: .leading, onToggle: onReact)
                AIGeneratedLabel()
                    .padding(.leading, Metrics.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// 卡片、状态行里的小按钮（去审批、重试、保险箱的填好 / 拒绝）：系统按钮 + 玻璃样式 + 小胶囊（规范 2.6）。
    func smallCapsuleButton(_ prominence: GlassButtonProminence = .regular) -> some View {
        glassButtonStyle(prominence)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }

    /// 对话里卡片的底（规范 2.1、2.4，参考 118 的选择卡）：和 agent 气泡同一个灰（`agentBubble`）、圆角 20、不画描边
    /// （按钮包着的卡片用；`BubbleCard` 是同一个样子，自己会撑满宽度）。
    func cardSurface() -> some View {
        background(Theme.agentBubble, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }
}

#Preview("卡片与状态行 · 浅色中文") {
    ConversationCardsPreview(instanceID: DemoData.writerID, showsAll: true)
        .previewShell()
}

#Preview("卡片与状态行 · 深色英文") {
    ConversationCardsPreview(instanceID: DemoData.writerID, showsAll: true)
        .previewShell(.english, scheme: .dark)
}
