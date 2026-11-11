import SwiftUI
import ThinktinKit

/// 发送反馈（`.feedback`，参考 76、77；规范 4.9.14、6.20 B）：`Form`：多行输入框 + 脚注（会用邮件发、带上版本）；
/// 小号灰字的组标题“出问题的 Botin（可选）”（ThinkTin 自己的说法）下面一行系统菜单选择器“Botin 无 ⌃⌄”（无 + 各个 Botin，
/// 参考 77；值是灰的，`SettingsBotinPicker`）；底部浮着“发送反馈”（比卡片窄，空的时候灰）。上下的节奏和设置别的页一样
/// （`settingsGroupedList()`）。ThinkTin 没有通用的反馈接口，点了把反馈拼成 `mailto:` 交给系统的邮件 App
/// （用户在邮件里还能改、能不发）；打不开邮件时提示反馈邮箱、可以复制。
struct FeedbackScreen: View {
    @State private var draft = FeedbackDraft()
    @State private var showsNoMail = false
    @FocusState private var isFocused: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                TextField(FeedbackText.placeholder(language), text: $draft.text, axis: .vertical)
                    .lineLimit(6...14)
                    .focused($isFocused)
                    .accessibilityLabel(Text(AppRoute.feedback.title(language)))
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    if draft.isTooLong {
                        Text(FeedbackText.tooLong(language)).foregroundStyle(Theme.danger)
                    } else {
                        Text(FeedbackText.footer(language))
                    }
                    Spacer(minLength: Metrics.Spacing.xs)
                    if draft.trimmed.unicodeScalars.count > FeedbackDraft.maxLength / 2 {
                        SettingsCharacterCount(
                            count: draft.trimmed.unicodeScalars.count, limit: FeedbackDraft.maxLength)
                    }
                }
                // 参考 76：脚注的字到下一组标题的字约 34pt，两张卡片隔约 82pt（一行脚注）；系统默认是 18pt、65pt。
                // 这里脚注后面紧跟着标题，比 `settingsGroupFooter()` 的 10pt 多留一点。
                .padding(.bottom, Metrics.Spacing.m)
            }
            .themedRow()
            Section {
                SettingsBotinPicker(
                    title: FeedbackText.botinLabel(language), selection: $draft.instanceID, instances: app.instances)
            } header: {
                Text(FeedbackText.botinHeader(language)).settingsGroupHeader()
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .settingsGroupedList()
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .inlineNavigationTitle(AppRoute.feedback.title(language))
        .floatingBar {
            SettingsBottomActions(title: FeedbackText.send(language), isEnabled: draft.canSend, isEditing: isFocused) {
                send()
            }
        }
        .onAppear { isFocused = true }
        .alert(FeedbackText.noMailTitle(language), isPresented: $showsNoMail) {
            Button(FeedbackText.copyAddress(language)) { Pasteboard.copy(FeedbackDraft.address) }
            Button(SettingsExtrasText.ok(language), role: .cancel) {}
        } message: {
            Text(FeedbackText.noMailMessage(language))
        }
    }

    /// 交给系统的邮件 App；没有能处理 `mailto:` 的 App 时提示邮箱。
    private func send() {
        let instance = app.instances.first { $0.id == draft.instanceID }
        guard
            let url = draft.mailtoURL(
                instance: instance, appInfo: .current, system: FeedbackDraft.systemDescription(), language: language)
        else { return }
        openURL(url) { accepted in
            if !accepted { showsNoMail = true }
        }
    }
}

#Preview("发送反馈 · 深色中文") {
    SettingsDestination(route: .feedback).previewShell(scheme: .dark)
}

#Preview("发送反馈 · 浅色英文") {
    SettingsDestination(route: .feedback).previewShell(.english)
}
