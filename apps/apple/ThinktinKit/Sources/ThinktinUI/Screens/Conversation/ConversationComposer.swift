import SwiftUI
import ThinktinKit

/// 对话页底部浮动的输入区（规范 4.3.1，参考 02、07）：玻璃胶囊的 `ComposerBar`（有引用时长成卡片）。平时上面什么都没有
/// （参考 02；以前左上角的默认模型小胶囊 2026-11-06 按用户定的“参考里没有的删掉”去掉了）。外面加上 12.5 的规则：
///
/// - 有运行没结束、输入框是空的：发送键变成停止（`cancelRun`）；有字时照常发送，上面提示“前一个任务还在进行，新消息会排队”；
/// - 32000 字上限（引用块也算）：快到时右上显示字数，超了标红、不能发；
/// - 发送前的密码拦截在视图模型里（`ConversationModel.send()`，命中时弹 `SecretInterceptionSheet`）；
/// - 发送、停止失败的错误显示在输入框上面（`ErrorBanner`）；
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
            lengthCounter
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

    /// 快到上限时输入框右上的字数（超了标红）；没到时不占地方。
    @ViewBuilder
    private var lengthCounter: some View {
        if model.showsLengthCounter {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
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
