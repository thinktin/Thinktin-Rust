import SwiftUI
import ThinktinKit

// 设置页面（WBS 12.12）共用的小组件。改版后（规范 4.9，参考 53–75）设置一带都是系统的 insetGrouped `List` / `Form`：
// 行里不放图标，标题、灰色副标题、右边灰色的值，系统 `NavigationLink` 画箭头；外部链接行尾 `arrow.up.right`。

/// 设置一带的尺寸（参考量出来的）。
enum SettingsMetrics {
    /// 设置根页、账号页第一行的头像（参考 53、54）。
    static let profileAvatar: CGFloat = 44
    /// 外观页方块的高（参考 72）。
    static let appearanceTileHeight: CGFloat = 64
    /// 外观页方块的圆角（参考 72）。
    static let appearanceTileRadius: CGFloat = 16
    /// 版本区 Logo 的高（规范 2.9）。
    static let footerLogo: CGFloat = 40
}

/// 一行的文字：标题，下面可选的灰色副标题，右边可选的灰色值（`LabeledContent`，放进 `NavigationLink` 时系统画箭头）。
/// 副标题是一行 `.footnote`（参考 53、70 的“自动审查已开启 · 3 条规则”“搜索插件”量出来约 13pt，不折行），
/// 字号是辅助功能的大号时才放开折行。整句说明（“换 key”这种操作行）传 `subtitleLineLimit: nil` 照常折行。
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var value: String?
    var isDestructive = false
    var subtitleLineLimit: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: String, subtitle: String? = nil, value: String? = nil, isDestructive: Bool = false,
        subtitleLineLimit: Int? = 1
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.isDestructive = isDestructive
        self.subtitleLineLimit = subtitleLineLimit
    }

    init(_ row: SettingsRow) {
        self.init(title: row.title, subtitle: row.subtitle, value: row.value, isDestructive: row.isDestructive)
    }

    var body: some View {
        LabeledContent {
            if let value {
                Text(value)
                    .lineLimit(1)
            }
        } label: {
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(title)
                    .foregroundStyle(isDestructive ? Theme.danger : Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : subtitleLineLimit)
                }
            }
        }
    }
}

/// 在浏览器里打开的一行（参考 75）：标题，行尾 `arrow.up.right`。
struct ExternalLinkRow: View {
    let title: String
    let url: URL

    @Environment(\.displayLanguage) private var language

    var body: some View {
        Link(destination: url) {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Metrics.Spacing.xs)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint(Text(language == .chinese ? "在浏览器里打开" : "Opens in your browser"))
    }
}

/// 设置根页最底下的版本区（参考 75、规范 2.9）：Logo、名字、版本号（构建号），居中。
struct SettingsVersionFooter: View {
    let footer: (name: String, version: String)

    var body: some View {
        VStack(spacing: Metrics.Spacing.xs) {
            BrandLogo()
                .frame(height: SettingsMetrics.footerLogo)
                .accessibilityHidden(true)
            Text(verbatim: footer.name)
                .font(.title3)
                .foregroundStyle(Theme.ink)
            Text(verbatim: footer.version)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

/// 页面顶部的行内标题（iOS 上用小标题样式）。
extension View {
    func settingsNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
            navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
            navigationTitle(title)
        #endif
    }
}

/// 预览、界面测试用的东西：只在内存里的偏好、固定的通知权限。
enum SettingsPreviewSupport {
    /// 只在内存里的偏好（不写 UserDefaults）。
    @MainActor
    static func preferences(
        appearance: AppearancePreference = .system, language: LanguagePreference = .system
    ) -> SettingsPreferences {
        let prefs = SettingsPreferences(defaults: nil)
        prefs.setAppearance(appearance)
        prefs.setLanguage(language)
        return prefs
    }
}

extension View {
    /// 预览、测试：放进内存里的偏好、固定的通知权限（默认已开启），不碰 UserDefaults 和系统的通知中心。
    func settingsPreviewEnvironment(
        _ preferences: SettingsPreferences? = nil, notifications: NotificationPermission = .authorized
    ) -> some View {
        settingsPreferencesStore(preferences ?? SettingsPreviewSupport.preferences())
            .environment(\.notificationPermissionReader, FixedNotificationPermission(notifications))
    }
}
