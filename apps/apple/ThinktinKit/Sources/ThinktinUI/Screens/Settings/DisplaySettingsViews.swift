import SwiftUI
import ThinktinKit

/// 外观（设置中心里压进来的子页面，不用 `AppRoute`；参考 72）：一排三个方块，跟随系统、浅色、深色；下面一排两个宽的
/// （纯黑、Botin 配色，参考 72 的第二排）。方块是各自独立的圆角框（没选中的只有一圈细线、选中的垫卡片色加一圈强调色的线），
/// 图标是正文色 / 次要灰，下面是名字（选中的加粗）。选了马上生效（App 根视图的 `.settingsPreferences()` 读它），存在本机。
/// 第二排还没做（纯黑要 Theme 加一套值、Botin 配色要按 Botin 换强调色，规范 4.9.11、6.22），点了弹“即将推出”。
struct AppearanceSettingsView: View {
    let preferences: SettingsPreferences

    @Environment(\.displayLanguage) private var language
    @State private var comingSoon: SettingsComingSoon?

    var body: some View {
        let zh = language == .chinese
        List {
            Section {
                VStack(spacing: Metrics.Spacing.l) {
                    HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                        ForEach(AppearancePreference.allCases, id: \.self) { option in
                            AppearanceTile(
                                title: option.title(language), systemImage: Self.icon(option),
                                isSelected: preferences.appearance == option,
                                select: { preferences.setAppearance(option) })
                        }
                    }
                    HStack(alignment: .top, spacing: Metrics.Spacing.s) {
                        AppearanceTile(
                            title: zh ? "纯黑" : "Pure black", systemImage: "circle.fill", isSelected: false,
                            select: { comingSoon = .extraAppearance })
                        AppearanceTile(
                            title: zh ? "Botin 配色" : "Botin colours", systemImage: "paintpalette", isSelected: false,
                            select: { comingSoon = .extraAppearance })
                    }
                }
                .padding(.top, Metrics.Spacing.xs)
                // 只有这一行去掉卡片底和边距；加在 `Section` 上会连脚注的边距一起去掉（2026-11-06 截图：脚注贴着卡片边）。
                .clearListRow()
            } footer: {
                Text(zh ? "只改这台设备上的显示，不影响别的设备。" : "This only changes how the app looks on this device.")
                    .padding(.top, Metrics.Spacing.xs)
            }
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .settingsNavigationTitle(zh ? "外观" : "Appearance")
        .appFeedback(.selection, trigger: preferences.appearance)
        .settingsComingSoon($comingSoon)
    }

    static func icon(_ option: AppearancePreference) -> String {
        switch option {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

/// 外观页的一个方块（参考 72）：圆角 16 的普通按钮，各自独立（不是玻璃：玻璃按钮挨在一起时整排后面拖一块灰影，
/// 2026-11-06 截图）。没选中的只有一圈细线、图标次要灰；选中的垫卡片色、一圈强调色的线、图标正文色。下面是名字。
/// 读屏念成“名字，已选中”的按钮。
struct AppearanceTile: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let select: @MainActor () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.appearanceTileRadius, style: .continuous)
        VStack(spacing: Metrics.Spacing.xs) {
            Button(action: select) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: SettingsMetrics.appearanceTileHeight)
                    .background(isSelected ? Theme.paperElevated : Color.clear, in: shape)
                    .overlay { shape.strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: 1) }
                    .contentShape(shape)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            Text(title)
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
