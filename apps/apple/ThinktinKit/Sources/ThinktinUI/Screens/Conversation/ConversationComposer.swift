import SwiftUI
import ThinktinKit

/// 对话页底部浮动的输入区（规范 4.3.1，参考 02、07）：玻璃胶囊的 `ComposerBar`（有引用时长成卡片），正上方一行小玻璃胶囊：
/// 默认模型、排队提示、字数。外面加上 12.5 的规则：
///
/// - 有运行没结束、输入框是空的：发送键变成停止（`cancelRun`）；有字时照常发送，上面提示“前一个任务还在进行，新消息会排队”；
/// - 32000 字上限（引用块也算）：快到时显示字数，超了标红、不能发；
/// - 发送前的密码拦截在视图模型里（`ConversationModel.send()`，命中时弹 `SecretInterceptionSheet`）；
/// - 发送、停止失败的错误显示在输入框上面（`ErrorBanner`）；
/// - 默认模型的标签（`main` 路由的上游模型；没配时提示），点开去这个实例的模型路由（不能逐条消息换模型）；
/// - 引用回复（长按消息选“引用回复”，`ConversationModel.setQuote`）：输入框顶上一条引用，× 取消。
/// - 左边的“+”（规范 4.3.6，参考 08）：照片或视频、拍照（只有 iOS）、选择文件；上传要服务端（12.22），现在点了弹系统提示
///   “即将推出”（`ComposerAttachmentSource`）。
///
/// 自己不画底：iOS 26 浮在 `safeAreaBar` 里，内容从下面滚过去、边缘系统软渐隐；旧系统的 `safeAreaInset` 下，玻璃胶囊
/// （`.regularMaterial`）挡住后面滚过的内容。
struct ConversationComposer: View {
    @Bindable var model: ConversationModel
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    /// 点模型标签：去模型路由。
    let onOpenModelRoutes: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language
    /// 点了“+”菜单里还不能用的一项：弹“即将推出”。
    @State private var comingSoon: ComposerAttachmentSource?

    /// “+”菜单里的几项（Mac 没有拍照）。
    static var attachmentSources: [ComposerAttachmentSource] {
        #if os(iOS)
            ComposerAttachmentSource.menu(hasCamera: true)
        #else
            ComposerAttachmentSource.menu(hasCamera: false)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let error = model.sendError {
                ErrorBanner(error, onRetry: { Task { await model.send() } }, onDismiss: { model.clearSendError() })
            }
            if let error = model.stopError {
                ErrorBanner(error, onRetry: { Task { await model.stop() } }, onDismiss: { model.clearStopError() })
            }
            if model.isOverLimit {
                ComposerChip(text: ConversationText.overLimit(language), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.danger)
            } else if model.willQueue && model.promptLength > 0 {
                ComposerChip(text: ConversationText.queueHint(language), systemImage: "clock")
                    .foregroundStyle(Theme.inkSecondary)
            }
            accessoryRow
            ComposerBar(
                text: $model.draft, placeholder: placeholder, action: barAction,
                actionLabel: ConversationText.composerActionLabel(model.composerAction, language: language),
                isOverLimit: model.isOverLimit, isDisabled: model.isMissing, focus: isFocused,
                quote: model.quotedText, onRemoveQuote: { model.clearQuote() },
                attachments: model.canAttach ? Self.attachmentSources : [], onAttach: { comingSoon = $0 })
        }
        // 参考 02：胶囊离屏幕两边约 31pt（比气泡的 16pt 缩进得多），底边几乎贴着安全区。
        .padding(.horizontal, Metrics.Spacing.xxl)
        .padding(.top, Metrics.Spacing.xs)
        // 离底边留 16pt（用户 2026-11-06：输入框太靠下，贴着主屏指示条）。
        .padding(.bottom, Metrics.Spacing.m)
        .frame(maxWidth: Metrics.readableWidth)
        .frame(maxWidth: .infinity)
        .alert(
            ConversationText.comingSoon(language),
            isPresented: Binding(get: { comingSoon != nil }, set: { if !$0 { comingSoon = nil } }),
            presenting: comingSoon
        ) { _ in
            Button(ConversationText.ok(language)) { comingSoon = nil }
        } message: { source in
            Text(ConversationText.attachmentComingSoon(source, language: language))
        }
    }

    /// 输入框正上方一行：左边默认模型的小胶囊，右边快到上限时的字数（超了标红）。都没有时不占地方。
    @ViewBuilder
    private var accessoryRow: some View {
        let label = ConversationText.modelLabel(model.mainRoute, language: language)
        if label != nil || model.showsLengthCounter {
            HStack(spacing: Metrics.Spacing.xs) {
                modelLabel
                Spacer(minLength: 0)
                if model.showsLengthCounter {
                    Text(ConversationText.lengthCounter(model.promptLength, language: language))
                        .typography(.caption)
                        .monospacedDigit()
                        .foregroundStyle(model.isOverLimit ? Theme.danger : Theme.inkSecondary)
                        .padding(.horizontal, Metrics.Spacing.s)
                        .frame(minHeight: ComposerChip.height)
                        .glassBackground()
                }
            }
        }
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
                .frame(minHeight: ComposerChip.height)
                .glassBackground(interactive: true)
                // 小胶囊只有 28pt 高，点按区域撑到 44。
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

/// 输入框上方的一个小玻璃胶囊（排队提示、超限提示）：图标 + 小字，能换行。
private struct ComposerChip: View {
    static let height: CGFloat = 28

    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .typography(.caption)
        .padding(.horizontal, Metrics.Spacing.s)
        .padding(.vertical, Metrics.Spacing.xxs)
        .frame(minHeight: Self.height)
        .glassBackground(in: RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
