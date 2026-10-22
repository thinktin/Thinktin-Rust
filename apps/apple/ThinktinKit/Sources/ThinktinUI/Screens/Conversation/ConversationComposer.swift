import SwiftUI
import ThinktinKit

/// 对话页底部的输入框：和 `ComposerBar` 同样的胶囊外观（圆角 24、`paperElevated` 底、一像素描边、强调色的圆形发送键），
/// 加上 12.5 的规则：
///
/// - 有运行没结束、输入框是空的：发送键变成停止（`cancelRun`）；有字时照常发送，上面提示“前一个任务还在进行，新消息会排队”；
/// - 32000 字上限：快到时显示字数，超了标红、不能发；
/// - 发送前的密码拦截在视图模型里（`ConversationModel.send()`，命中时弹 `SecretInterceptionSheet`）；
/// - 发送、停止失败的错误显示在输入框上面（`ErrorBanner`）；
/// - 上面一行是默认模型的标签（`main` 路由的上游模型；没配时提示），点开去这个实例的模型路由（不能逐条消息换模型）。
///
/// `ComposerBar` 是 12.1 的公共组件，还没有停止键和排队提示；等它有了，这里换回去用它。
struct ConversationComposer: View {
    @Bindable var model: ConversationModel
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    /// 点模型标签：去模型路由。
    let onOpenModelRoutes: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.input, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let error = model.sendError {
                ErrorBanner(error, onRetry: { Task { await model.send() } }, onDismiss: { model.clearSendError() })
            }
            if let error = model.stopError {
                ErrorBanner(error, onRetry: { Task { await model.stop() } }, onDismiss: { model.clearStopError() })
            }
            if model.willQueue && model.promptLength > 0 {
                Label(ConversationText.queueHint(language), systemImage: "clock")
                    .typography(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, Metrics.Spacing.s)
            }
            modelLabel
            HStack(alignment: .bottom, spacing: Metrics.Spacing.xs) {
                TextField(
                    placeholder, text: $model.draft, prompt: Text(placeholder).foregroundStyle(Theme.inkTertiary),
                    axis: .vertical
                )
                .lineLimit(1...6)
                .typography(.body)
                .foregroundStyle(Theme.ink)
                .tint(Theme.accent)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .frame(minHeight: Metrics.iconButton)
                .disabled(model.isMissing)

                actionButton
            }
            .padding(.leading, Metrics.Spacing.l)
            .padding(.trailing, Metrics.Spacing.xs)
            .padding(.vertical, Metrics.Spacing.xs)
            .background(Theme.paperElevated, in: shape)
            .overlay {
                shape.strokeBorder(
                    model.isOverLimit ? Theme.danger : Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale))
            }
            if model.isOverLimit {
                Text(ConversationText.overLimit(language))
                    .typography(.caption)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, Metrics.Spacing.s)
            } else if model.showsLengthCounter {
                Text(ConversationText.lengthCounter(model.promptLength, language: language))
                    .typography(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, Metrics.Spacing.s)
            }
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.top, Metrics.Spacing.xs)
        .padding(.bottom, Metrics.Spacing.xs)
        .frame(maxWidth: Metrics.readableWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
    }

    /// 默认模型的标签：配了显示模型名，没配用警告色提示；还没拉到时不显示。
    @ViewBuilder
    private var modelLabel: some View {
        if let text = ConversationText.modelLabel(model.mainRoute, language: language) {
            let missing = model.mainRoute == .missing
            Button(action: onOpenModelRoutes) {
                HStack(spacing: Metrics.Spacing.xxs) {
                    Image(systemName: missing ? "exclamationmark.triangle" : "cpu")
                        .imageScale(.small)
                    Text(verbatim: text)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                }
                .typography(.caption)
                .foregroundStyle(missing ? Theme.warning : Theme.inkSecondary)
                .padding(.horizontal, Metrics.Spacing.s)
                .frame(minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(ConversationText.modelLabelAccessibility(model.mainRoute, language: language)))
            .accessibilityAddTraits(.isButton)
        }
    }

    /// 发送 / 停止 / 转圈。
    @ViewBuilder
    private var actionButton: some View {
        let action = model.composerAction
        let label = Text(ConversationText.composerActionLabel(action, language: language))
        switch action {
        case .send:
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(Typography.body.font.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                    .background(model.canSend ? Theme.accent : Theme.inkTertiary.opacity(0.5), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .accessibilityLabel(label)
        case .stop:
            Button {
                Task { await model.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.paperElevated)
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                    .background(Theme.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        case .sending, .stopping:
            ProgressView()
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .accessibilityLabel(label)
        }
    }
}
