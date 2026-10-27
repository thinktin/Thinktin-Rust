import SwiftUI
import ThinktinKit

// 模型 key、路由、用量（WBS 12.4）共用的小组件。名字都带 Models 前缀，不和别的功能重名。
// 分组、行、小标签、页头、加载中、提示条沿用 12.3 的 `GroupedSection`、`ListRow`、`TagChip`、`PageHeader`、
// `LoadingStateView`、`InlineNotice`，勾选框沿用 12.2 的 `CheckboxRow`、红字沿用 `FieldMessage`。

/// 表单里的一个输入框：上面一行小标题，输入框（普通、密码、标识、网址、数字），下面是问题（危险色）或提示。
struct ModelsField: View {
    enum Kind {
        /// 普通文字（备注）。
        case plain
        /// key：打码显示，不自动大写、不纠错。
        case secret
        /// 要原样提交的名字（上游模型名）：不自动大写、不纠错（厂商的模型名区分大小写，“Claude-…”会找不到）。
        case identifier
        /// 网址。
        case url
        /// 正整数（每日上限）。
        case number
    }

    let title: String
    let text: Binding<String>
    var prompt: String?
    var kind: Kind = .plain
    /// 问题（已经按界面语言取好的）；有问题时边框变成危险色。
    var problem: String?
    var hint: String?

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
            Text(title)
                .typography(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .font(kind == .secret ? Typography.body.monospacedFont : Typography.body.font)
                .foregroundStyle(Theme.ink)
                .autocorrectionDisabled(kind != .plain)
                .modelsKeyboard(kind)
                .padding(.horizontal, Metrics.Spacing.s)
                .frame(minHeight: Metrics.minTapTarget)
                .background(Theme.paperElevated, in: shape)
                .overlay {
                    shape.strokeBorder(
                        problem == nil ? Theme.hairline : StatusTone.failure.color,
                        lineWidth: Metrics.hairline(scale: displayScale))
                }
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(problem ?? hint ?? ""))
            if let problem {
                FieldMessage(text: problem)
                    .accessibilityHidden(true)
            } else if let hint {
                Text(hint)
                    .typography(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let placeholder = prompt.map { Text($0).foregroundStyle(Theme.inkTertiary) }
        switch kind {
        case .secret:
            SecureField(title, text: text, prompt: placeholder)
        case .plain, .identifier, .url, .number:
            TextField(title, text: text, prompt: placeholder)
        }
    }
}

extension View {
    /// 输入框的键盘：key、标识和网址不自动大写，网址用网址键盘，上限用数字键盘（iOS）。
    @ViewBuilder
    fileprivate func modelsKeyboard(_ kind: ModelsField.Kind) -> some View {
        #if canImport(UIKit)
            switch kind {
            case .plain: self
            case .secret, .identifier: self.textInputAutocapitalization(.never).keyboardType(.asciiCapable)
            case .url: self.textInputAutocapitalization(.never).keyboardType(.URL)
            case .number: self.keyboardType(.numberPad)
            }
        #else
            self
        #endif
    }

    /// 不在 `ModelsField` 里的输入框（弹窗里的别名）要原样提交时用：不自动大写、不纠错。
    func modelsIdentifierInput() -> some View {
        autocorrectionDisabled().modelsKeyboard(.identifier)
    }
}

/// key 列表里的一行：厂商的首字头像、名字、厂商和后 4 位，下面是停用、上限、协议的小标签。整行是按钮。
struct ModelsCredentialRow: View {
    let summary: CredentialSummary
    var action: (@MainActor () -> Void)?

    @Environment(\.displayLanguage) private var language

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(summary.accessibilityLabel(language)))
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(summary.accessibilityLabel(language)))
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Metrics.Spacing.s) {
            AgentMonogram(summary.monogram, style: .headline, size: 36)
                .opacity(summary.isDisabled ? 0.5 : 1)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(summary.name)
                    .typography(.body)
                    .foregroundStyle(summary.isDisabled ? Theme.inkSecondary : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary.subtitle)
                    .typography(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TagChipRow {
                    if summary.isDisabled { TagChip(text: summary.statusName) }
                    TagChip(text: summary.dailyLimit)
                    if let protocols = summary.protocols { TagChip(text: protocols) }
                }
                .padding(.top, Metrics.Spacing.xxs)
            }
            Spacer(minLength: Metrics.Spacing.xs)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.Spacing.m)
        .padding(.vertical, Metrics.Spacing.s)
        .frame(minHeight: Metrics.minTapTarget)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 离线、拉不到时的空状态（顶部的离线横幅由应用框架放，这里只占住页面）。
struct ModelsUnavailableView: View {
    let error: ClientError?
    let onRetry: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        if error?.isOffline == true {
            EmptyStateView(
                systemImage: "wifi.slash", title: zh ? "离线，暂无数据" : "Offline",
                message: zh ? "联网后会自动刷新。" : "This refreshes once you're back online.")
        } else {
            EmptyStateView(
                systemImage: "exclamationmark.triangle", title: zh ? "暂时拉不到" : "Couldn't load",
                actionTitle: zh ? "重试" : "Retry", action: onRetry)
        }
    }
}

/// 页面底部的小字说明。
struct ModelsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.Spacing.xs)
    }
}

/// 离线时写操作的说明（按钮下面）。
struct ModelsOfflineNote: View {
    @Environment(\.displayLanguage) private var language

    var body: some View {
        Text(language == .chinese ? "离线时不能修改，联网后再试。" : "You can't make changes while offline.")
            .typography(.footnote)
            .foregroundStyle(Theme.inkSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

#Preview("key 的一行 · 浅色中文") {
    let mock = MockClient(autoReply: false)
    VStack(spacing: Metrics.Spacing.s) {
        GroupedSection {
            ForEach(mock.state.credentials) { credential in
                ModelsCredentialRow(summary: CredentialSummary(credential: credential, vendors: DemoData.vendors)) {}
            }
        }
        ModelsField(title: "API key", text: .constant(""), prompt: "sk-…", kind: .secret, hint: "加密保存，只显示后 4 位。")
        ModelsField(
            title: "Anthropic Messages 地址", text: .constant("http://x"), kind: .url, problem: "只支持 https:// 开头的地址。")
    }
    .padding()
    .background(Theme.paper)
    .environment(\.displayLanguage, .chinese)
}

#Preview("key 的一行 · 深色英文") {
    let mock = MockClient(autoReply: false)
    VStack(spacing: Metrics.Spacing.s) {
        GroupedSection {
            ForEach(mock.state.credentials) { credential in
                ModelsCredentialRow(
                    summary: CredentialSummary(credential: credential, vendors: DemoData.vendors, language: .english))
            }
        }
        ModelsUnavailableView(error: .network(message: "offline")) {}
    }
    .padding()
    .background(Theme.paper)
    .environment(\.displayLanguage, .english)
    .preferredColorScheme(.dark)
}
