import SwiftUI
import ThinktinKit

/// 工具调用卡片（agent 自己的工具、平台工具）：种类图标、标题（agent 写的，带“AI 生成”标识）、一句话摘要、状态；
/// 点开看参数和结果（等宽字体）。
struct ToolCallCardView: View {
    let card: ToolCallCard

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale
    @State private var isExpanded = false

    var body: some View {
        let p = ToolCallPresentation(card, language: language)
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.s) {
                    Image(systemName: Self.symbol(for: card))
                        .typography(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.Spacing.l)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
                        Text(verbatim: p.title)
                            .typography(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: Metrics.Spacing.xs) {
                            Text(p.kindName)
                            if let summary = p.summary {
                                Text(verbatim: summary)
                                    .font(Typography.caption.monospacedFont)
                                    .lineLimit(1)
                            }
                        }
                        .typography(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    ToolStatusIcon(status: card.status)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(p.statusName ?? ""))
            .accessibilityHint(
                Text(isExpanded ? ConversationText.hideDetails(language) : ConversationText.showDetails(language)))
            if ToolCallPresentation.isAIGenerated(card) {
                AIGeneratedLabel()
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
                    if let input = p.input {
                        DetailSection(title: ConversationText.toolInput(language), text: input)
                    }
                    if let output = p.output {
                        DetailSection(title: ConversationText.toolOutput(language), text: output)
                    }
                    if p.input == nil && p.output == nil, let raw = card.raw?.prettyPrinted(), !raw.isEmpty {
                        DetailSection(title: ConversationText.toolRaw(language), text: raw)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(Metrics.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paperElevated, in: shape)
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
    }

    /// 种类图标（ACP 的 tool kind、平台工具的类别）。
    static func symbol(for card: ToolCallCard) -> String {
        if let category = card.platformCategory {
            switch category {
            case .plan: return "calendar.badge.clock"
            case .artifact: return "doc.richtext"
            case .delegate: return "person.2"
            case .vault: return "key"
            case .computer: return "desktopcomputer"
            case .other: return "square.grid.2x2"
            }
        }
        switch card.kind ?? "" {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "brain"
        case "fetch": return "globe"
        case "switch_mode": return "arrow.triangle.swap"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// 工具调用的状态图标：等待中、进行中（转圈）、完成、失败；平台工具没有状态。
struct ToolStatusIcon: View {
    let status: ToolCallStatus?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let name = ConversationText.toolStatusName(status, language: language)
        switch status {
        case .inProgress?:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text(name))
        case .pending?:
            Image(systemName: "clock")
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityLabel(Text(name))
        case .completed?:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .accessibilityLabel(Text(name))
        case .failed?:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.danger)
                .accessibilityLabel(Text(name))
        case .unknown?, nil:
            EmptyView()
        }
    }
}

/// 展开后的一段详情：小标题加等宽的原文（横向可以滚，最多显示 30 行）。
struct DetailSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(title)
                .typography(.caption)
                .foregroundStyle(Theme.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(Typography.caption.monospacedFont)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(30)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(Metrics.Spacing.xs)
            }
            .background(
                Theme.userBubble.opacity(0.6),
                in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous))
        }
    }
}

/// agent 的待办清单：每项的状态，完成了几项，带“AI 生成”标识；长按复制、分享、举报（和 agent 的回复一样）。
struct AgentPlanCardView: View {
    let card: AgentPlanCard
    /// 时间线里的那一项（举报用它的事件序号）；预览里没有。
    var item: ConversationItem?
    var onReport: (ContentReportTarget) -> Void = { _ in }

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Card(padding: Metrics.Spacing.s) {
            HStack(spacing: Metrics.Spacing.xs) {
                Image(systemName: "checklist")
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
                Text(ConversationText.agentPlanTitle(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text(
                    ConversationText.agentPlanProgress(
                        done: card.completedCount, total: card.entries.count, language: language)
                )
                .typography(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
            }
            ForEach(Array(card.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                    Image(systemName: Self.symbol(entry.status))
                        .foregroundStyle(Self.color(entry.status))
                        .accessibilityHidden(true)
                    Text(verbatim: entry.content)
                        .typography(.subheadline)
                        .foregroundStyle(entry.status == .completed ? Theme.inkSecondary : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(ConversationText.agentPlanEntryStatus(entry.status, language: language)))
            }
            if card.isAIGenerated { AIGeneratedLabel() }
        }
        .contextMenu {
            MessageMenu(text: card.plainText, target: reportTarget, onReport: onReport)
        }
        .messageAccessibilityActions(text: card.plainText, target: reportTarget, onReport: onReport)
    }

    private var reportTarget: ContentReportTarget? {
        item.flatMap(ContentReportTarget.init(item:))
    }

    static func symbol(_ status: ToolCallStatus?) -> String {
        switch status {
        case .completed?: "checkmark.circle.fill"
        case .inProgress?: "circle.dotted"
        default: "circle"
        }
    }

    static func color(_ status: ToolCallStatus?) -> Color {
        switch status {
        case .completed?: Theme.success
        case .inProgress?: Theme.accent
        default: Theme.inkTertiary
        }
    }
}

#Preview("工具调用 · 浅色中文") {
    ScrollView {
        VStack(spacing: Metrics.Spacing.s) {
            ForEach(ConversationPreviewData.toolCards, id: \.toolCallID) { card in
                ToolCallCardView(card: card)
            }
            AgentPlanCardView(card: ConversationPreviewData.agentPlan)
        }
        .padding()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .chinese)
}

#Preview("工具调用 · 深色英文") {
    ScrollView {
        VStack(spacing: Metrics.Spacing.s) {
            ForEach(ConversationPreviewData.toolCards, id: \.toolCallID) { card in
                ToolCallCardView(card: card)
            }
            AgentPlanCardView(card: ConversationPreviewData.agentPlan)
        }
        .padding()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
