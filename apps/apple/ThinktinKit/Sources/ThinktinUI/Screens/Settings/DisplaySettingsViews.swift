import SwiftUI
import ThinktinKit

/// 外观（设置中心里压进来的子页面，不用 `AppRoute`）：跟随系统、浅色、深色。选了马上生效（App 根视图的
/// `.settingsPreferences()` 读它），存在本机。
struct AppearanceSettingsView: View {
    let preferences: SettingsPreferences

    @Environment(\.displayLanguage) private var language

    var body: some View {
        let zh = language == .chinese
        AccountScrollPage {
            AccountSection(
                footer: zh ? "只改这台设备上的显示，不影响别的设备。" : "This only changes how the app looks on this device."
            ) {
                SettingsOptionGroup(options: AppearancePreference.allCases) { option in
                    SettingsOptionRow(
                        systemImage: Self.icon(option), title: option.title(language), detail: option.detail(language),
                        isSelected: preferences.appearance == option
                    ) {
                        preferences.setAppearance(option)
                    }
                }
            }
        }
        .settingsNavigationTitle(zh ? "外观" : "Appearance")
    }

    static func icon(_ option: AppearancePreference) -> String {
        switch option {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// 语言（设置中心里压进来的子页面）：跟随系统、中文、English。选了界面马上换（App 根视图的 `.settingsPreferences()`），
/// 推送、收件箱的语言由 `LanguageSettingsModel` 同步到服务端（`setLocale`），请求语言跟着换（`setAcceptLanguage(for:)`）；
/// 没同步上时提示一句，可以重试。
struct LanguageSettingsView: View {
    @State private var model: LanguageSettingsModel

    @Environment(\.displayLanguage) private var language

    init(model: LanguageSettingsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let zh = language == .chinese
        let system = model.preferences.systemDisplayLanguage
        AccountScrollPage {
            AccountSection(footer: LanguageSettingsModel.footnote(language)) {
                SettingsOptionGroup(options: LanguagePreference.allCases) { option in
                    SettingsOptionRow(
                        systemImage: Self.icon(option), title: option.title(language),
                        detail: option == .system
                            ? (zh ? "现在是" : "Currently ") + LanguagePreference(system).title(language) : nil,
                        isSelected: model.selection == option
                    ) {
                        Task { await model.select(option) }
                    }
                }
            }
            if model.isSyncing {
                HStack(spacing: Metrics.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(zh ? "正在同步推送和收件箱的语言…" : "Updating notifications and inbox…")
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(.horizontal, Metrics.Spacing.m)
                .accessibilityElement(children: .combine)
            }
            if let error = model.syncError {
                VStack(alignment: .leading, spacing: Metrics.Spacing.xs) {
                    Text(LanguageSettingsModel.syncFailedMessage(language))
                        .typography(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.Spacing.m)
                    ErrorBanner(
                        error, onRetry: { Task { await model.retrySync() } }, onDismiss: { model.dismissError() })
                }
            }
        }
        .settingsNavigationTitle(zh ? "语言" : "Language")
    }

    static func icon(_ option: LanguagePreference) -> String {
        switch option {
        case .system: "iphone"
        case .chinese: "character.bubble"
        case .english: "textformat.abc"
        }
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
