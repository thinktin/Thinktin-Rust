import SwiftUI
import ThinktinKit

/// 对话页底部浮动的输入框（规范 4.3.1、4.3.5，参考 02、07）：玻璃胶囊（高 48），左边多行文字（最多长到 6 行，往上长），
/// 右边圆形的主按钮；有引用时长成圆角 28 的卡片：上面一条引用（单行截断，右边 ×），中间输入，下面一行右边是主按钮。
///
/// 主按钮是 [`Action`]：发送（强调色的玻璃圆，有非空白的文字才能点，也可以由调用方决定）、停止（同样的圆，方块图标）、
/// 转圈（发送中、停止中）。超过字数上限时外沿描一圈危险色（提示文字由调用方放在上面）。
///
/// 左边的“+”（附件，规范 4.3.6，参考 03、08）：传了 `attachments` 才有，是系统 `Menu`（照片或视频、拍照、选择文件），
/// 选了哪项交给 `onAttach`（上传要服务端，现在对话页弹“即将推出”）；有引用的卡片里它在下面一行的左边（参考 07）。
/// 参考的麦克风和语音（6.23）ThinkTin 没有，不放。玻璃在 iOS 26 是 Liquid Glass，旧系统是 `.regularMaterial`
/// （`Design/Glass.swift`）。对话页（12.5）在它上面放错误、排队提示和字数；`onSend` 为 nil 时发送按钮一直置灰
/// （预览、占位）。
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

    /// 单行时的高度（参考 02 的胶囊约 48pt）；圆角取一半，单行正好是胶囊，多行时是圆角 24 的圆角矩形。
    static let height: CGFloat = 48
    /// 主按钮（圆）的直径。
    static let buttonSize: CGFloat = 36

    @Binding private var text: String
    private let placeholder: String
    private let action: Action
    private let actionLabel: String?
    private let isOverLimit: Bool
    private let isDisabled: Bool
    private let focus: FocusState<Bool>.Binding?
    private let quote: String?
    private let onRemoveQuote: (@MainActor () -> Void)?
    private let attachments: [ComposerAttachmentSource]
    private let onAttach: (@MainActor (ComposerAttachmentSource) -> Void)?

    @Environment(\.displayLanguage) private var language

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
    ///   - isOverLimit: 超过字数上限（外沿标红）。
    ///   - isDisabled: 不能输入（比如实例已经删了）。
    ///   - focus: 输入框的焦点（调用方要收起键盘、聚焦时传）。
    ///   - quote: 引用回复的原文（输入框长成卡片，上面一条引用）；nil 是普通的胶囊。
    ///   - onRemoveQuote: 点引用条上的 ×。
    ///   - attachments: 左边“+”菜单里的几项；空的不放“+”。
    ///   - onAttach: 选了“+”菜单里的一项。
    public init(
        text: Binding<String>, placeholder: String, action: Action, actionLabel: String? = nil,
        isOverLimit: Bool = false, isDisabled: Bool = false, focus: FocusState<Bool>.Binding? = nil,
        quote: String? = nil, onRemoveQuote: (@MainActor () -> Void)? = nil,
        attachments: [ComposerAttachmentSource] = [], onAttach: (@MainActor (ComposerAttachmentSource) -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.action = action
        self.actionLabel = actionLabel
        self.isOverLimit = isOverLimit
        self.isDisabled = isDisabled
        self.focus = focus
        self.quote = quote
        self.onRemoveQuote = onRemoveQuote
        self.attachments = attachments
        self.onAttach = onAttach
    }

    /// 左边有没有“+”。
    var showsAttachments: Bool { onAttach != nil && !attachments.isEmpty && !isDisabled }

    /// 发送按钮能不能点。
    var canSend: Bool {
        guard case .send(let isEnabled, let perform) = action, perform != nil, !isDisabled else { return false }
        return isEnabled ?? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 外形：单行是胶囊（圆角 = 高度的一半），有引用时是圆角 28 的卡片。
    var cornerRadius: CGFloat {
        quote == nil ? Self.height / 2 : Metrics.Radius.composerCard
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // 结构固定（引用条、输入行、卡片的按钮行都是可有可无的一项），切换引用时输入框不重建、不丢焦点。
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            if let quote {
                QuoteStrip(quote: quote, onRemove: onRemoveQuote)
            }
            HStack(alignment: .bottom, spacing: Metrics.Spacing.xs) {
                if quote == nil && showsAttachments { attachMenu }
                field
                if quote == nil { actionButton }
            }
            if quote != nil {
                HStack(spacing: 0) {
                    if showsAttachments { attachMenu }
                    Spacer(minLength: 0)
                    actionButton
                }
            }
        }
        .padding(
            .leading,
            quote == nil
                ? (showsAttachments ? (Self.height - Self.buttonSize) / 2 : Metrics.Spacing.m) : Metrics.Spacing.s
        )
        .padding(.trailing, quote == nil ? (Self.height - Self.buttonSize) / 2 : Metrics.Spacing.s)
        .padding(.vertical, quote == nil ? (Self.height - Self.buttonSize) / 2 : Metrics.Spacing.s)
        .frame(minHeight: Self.height)
        .glassBackground(in: shape)
        .overlay {
            if isOverLimit {
                shape.strokeBorder(Theme.danger, lineWidth: 1.5)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: quote == nil)
    }

    private var field: some View {
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
        .frame(minHeight: Self.buttonSize)
        .padding(.horizontal, quote == nil ? 0 : Metrics.Spacing.xxs)
        .disabled(isDisabled)
    }

    /// 左边的“+”：系统菜单，从按钮往上展开（参考 08）。
    private var attachMenu: some View {
        Menu {
            ForEach(attachments, id: \.self) { source in
                Button {
                    onAttach?(source)
                } label: {
                    Label(source.title(language), systemImage: source.systemImage)
                }
            }
        } label: {
            Label(ConversationText.attach(language), systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(Typography.body.font.weight(.medium))
                .frame(width: Self.buttonSize - 12, height: Self.buttonSize - 12)
        }
        .menuIndicator(.hidden)
        .glassButtonStyle(.regular)
        .buttonBorderShape(.circle)
    }

    @ViewBuilder
    private var actionButton: some View {
        let zh = language == .chinese
        switch action {
        case .send(_, let perform):
            CircleActionButton(
                title: actionLabel ?? (zh ? "发送" : "Send"), systemImage: "arrow.up", isEnabled: canSend
            ) {
                perform?()
            }
        case .stop(let perform):
            CircleActionButton(title: actionLabel ?? (zh ? "停止" : "Stop"), systemImage: "stop.fill", action: perform)
        case .busy:
            ProgressView()
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .accessibilityLabel(Text(actionLabel ?? (zh ? "正在处理" : "Working")))
        }
    }
}

/// 输入框右边的圆形主按钮：系统按钮 + 突出的玻璃样式（旧系统 `.borderedProminent`）+ 圆形，只显示图标。
private struct CircleActionButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(Typography.body.font.weight(.semibold))
                .frame(width: ComposerBar.buttonSize - 12, height: ComposerBar.buttonSize - 12)
        }
        .glassButtonStyle(.prominent)
        .buttonBorderShape(.circle)
        .disabled(!isEnabled)
    }
}

