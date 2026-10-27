import SwiftUI
import ThinktinKit

/// 对话页底部的输入框：`ComposerBar`（胶囊、发送 / 停止 / 转圈的按钮、超限标红），外面加上 12.5 的规则：
///
/// - 有运行没结束、输入框是空的：发送键变成停止（`cancelRun`）；有字时照常发送，上面提示“前一个任务还在进行，新消息会排队”；
/// - 32000 字上限：快到时显示字数，超了标红、不能发；
/// - 发送前的密码拦截在视图模型里（`ConversationModel.send()`，命中时弹 `SecretInterceptionSheet`）；
/// - 发送、停止失败的错误显示在输入框上面（`ErrorBanner`）；
/// - 上面一行是默认模型的标签（`main` 路由的上游模型；没配时提示），点开去这个实例的模型路由（不能逐条消息换模型）。
struct ConversationComposer: View {
    @Bindable var model: ConversationModel
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    /// 点模型标签：去模型路由。
    let onOpenModelRoutes: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
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
            ComposerBar(
                text: $model.draft, placeholder: placeholder, action: barAction,
                actionLabel: ConversationText.composerActionLabel(model.composerAction, language: language),
                isOverLimit: model.isOverLimit, isDisabled: model.isMissing, focus: isFocused)
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
    private var barAction: ComposerBar.Action {
        switch model.composerAction {
        case .send: .send(isEnabled: model.canSend) { Task { await model.send() } }
        case .stop: .stop { Task { await model.stop() } }
        case .sending, .stopping: .busy
        }
    }
}
