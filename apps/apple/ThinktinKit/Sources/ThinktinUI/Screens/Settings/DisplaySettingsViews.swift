import SwiftUI
import ThinktinKit

/// 外观（设置中心里压进来的子页面，不用 `AppRoute`；参考 72）：一排三个方块，跟随系统、浅色、深色；下面一排两个宽的
/// （纯黑、Botin 配色，参考 72 的第二排）。方块是各自独立的圆角框（没选中的只有一圈细线、选中的垫卡片色加一圈强调色的线），
/// 第一排的图标是正文色 / 次要灰，第二排是色样（正文色的实心圆、Botin 头像颜色的色轮），下面是名字（选中的加粗）。
/// 方块从别的页面第一张卡片的位置开始，下面没有脚注（参考 72）。选了马上生效（App 根视图的 `.settingsPreferences()`
/// 读它），存在本机。第二排还没做（纯黑要 Theme 加一套值、Botin 配色要按 Botin 换强调色，规范 4.9.11、6.22），点了弹“即将推出”。
struct AppearanceSettingsView: View {
    let preferences: SettingsPreferences

    @Environment(\.displayLanguage) private var language
    @State private var comingSoon: SettingsComingSoon?

    var body: some View {
        let zh = language == .chinese
        List {
            Section {
                VStack(spacing: AppearanceTileLayout.rowSpacing) {
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
                            title: zh ? "纯黑" : "Pure black", icon: .inkSwatch, isSelected: false,
                            select: { comingSoon = .extraAppearance })
                        AppearanceTile(
                            title: zh ? "Botin 配色" : "Botin colours", icon: .botinColors, isSelected: false,
                            select: { comingSoon = .extraAppearance })
                    }
                }
                // 这一行去掉卡片底和边距，方块自己画框。
                .clearListRow()
            }
        }
        .insetGroupedList()
        .settingsGroupedList()
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

/// 外观页方块的尺寸（参考 72 量的；2026-11-11 截图里方块高 64pt、两排的间距 110pt，比参考扁、挤）。
enum AppearanceTileLayout {
    /// 方块的高（参考约 80pt）。
    static let height: CGFloat = 80
    /// 图标、色样的大小（参考约 26pt）；跟着 `.title2` 缩放。
    static let icon: CGFloat = 26
    /// 上一排的名字到下一排的方块（参考：名字中线到下一排约 40pt，两排的间距约 141pt）。
    static let rowSpacing: CGFloat = Metrics.Spacing.xxl
}

/// 外观页的一个方块（参考 72）：圆角 16 的普通按钮，各自独立（不是玻璃：玻璃按钮挨在一起时整排后面拖一块灰影，
/// 2026-11-06 截图）。没选中的只有一圈细线、图标次要灰；选中的垫卡片色、一圈强调色的线、图标正文色。下面隔 12pt 是名字。
/// 读屏念成“名字，已选中”的按钮。
struct AppearanceTile: View {
    /// 方块里画什么。
    enum Icon: Equatable {
        /// SF Symbol：没选中是次要灰，选中是正文色。
        case symbol(String)
        /// 正文色的实心圆（“纯黑”，参考 72 的“黑色”）。是色样，不跟着选没选中变色。
        case inkSwatch
        /// Botin 头像的颜色拼成的色轮（“Botin 配色”，参考 72 的“Bot 颜色”）。
        case botinColors
    }

    let title: String
    let icon: Icon
    let isSelected: Bool
    let select: @MainActor () -> Void

    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = AppearanceTileLayout.icon

    init(title: String, icon: Icon, isSelected: Bool, select: @escaping @MainActor () -> Void) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.select = select
    }

    /// 图标是 SF Symbol 的方块（第一排）。
    init(title: String, systemImage: String, isSelected: Bool, select: @escaping @MainActor () -> Void) {
        self.init(title: title, icon: .symbol(systemImage), isSelected: isSelected, select: select)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.appearanceTileRadius, style: .continuous)
        VStack(spacing: Metrics.Spacing.s) {
            Button(action: select) {
                iconView
                    .frame(maxWidth: .infinity, minHeight: AppearanceTileLayout.height)
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

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: iconSize))
                .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
        case .inkSwatch:
            Circle()
                .fill(Theme.ink)
                .frame(width: iconSize, height: iconSize)
        case .botinColors:
            BotinColorWheel()
                .frame(width: iconSize, height: iconSize)
        }
    }
}

/// “Botin 配色”方块里的色轮（参考 72 是一个分成几瓣的彩色圆）：Botin 头像的颜色照色相排一圈，一种一瓣，从正上方起顺时针。
struct BotinColorWheel: View {
    /// 一圈上的颜色：头像色板里有彩度的十种（棕、灰不放）。
    static let colors: [AvatarColor] = [.red, .orange, .amber, .green, .mint, .sky, .blue, .violet, .purple, .pink]

    var body: some View {
        ZStack {
            ForEach(Self.colors.indices, id: \.self) { index in
                ColorWheelWedge(index: index, count: Self.colors.count)
                    .fill(InstanceAvatar.fill(of: Self.colors[index]))
            }
        }
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// 色轮的一瓣：圆心和圆外两点连成的三角形。两点离圆心有外框的边长那么远，三角形的外边整条落在圆外（三瓣以上时），
/// 多出来的角由外面的圆裁掉。每一瓣往下一瓣那边多画一点点，被下一瓣盖住，两瓣之间不露底色的细缝。
struct ColorWheelWedge: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let reach = max(rect.width, rect.height)
        let step = 2 * Double.pi / Double(max(count, 1))
        let start = step * Double(index) - Double.pi / 2
        // 往下一瓣多画的角度（弧度，约 1°）。
        let overlap = 0.02
        func point(at angle: Double) -> CGPoint {
            CGPoint(x: center.x + reach * CGFloat(cos(angle)), y: center.y + reach * CGFloat(sin(angle)))
        }
        var path = Path()
        path.move(to: center)
        path.addLine(to: point(at: start))
        path.addLine(to: point(at: start + step + overlap))
        path.closeSubpath()
        return path
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
                footer.settingsGroupFooter()
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
        .settingsGroupedList()
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
                Text(HapticsText.footer(language)).settingsGroupFooter()
            }
            .themedRow()
        }
        .insetGroupedList()
        .settingsGroupedList()
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
