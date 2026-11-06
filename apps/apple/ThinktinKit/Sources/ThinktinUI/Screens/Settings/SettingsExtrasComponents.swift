import SwiftUI
import ThinktinKit

// 设置里还没有后端的几页（权限与规则、订阅、导入记忆、发送反馈、保险箱的卡片和联系信息、设备改名）共用的小组件：
// “即将推出”的系统提示、“只做一件事”的页底部的全宽主按钮（规范 2.7，参考 63、64、71、76）。

extension View {
    /// 点了还不能用的操作弹系统的“即将推出”提示（`SettingsComingSoon` 写原因）；关掉时把 `item` 清成 nil。
    func settingsComingSoon(_ item: Binding<SettingsComingSoon?>) -> some View {
        modifier(SettingsComingSoonAlert(item: item))
    }
}

private struct SettingsComingSoonAlert: ViewModifier {
    @Binding var item: SettingsComingSoon?

    @Environment(\.displayLanguage) private var language

    func body(content: Content) -> some View {
        content.alert(
            SettingsExtrasText.comingSoonTitle(language),
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            presenting: item
        ) { _ in
            Button(SettingsExtrasText.ok(language)) { item = nil }
        } message: { item in
            Text(item.message(language))
        }
    }
}

/// “只做一件事”的页底部浮着的全宽主按钮（规范 2.7：新建规则、导入记忆、发送反馈、新卡片），可选下面一行文字“取消”
/// （参考 63、64）。不能点时系统画成灰的（参考 63 空表单）。按钮比上面的卡片窄：左右留 32pt（参考 60、63、71、76
/// 量出来约 30pt，卡片是 16pt）；“取消”是正文色（参考 63、64）。
struct SettingsBottomActions: View {
    let title: String
    var isEnabled = true
    var isWorking = false
    /// 下面的“取消”；nil 不放。
    var onCancel: (@MainActor () -> Void)?
    let action: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            Button(action: action) {
                HStack(spacing: Metrics.Spacing.xs) {
                    if isWorking { ProgressView() }
                    Text(title)
                }
                .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(.prominent)
            .controlSize(.large)
            .disabled(!isEnabled || isWorking)
            if let onCancel {
                Button(SettingsExtrasText.cancel(language), action: onCancel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: Metrics.minTapTarget)
            }
        }
        .padding(.horizontal, Metrics.Spacing.xxl)
        .padding(.bottom, Metrics.Spacing.s)
    }
}

/// 表单里“标签在上、输入在下”的多行输入框（参考 63 的“适用于”、71 的粘贴框、76 的反馈、60 的“提示”）。
/// `title` 为 nil 时不画标签（标签在 Section 的标题里）。
struct SettingsMultilineField: View {
    var title: String?
    let placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 4...8

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.xxs) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(lines)
                .accessibilityLabel(Text(title ?? placeholder))
        }
        .padding(.vertical, Metrics.Spacing.xxs)
    }
}

/// 脚注里的字数（“12/500”），超了用危险色。
struct SettingsCharacterCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text(verbatim: "\(count)/\(limit)")
            .monospacedDigit()
            .foregroundStyle(count > limit ? Theme.danger : Theme.inkTertiary)
    }
}

/// 选 Botin 的系统菜单选择器（参考 77 的“Bot 无 ⌃⌄”）：可选“无”（`allowsNone`），其余是还能用的 Botin。
/// 值和上下箭头是次要文字的灰（`menuPickerTint()`，参考 76），不用强调色。
struct SettingsBotinPicker: View {
    let title: String
    @Binding var selection: InstanceID?
    let instances: [Instance]
    var allowsNone = true

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Picker(title, selection: $selection) {
            if allowsNone {
                Text(SettingsExtrasText.none(language)).tag(InstanceID?.none)
            }
            ForEach(SettingsExtrasText.pickableInstances(instances)) { instance in
                Text(verbatim: instance.name).tag(InstanceID?.some(instance.id))
            }
        }
        .pickerStyle(.menu)
        .menuPickerTint()
    }
}
