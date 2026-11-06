import SwiftUI
import ThinktinKit

/// 还没有任务的对话（规范 4.3.1、6.18 A，参考 118 的“新 Bot 首次欢迎与引导卡片”的版式）：
///
/// - 最上面居中的时间（Botin 的创建时间，和时间线的时间分隔一个样子）；
/// - 一个左边的灰气泡：App 的说明（“给 X 布置第一个任务……”），不是 Botin 说的，所以不带“AI 生成”标识；
/// - 一张同样宽的卡片（`ConversationModel.starter`）：没配默认模型时是“开始之前”+ 去配模型路由；配好了是“想让 X 先帮你做
///   什么？”和 A–D 四个示例任务，点一个放进输入框（`useSuggestion`，用户改一改再发），右上 × 收起；
/// - 卡片下面一行小灰字“也可以在下面直接写”。
///
/// 参考里是 Bot 自己发的欢迎语和结构化的选择题，ThinkTin 没有欢迎消息、也没有“agent 提问 + 选项”的事件，客户端自己画。
struct ConversationWelcome: View {
    let instanceName: String?
    /// Botin 的创建时间（时间行）；不知道时不画。
    let createdAt: Date?
    let starter: ConversationStarter?
    let onSuggestion: @MainActor (String) -> Void
    let onSetUp: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    @State private var isDismissed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            if let createdAt {
                TimeSeparatorView(text: ConversationTimeSeparator.label(createdAt, language: language))
                    .padding(.bottom, Metrics.Spacing.xs)
            }
            HStack(spacing: 0) {
                Text(verbatim: ConversationText.welcome(instanceName: instanceName, language: language))
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Spacing.m)
                    .padding(.vertical, Metrics.Spacing.s)
                    .background(Theme.agentBubble, in: messageBubbleShape)
                Spacer(minLength: messageBubbleGutter)
            }
            if let starter, !isDismissed {
                HStack(spacing: 0) {
                    card(starter)
                    Spacer(minLength: messageBubbleGutter)
                }
                .transition(.opacity)
                if starter == .suggestions {
                    Text(ConversationText.starterFooter(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.leading, Metrics.Spacing.m)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ starter: ConversationStarter) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.xs) {
                Text(title(starter))
                    .typography(.headline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(Typography.subheadline.font.weight(.medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ConversationText.starterDismiss(language)))
            }
            switch starter {
            case .suggestions:
                VStack(alignment: .leading, spacing: 0) {
                    let suggestions = ConversationText.starterSuggestions(language)
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, text in
                        SuggestionRow(letter: Self.letter(index), text: text) { onSuggestion(text) }
                    }
                }
            case .needsSetup:
                Text(ConversationText.setupNote(language))
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ConversationText.setupAction(language), action: onSetUp)
                    .smallCapsuleButton(.prominent)
            }
        }
        .padding(.leading, Metrics.Spacing.m)
        .padding(.trailing, Metrics.Spacing.xs)
        .padding(.vertical, Metrics.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.agentBubble, in: messageBubbleShape)
        .overlay { messageBubbleShape.strokeBorder(Theme.hairline, lineWidth: 1) }
    }

    private func title(_ starter: ConversationStarter) -> String {
        switch starter {
        case .suggestions: ConversationText.starterTitle(instanceName: instanceName, language: language)
        case .needsSetup: ConversationText.setupTitle(language)
        }
    }

    /// 选项前面的字母：A、B、C、D……
    static func letter(_ index: Int) -> String {
        let scalar = UnicodeScalar(UInt8(65 + max(0, min(25, index))))
        return String(Character(scalar))
    }
}

/// 示例任务的一行（参考 118）：左边带框的小方块写字母，右边是任务；整行能点。
private struct SuggestionRow: View {
    let letter: String
    let text: String
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Spacing.s) {
                Text(verbatim: letter)
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: Metrics.Spacing.xl, height: Metrics.Spacing.xl)
                    .background(
                        Theme.paper, in: RoundedRectangle(cornerRadius: Metrics.Spacing.xs, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.Spacing.xs, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .typography(.body)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityHint(Text(ConversationText.starterHint(language)))
    }
}

#Preview("第一次进来 · 浅色中文") {
    ScrollView {
        VStack(spacing: Metrics.Spacing.xl) {
            ConversationWelcome(
                instanceName: "写作助手", createdAt: Date(), starter: .suggestions, onSuggestion: { _ in }, onSetUp: {})
            ConversationWelcome(
                instanceName: "资料员", createdAt: nil, starter: .needsSetup, onSuggestion: { _ in }, onSetUp: {})
        }
        .padding()
    }
    .background(Theme.paper)
    .environment(\.displayLanguage, .chinese)
}

#Preview("第一次进来 · 深色英文") {
    ConversationWelcome(
        instanceName: "Writer", createdAt: Date(), starter: .suggestions, onSuggestion: { _ in }, onSetUp: {}
    )
    .padding()
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
