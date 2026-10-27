import SwiftUI

/// 卡片：圆角 16 的容器（工具调用、审批、产出物、计划……）。不用阴影分层，靠底色对比和一像素的描边。
///
/// ```swift
/// Card {
///     Text("每周周报").typography(.headline)
///     Text("每周一 09:00").typography(.subheadline)
/// }
/// ```
public struct Card<Content: View>: View {
    /// 卡片的底色。
    public enum Background: Hashable, Sendable {
        /// `paperElevated`：普通卡片。
        case elevated
        /// `userBubble`：用户消息。
        case bubble
    }

    private let background: Background
    private let padding: CGFloat
    private let bordered: Bool
    private let content: Content

    @Environment(\.displayScale) private var displayScale

    /// - Parameters:
    ///   - background: 底色。
    ///   - padding: 内边距。
    ///   - bordered: 画一像素的描边（`hairline`）。用户消息卡片不画。
    public init(
        background: Background = .elevated, padding: CGFloat = Metrics.Spacing.m, bordered: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.padding = padding
        self.bordered = bordered
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: shape)
        .overlay {
            if bordered {
                shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale))
            }
        }
    }

    private var fill: Color {
        switch background {
        case .elevated: Theme.paperElevated
        case .bubble: Theme.userBubble
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
    }
}

#Preview("卡片") {
    VStack(spacing: Metrics.Spacing.m) {
        Card {
            Text("每周周报").typography(.headline).foregroundStyle(Theme.ink)
            Text("每周一 09:00 · 下次 10月27日").typography(.subheadline).foregroundStyle(Theme.inkSecondary)
        }
        Card(background: .bubble, bordered: false) {
            Text("帮我把上周的提交整理成周报。").typography(.body).foregroundStyle(Theme.ink)
        }
    }
    .padding()
    .background(Theme.paper)
}

#Preview("卡片 · 深色") {
    Card {
        Text("产出物：周报.md").typography(.headline).foregroundStyle(Theme.ink)
        Text("v2 · 12 KB").typography(.footnote).foregroundStyle(Theme.inkSecondary)
    }
    .padding()
    .background(Theme.paper)
    .preferredColorScheme(.dark)
}