/// 输入卡片顶上那条引用（参考 07）：浅灰胶囊、一行截断，右边 ×。读屏念“引用：……”，× 是“取消引用”。
private struct QuoteStrip: View {
    let quote: String
    let onRemove: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: Metrics.Spacing.xxs) {
            Text(verbatim: MessageQuote.preview(quote))
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text(ConversationText.quoteAccessibility(quote, language: language)))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(Typography.footnote.font.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: Metrics.minTapTarget - 12, height: Metrics.minTapTarget - 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ConversationText.removeQuote(language)))
            }
        }
        .padding(.leading, Metrics.Spacing.s)
        .padding(.trailing, Metrics.Spacing.xxs)
        .frame(minHeight: Metrics.minTapTarget - 12)
        .background(Theme.inkTertiary.opacity(0.12), in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: Metrics.hairline(scale: displayScale)) }
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
        ComposerBar(text: .constant(""), placeholder: "给 Botin 布置一个任务")
        ComposerBar(
            text: .constant(""), placeholder: "给 Botin 布置一个任务", action: .send {},
            attachments: ComposerAttachmentSource.allCases, onAttach: { _ in })
        ComposerBar(
            text: .constant(""), placeholder: "给写作助手布置任务", action: .send {}, quote: "引用的一段", onRemoveQuote: {},
            attachments: ComposerAttachmentSource.allCases, onAttach: { _ in })
        ComposerBar(text: .constant("帮我把上周的提交整理成周报，发到飞书群。"), placeholder: "给 Botin 布置一个任务") {}
        ComposerBar(text: .constant(""), placeholder: "给 Botin 布置一个任务", action: .stop {})
        ComposerBar(
            text: .constant(""), placeholder: "给写作助手布置任务", action: .send {},
            quote: "我现在有一个只有你能看到的保险箱，可以存登录信息和卡片。", onRemoveQuote: {})
        ComposerBar(text: .constant("太长了"), placeholder: "", action: .send(isEnabled: false) {}, isOverLimit: true)
    }
    .padding()
    .background(Theme.paper)
}

#Preview("输入框 · 深色") {
    ComposerBar(text: .constant(""), placeholder: "Give a Botin a task") {}
        .padding()
        .background(Theme.paper)
        .environment(\.displayLanguage, .english)
        .preferredColorScheme(.dark)
}
