import SwiftUI
import ThinktinKit

// 模型 key、路由、用量（WBS 12.4）共用的小组件。名字都带 Models 前缀，不和别的功能重名。
// 改版后各页是系统的 `List` / `Form`（规范 2.5），这里只有行的内容；红字沿用 `FieldMessage`。

/// 表单里的一个输入框（放在 `Form` 的一行里，和 `FormTextField` 一样标签在上、没有自己画的框）：上面一行小标题，
/// 输入框（普通、密码、标识、网址、数字），下面是问题（危险色）或提示。
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

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            field
                .font(kind == .secret ? Typography.body.monospacedFont : Typography.body.font)
                .foregroundStyle(Theme.ink)
                .autocorrectionDisabled(kind != .plain)
                .modelsKeyboard(kind)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(problem ?? hint ?? ""))
            if let problem {
                FieldMessage(text: problem)
                    .accessibilityHidden(true)
            } else if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Metrics.Spacing.xxs)
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
    func modelsKeyboard(_ kind: ModelsField.Kind) -> some View {
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

/// key 列表里的一行（分组列表的行，外面包 `NavigationLink` 时系统画箭头）：照规范 2.5 的行（一行标题、一行灰字）——
/// 厂商的圆角方块首字图标（规范 2.4：应用 / 厂商的图标是 40pt、圆角方块，和 Botin 的圆头像分开）、名字、一行 `.footnote`
/// 的“厂商 · 后 4 位”，右边灰色的每日上限。协议在 key 详情里；停用的在“已停用”那一组，行里不再写一遍。
struct ModelsCredentialRow: View {
    let summary: CredentialSummary

    @Environment(\.displayLanguage) private var language

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.Spacing.s) {
            CredentialVendorIcon(name: summary.vendorName, size: CredentialVendorIcon.rowSize)
                .opacity(summary.isDisabled ? 0.5 : 1)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(summary.name)
                    .foregroundStyle(summary.isDisabled ? Theme.inkSecondary : Theme.ink)
                    .lineLimit(1)
                Text(summary.subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Metrics.Spacing.xs)
            Text(summary.dailyLimitShort)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, Metrics.Spacing.unit / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary.accessibilityLabel(language)))
    }
}

/// 厂商的图标：圆角方块、厂商名的首字、按名字取色（和引擎目录的 `EngineIcon` 一样画法；不用厂商的 Logo）。
struct CredentialVendorIcon: View {
    /// 列表行（规范 2.4：应用图标方块 40）。
    static let rowSize: CGFloat = 40
    /// key 详情的头部。
    static let detailSize: CGFloat = 64

    let name: String
    let size: CGFloat

    var body: some View {
        AvatarGlyph(name: name, appearance: InstanceAppearance(shape: .squircle), size: size)
            .accessibilityHidden(true)
    }
}

/// 离线、拉不到时的空状态（系统的 `ContentUnavailableView`；顶部的离线横幅由应用框架放，这里只占住页面）。
struct ModelsUnavailableView: View {
    let error: ClientError?
    let onRetry: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        if error?.isOffline == true {
            ContentUnavailableView(
                zh ? "离线，暂无数据" : "Offline", systemImage: "wifi.slash",
                description: Text(zh ? "联网后会自动刷新。" : "This refreshes once you're back online."))
        } else {
            ContentUnavailableView {
                Label(zh ? "暂时拉不到" : "Couldn't load", systemImage: "exclamationmark.triangle")
            } actions: {
                Button(zh ? "重试" : "Retry", action: onRetry)
                    .glassButtonStyle()
            }
        }
    }
}

#Preview("key 的一行 · 浅色中文") {
    let mock = MockClient(autoReply: false)
    List {
        ForEach(mock.state.credentials) { credential in
            ModelsCredentialRow(summary: CredentialSummary(credential: credential, vendors: DemoData.vendors))
        }
        ModelsField(title: "API key", text: .constant(""), prompt: "sk-…", kind: .secret, hint: "加密保存，只显示后 4 位。")
        ModelsField(
            title: "Anthropic Messages 地址", text: .constant("http://x"), kind: .url, problem: "只支持 https:// 开头的地址。")
    }
    .environment(\.displayLanguage, .chinese)
}

#Preview("key 的一行 · 深色英文") {
    let mock = MockClient(autoReply: false)
    VStack(spacing: Metrics.Spacing.s) {
        List {
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
