import SwiftUI
import ThinktinKit

/// 导入记忆（`.importMemory`，参考 71；规范 4.9.10、6.20）：`Form` 两组，组标题写步骤：
/// 1. 导出提示词（能选中复制的文字，最多露 8 行）+ 一行“复制提示词”（复制后换成“已复制”，带触感）；
/// 2. 多行的粘贴框（占位“在这里粘贴你的记忆”），ThinkTin 多一行“添加到”选哪个 Botin（各 Botin 的记忆是分开的）；
/// 底部浮着全宽的“添加到记忆”（空的时候灰）。没有写记忆的接口，点了弹“即将推出”，粘贴的内容不离开这台设备。
struct ImportMemoryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ImportMemoryContent(draft: ImportMemoryDraft(instances: app.instances))
    }
}

private struct ImportMemoryContent: View {
    @State private var draft: ImportMemoryDraft
    @State private var copies = 0
    @State private var comingSoon: SettingsComingSoon?

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language

    init(draft: ImportMemoryDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let prompt = ImportMemoryText.exportPrompt(language)
        Form {
            Section {
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(.vertical, Metrics.Spacing.unit)
                Button {
                    Pasteboard.copy(prompt)
                    copies += 1
                } label: {
                    Text(copies > 0 ? SettingsExtrasText.copied(language) : ImportMemoryText.copyPrompt(language))
                }
                .accessibilityHint(Text(language == .chinese ? "把整段提示词放进剪贴板" : "Copies the whole prompt"))
            } header: {
                Text(ImportMemoryText.step1(language)).textCase(nil)
            }
            .themedRow()
            Section {
                SettingsMultilineField(
                    placeholder: ImportMemoryText.placeholder(language), text: $draft.text, lines: 6...14)
                let instances = SettingsExtrasText.pickableInstances(app.instances)
                if instances.isEmpty {
                    LabeledContent(ImportMemoryText.target(language), value: ImportMemoryText.noBotins(language))
                } else {
                    SettingsBotinPicker(
                        title: ImportMemoryText.target(language), selection: $draft.instanceID,
                        instances: app.instances, allowsNone: false)
                }
            } header: {
                Text(ImportMemoryText.step2(language)).textCase(nil)
            } footer: {
                if draft.isTooLong {
                    Text(ImportMemoryText.tooLong(language)).foregroundStyle(Theme.danger)
                } else {
                    Text(ImportMemoryText.footer(language))
                }
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedGroupedBackground()
        .scrollDismissesKeyboard(.interactively)
        .inlineNavigationTitle(AppRoute.importMemory.title(language))
        .floatingBar {
            SettingsBottomActions(title: ImportMemoryText.submit(language), isEnabled: draft.canSubmit) {
                comingSoon = .importMemory
            }
        }
        .appFeedback(.success, trigger: copies)
        .onChange(of: app.instances) {
            // Botin 列表晚到（刚启动）或者选的那个被删了：重新选第一个还能用的。
            let pickable = SettingsExtrasText.pickableInstances(app.instances)
            if !pickable.contains(where: { $0.id == draft.instanceID }) { draft.instanceID = pickable.first?.id }
        }
        .settingsComingSoon($comingSoon)
    }
}

#Preview("导入记忆 · 深色中文") {
    SettingsDestination(route: .importMemory).previewShell(scheme: .dark)
}

#Preview("导入记忆 · 浅色英文") {
    SettingsDestination(route: .importMemory).previewShell(.english)
}
