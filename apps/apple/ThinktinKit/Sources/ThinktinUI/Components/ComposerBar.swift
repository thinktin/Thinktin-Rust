import SwiftUI

/// 底部输入框：圆角 24 的大胶囊，左边多行文字（最多长到 6 行），右边强调色的圆形发送按钮。
///
/// 现在只有外观和“有字才能发”的规则；停止按钮、排队提示、32000 字上限、发送前的密码拦截在 12.5 加。
/// `onSend` 为 nil 时发送按钮一直置灰（欢迎页的占位）。
public struct ComposerBar: View {
    @Binding private var text: String
    private let placeholder: String
    private let onSend: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    /// - Parameters:
    ///   - text: 输入的文字。
    ///   - placeholder: 占位文字（已经按界面语言取好的）。
    ///   - onSend: 点发送时调用；调用方负责清空 `text`。
    public init(text: Binding<String>, placeholder: String, onSend: (@MainActor () -> Void)? = nil) {
        _text = text
        self.placeholder = placeholder
        self.onSend = onSend
    }

    /// 有非空白的文字、并且接了 `onSend` 才能发。
    var canSend: Bool {
        onSend != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.input, style: .continuous)
        HStack(alignment: .bottom, spacing: Metrics.Spacing.xs) {
            TextField(
                placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(Theme.inkTertiary),
                axis: .vertical
            )
            .lineLimit(1...6)
            .typography(.body)
            .foregroundStyle(Theme.ink)
            .tint(Theme.accent)
            .textFieldStyle(.plain)
            // 单行时和发送按钮一样高、文字垂直居中；多行时往上长，发送按钮留在底部。
            .frame(minHeight: Metrics.iconButton)

            sendButton
        }
        .padding(.leading, Metrics.Spacing.l)
        .padding(.trailing, Metrics.Spacing.xs)
        .padding(.vertical, Metrics.Spacing.xs)
        .background(Theme.paperElevated, in: shape)
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
    }

    private var sendButton: some View {
        Button {
            onSend?()
        } label: {
            Image(systemName: "arrow.up")
                .font(Typography.body.font.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .background(canSend ? Theme.accent : Theme.inkTertiary.opacity(0.5), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(Text(language == .chinese ? "发送" : "Send"))
    }
}

#Preview("输入框") {
    VStack(spacing: Metrics.Spacing.m) {
        ComposerBar(text: .constant(""), placeholder: "给 agent 布置一个任务")
        ComposerBar(text: .constant("帮我把上周的提交整理成周报，发到飞书群。"), placeholder: "给 agent 布置一个任务") {}
    }
    .padding()
    .background(Theme.paper)
}

#Preview("输入框 · 深色") {
    ComposerBar(text: .constant(""), placeholder: "Give an agent a task") {}
        .padding()
        .background(Theme.paper)
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
