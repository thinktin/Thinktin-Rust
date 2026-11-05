import SwiftUI
import ThinktinKit

/// 外观（设置中心里压进来的子页面，不用 `AppRoute`；参考 72）：一排三个方块，跟随系统、浅色、深色，选中的是突出的
/// 玻璃按钮、名字加粗。选了马上生效（App 根视图的 `.settingsPreferences()` 读它），存在本机。
/// 参考的第二排（深色时的底色：黑色 / 跟着 Bot 的颜色）这里没做：纯黑要 Theme 加一套值，排在第 2 轮（规范 4.9.11、6.22）。
struct AppearanceSettingsView: View {
    let preferences: SettingsPreferences

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        List {
            Section {
                HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                    ForEach(AppearancePreference.allCases, id: \.self) { option in
                        AppearanceTile(
                            option: option, isSelected: preferences.appearance == option,
                            select: { preferences.setAppearance(option) })
                    }
                }
                .padding(.top, Metrics.Spacing.xs)
            } footer: {
                Text(zh ? "只改这台设备上的显示，不影响别的设备。" : "This only changes how the app looks on this device.")
                    .padding(.top, Metrics.Spacing.xs)
            }
            .clearListRow()
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .settingsNavigationTitle(zh ? "外观" : "Appearance")
        .appFeedback(.selection, trigger: preferences.appearance)
    }

    static func icon(_ option: AppearancePreference) -> String {
        switch option {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

/// 外观页的一个方块（参考 72）：圆角 16 的系统按钮（选中的 `.prominent`），下面是名字。读屏念成“名字，已选中”的按钮。
struct AppearanceTile: View {
    let option: AppearancePreference
    let isSelected: Bool
    let select: @MainActor () -> Void

    @Environment(\.displayLanguage) private var language

    var body: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            Button(action: select) {
                Image(systemName: AppearanceSettingsView.icon(option))
                    .font(.title2)
                    .frame(maxWidth: .infinity, minHeight: SettingsMetrics.appearanceTileHeight)
                    .accessibilityHidden(true)
            }
            .glassButtonStyle(isSelected ? .prominent : .regular)
            .buttonBorderShape(.roundedRectangle(radius: SettingsMetrics.appearanceTileRadius))
            Text(option.title(language))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 语言（设置中心里压进来的子页面；参考 73）：一组纯文字行，选中的打勾（系统 `Picker(.inline)`），各语言用自己的文字写。
/// 选了界面马上换（App 根视图的 `.settingsPreferences()`），推送、收件箱的语言由 `LanguageSettingsModel` 同步到服务端
/// （`setLocale`），请求语言跟着换（`setAcceptLanguage(for:)`）；同步中、没同步上的提示在分组的脚注里，可以重试。
struct LanguageSettingsView: View {
    @State private var model: LanguageSettingsModel

    @Environment(\.displayLanguage) private var language

    init(model: LanguageSettingsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        List {
            Section {
                Picker(
                    selection: Binding(
                        get: { model.selection },
                        set: { option in Task { await model.select(option) } })
                ) {
                    ForEach(LanguagePreference.allCases, id: \.self) { option in
                        Text(rowTitle(option)).tag(option)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                footer
            }
            .themedRow()
            if let error = model.syncError {
                Section {
                    ErrorBanner(
                        error, onRetry: { Task { await model.retrySync() } }, onDismiss: { model.dismissError() })
                }
                .clearListRow()
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .settingsNavigationTitle(zh ? "语言" : "Language")
        .appFeedback(.selection, trigger: model.selection)
    }

    /// “跟随系统”带上现在系统给的语言：“跟随系统（中文）”。
    private func rowTitle(_ option: LanguagePreference) -> String {
        guard option == .system else { return option.title(language) }
        return option.summary(system: model.preferences.systemDisplayLanguage, language: language)
    }

    @ViewBuilder
    private var footer: some View {
        let zh = language == .chinese
        if model.isSyncing {
            HStack(spacing: Metrics.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text(zh ? "正在同步推送和收件箱的语言…" : "Updating notifications and inbox…")
            }
            .accessibilityElement(children: .combine)
        } else if model.syncError != nil {
            Text(LanguageSettingsModel.syncFailedMessage(language))
        } else {
            Text(LanguageSettingsModel.footnote(language))
        }
    }
}

/// 触感反馈（设置中心里压进来的子页面；参考 74）：一个开关和脚注。只存这台设备（`SettingsPreferences.hapticsEnabled`），
/// 界面里的触感都走 `appFeedback`，关掉后马上不震。
struct HapticsSettingsView: View {
    let preferences: SettingsPreferences

    @Environment(\.displayLanguage) private var language

    var body: some View {
        List {
            Section {
                Toggle(
                    HapticsText.title(language),
                    isOn: Binding(
                        get: { preferences.hapticsEnabled }, set: { preferences.setHapticsEnabled($0) }))
            } footer: {
                Text(HapticsText.footer(language))
            }
            .themedRow()
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .settingsNavigationTitle(HapticsText.title(language))
    }
}

#Preview("外观 · 浅色中文") {
    AppearanceSettingsView(preferences: SettingsPreviewSupport.preferences())
        .previewShell()
}

#Preview("外观 · 深色英文") {
    AppearanceSettingsView(preferences: SettingsPreviewSupport.preferences(appearance: .dark))
        .previewShell(.english, scheme: .dark)
}

#Preview("语言 · 浅色中文") {
    let client = ShellPreviewClients.signedIn()
    LanguageSettingsView(
        model: LanguageSettingsModel(
            client: client, preferences: SettingsPreviewSupport.preferences(), user: client.state.user)
    )
    .previewShell(client: client)
}

#Preview("语言 · 深色英文、没同步上") {
    let client = ShellPreviewClients.signedIn()
    let model = LanguageSettingsModel(
        client: client, preferences: SettingsPreviewSupport.preferences(language: .english), user: client.state.user)
    LanguageSettingsView(model: model)
        .task {
            client.failNext(with: .network(message: "offline"))
            await model.retrySync()
        }
        .previewShell(.english, scheme: .dark, client: client)
}

#Preview("触感反馈 · 深色中文") {
    HapticsSettingsView(preferences: SettingsPreviewSupport.preferences())
        .previewShell(scheme: .dark)
}
