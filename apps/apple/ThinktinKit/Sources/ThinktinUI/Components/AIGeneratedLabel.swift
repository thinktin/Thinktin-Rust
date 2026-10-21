import SwiftUI
import ThinktinKit

/// “AI 生成” / “AI-generated” 标识（合规要求，WBS 16.3）：agent 的回复、思考、待办清单、产出物上都要带，
/// 复制分享时也带上（文字和服务端 `proto::labels::explicit_label` 一致，取自 `DisplayLanguage.aiGeneratedLabel`）。
///
/// 是显式标识：文字始终可见、不截断，读屏会读出来，不要用 `.accessibilityHidden` 藏掉。
public struct AIGeneratedLabel: View {
    @Environment(\.displayLanguage) private var language

    public init() {}

    public var body: some View {
        let text = language.aiGeneratedLabel
        HStack(spacing: Metrics.Spacing.xxs) {
            Image(systemName: "sparkles")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
        }
        .typography(.caption2)
        .foregroundStyle(Theme.inkSecondary)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Metrics.Spacing.xs)
        // 标签很小，上下只留半个单位。
        .padding(.vertical, Metrics.Spacing.unit / 2)
        .overlay {
            // 一个点宽（不是一像素）：标签小，细线看不清。
            Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

#Preview("AI 生成标识") {
    VStack(alignment: .leading, spacing: Metrics.Spacing.s) {
        Text("上周一共合并了 12 个提交，主要是事件流续传和缓存。").typography(.body).foregroundStyle(Theme.ink)
        AIGeneratedLabel()
        AIGeneratedLabel().environment(\.displayLanguage, .english)
    }
    .padding()
    .background(Theme.paper)
}

#Preview("AI 生成标识 · 深色") {
    AIGeneratedLabel()
        .padding()
        .background(Theme.paper)
        .preferredColorScheme(.dark)
}
