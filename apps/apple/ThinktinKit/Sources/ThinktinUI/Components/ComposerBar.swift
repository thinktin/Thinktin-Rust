import SwiftUI

/// 底部输入框：圆角 24 的大胶囊，左边多行文字（最多长到 6 行），右边圆形的按钮。
///
/// 按钮是 [`Action`]：发送（强调色，有非空白的文字才能点，也可以由调用方决定）、停止（墨色底的方块）、转圈（发送中、停止中）。
/// 超过字数上限时描边变成危险色（提示文字由调用方放在下面）。对话页（12.5）在它外面加错误、排队提示、模型标签和字数；
/// `onSend` 为 nil 时发送按钮一直置灰（欢迎页的占位）。
public struct ComposerBar: View {
    /// 右边的按钮。
    public enum Action {
        /// 发送。`isEnabled` 为 nil 时按“有非空白的文字”算；`perform` 为 nil 时一直置灰。
        case send(isEnabled: Bool? = nil, perform: (@MainActor () -> Void)?)
        /// 停止正在进行的运行（有运行没结束、输入框是空的时候）。
        case stop(perform: @MainActor () -> Void)
        /// 发送中、停止中：转圈，不能点。
        case busy
    }

    @Binding private var text: String
    private let placeholder: String
    private let action: Action
    private let actionLabel: String?
    private let isOverLimit: Bool
    private let isDisabled: Bool
    private let focus: FocusState<Bool>.Binding?

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    /// - Parameters:
    ///   - text: 输入的文字。
    ///   - placeholder: 占位文字（已经按界面语言取好的）。
    ///   - onSend: 点发送时调用；调用方负责清空 `text`。
    public init(text: Binding<String>, placeholder: String, onSend: (@MainActor () -> Void)? = nil) {
        self.init(text: text, placeholder: placeholder, action: .send(perform: onSend))
    }

    /// - Parameters:
    ///   - action: 右边的按钮。
    ///   - actionLabel: 按钮的读屏标签；nil 时按按钮种类给（发送、停止、正在处理）。
    ///   - isOverLimit: 超过字数上限（描边标红）。
    ///   - isDisabled: 不能输入（比如实例已经删了）。
    ///   - focus: 输入框的焦点（调用方要收起键盘、聚焦时传）。
    public init(
        text: Binding<String>, placeholder: String, action: Action, actionLabel: String? = nil,
        isOverLimit: Bool = false, isDisabled: Bool = false, focus: FocusState<Bool>.Binding? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.action = action
        self.actionLabel = actionLabel
        self.isOverLimit = isOverLimit
        self.isDisabled = isDisabled
        self.focus = focus
    }

    /// 发送按钮能不能点。
    var canSend: Bool {
        guard case .send(let isEnabled, let perform) = action, perform != nil, !isDisabled else { return false }
        return isEnabled ?? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            .modifier(OptionalFocus(binding: focus))
            // 单行时和按钮一样高、文字垂直居中；多行时往上长，按钮留在底部。
            .frame(minHeight: Metrics.iconButton)
            .disabled(isDisabled)

            actionButton
        }
        .padding(.leading, Metrics.Spacing.l)
        .padding(.trailing, Metrics.Spacing.xs)
        .padding(.vertical, Metrics.Spacing.xs)
        .background(Theme.paperElevated, in: shape)
        .overlay {
            shape.strokeBorder(
                isOverLimit ? Theme.danger : Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale))
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let zh = language == .chinese
        switch action {
        case .send(_, let perform):
            Button {
                perform?()
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
            .accessibilityLabel(Text(actionLabel ?? (zh ? "发送" : "Send")))
        case .stop(let perform):
            Button {
                perform()
            } label: {
                Image(systemName: "stop.fill")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.paperElevated)
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                    .background(Theme.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(actionLabel ?? (zh ? "停止" : "Stop")))
        case .busy:
            ProgressView()
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .accessibilityLabel(Text(actionLabel ?? (zh ? "正在处理" : "Working")))
        }
    }
}

/// 有焦点绑定时才加 `.focused`。
private struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}

#Preview("输入框") {
    VStack(spacing: Metrics.Spacing.m) {
        ComposerBar(text: .constant(""), placeholder: "给 agent 布置一个任务")
        ComposerBar(text: .constant("帮我把上周的提交整理成周报，发到飞书群。"), placeholder: "给 agent 布置一个任务") {}
        ComposerBar(text: .constant(""), placeholder: "给 agent 布置一个任务", action: .stop {})
        ComposerBar(text: .constant("太长了"), placeholder: "", action: .send(isEnabled: false) {}, isOverLimit: true)
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
