import SwiftUI
import ThinktinKit

// 设置页面（WBS 12.12）共用的小组件。改版后（规范 4.9，参考 53–75）设置一带都是系统的 insetGrouped `List` / `Form`：
// 行里不放图标，标题、灰色副标题、右边灰色的值，系统 `NavigationLink` 画箭头；外部链接行尾 `arrow.up.right`。

/// 设置一带的尺寸（参考量出来的）。
enum SettingsMetrics {
    /// 设置根页、账号页第一行的头像（参考 53、54 量出来约 40pt，那一行高 73pt）。
    static let profileAvatar: CGFloat = 40
    /// 一行里标题和副标题之间（参考 53、70：标题顶到副标题顶约 25pt，带副标题的行高约 72pt）。
    static let subtitleSpacing: CGFloat = 6
    /// 外观页方块的圆角（参考 72）。
    static let appearanceTileRadius: CGFloat = 16
    /// 版本区 Logo 的高（参考 75 的图标约 51pt）。
    static let footerLogo: CGFloat = 52
    /// 版本区名字的字号（参考 75 约 24pt，系统的文字样式里没有这一号；跟着 `.title2` 缩放）。
    static let footerName: CGFloat = 24
    /// 两组之间（参考 53、54、59、70、75：中间没有标题、脚注的两张卡片相隔 27.5–28pt；系统默认 35pt）。
    static let sectionSpacing: CGFloat = 28
    /// 分组标题上面多留的（系统给标题留的高度不变，上一组下面只剩半个组间距；补上以后标题隔开的两张卡片还是约 54pt，
    /// 参考 53、54 是 53.9pt）。
    static let headerTopPadding: CGFloat = Metrics.Spacing.unit
    /// 脚注下面多留的（参考 60 一行脚注隔开的两张卡片 53.9pt、75 两行的 72pt、61 脚注加标题 80pt；系统的少 10pt 左右）。
    static let footerBottomPadding: CGFloat = 10
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
            VStack(alignment: .leading, spacing: SettingsMetrics.subtitleSpacing) {
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

/// 设置根页最底下的版本区（参考 75、规范 2.9）：Logo、名字、版本号（构建号），居中。参考量的：图标高约 51pt，名字约 24pt、
/// 离图标约 22pt，版本号离名字约 13pt，图标离上面最后一张卡片约 62pt（上面的留白加上组间距）。
struct SettingsVersionFooter: View {
    let footer: (name: String, version: String)

    @ScaledMetric(relativeTo: .title2) private var nameSize: CGFloat = SettingsMetrics.footerName

    var body: some View {
        VStack(spacing: 0) {
            BrandLogo()
                .frame(height: SettingsMetrics.footerLogo)
                .padding(.bottom, Metrics.Spacing.m)
                .accessibilityHidden(true)
            Text(verbatim: footer.name)
                .font(.system(size: nameSize))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, Metrics.Spacing.xxs)
            Text(verbatim: footer.version)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Spacing.xxl)
        .padding(.bottom, Metrics.Spacing.xl)
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

extension View {
    /// 设置一带分组列表上下的节奏（参考 53、54、59、60、70、75 量的）：两组之间 28pt（系统默认 35pt），导航栏下面 24pt 是
    /// 第一张卡片（卡片顶在 × / 返回的圆下面约 34pt；系统默认再低 11pt）。加在 `insetGroupedList()` / `formStyle(.grouped)`
    /// 后面；这一页的分组标题用 `settingsGroupHeader()`、脚注加 `settingsGroupFooter()`，标题和脚注隔开的间距才和参考一样。
    /// macOS 原样。
    func settingsGroupedList() -> some View {
        #if os(iOS)
            listSectionSpacing(SettingsMetrics.sectionSpacing)
                .contentMargins(.top, Metrics.Spacing.xl, for: .scrollContent)
        #else
            self
        #endif
    }

    /// 设置一带的分组标题（用了 `settingsGroupedList()` 的页面）：`groupHeader()` 的小号灰字，上面补 4pt
    /// （`SettingsMetrics.headerTopPadding`）。
    func settingsGroupHeader() -> some View {
        #if os(iOS)
            groupHeader().padding(.top, SettingsMetrics.headerTopPadding)
        #else
            groupHeader()
        #endif
    }

    /// 设置一带的脚注（用了 `settingsGroupedList()` 的页面）：`groupFooter()` 的灰，下面补 10pt
    /// （`SettingsMetrics.footerBottomPadding`）。字号是系统的脚注；红字、字数照常自己上色。
    func settingsGroupFooter() -> some View {
        #if os(iOS)
            groupFooter().padding(.bottom, SettingsMetrics.footerBottomPadding)
        #else
            groupFooter()
        #endif
    }

    /// 保险箱几页的分组标题：参考 59、61 的标题（“地址”等）比别的设置页亮一档，和行里的灰字一样（`inkSecondary`）。
    func vaultGroupHeader() -> some View {
        foregroundStyle(Theme.inkSecondary).settingsGroupHeader()
    }

    /// 保险箱几页的脚注：参考 57、59、60、61 的脚注和行里的灰字一样亮（约 #9B9B9D），不像别的设置页暗一档。
    func vaultGroupFooter() -> some View {
        foregroundStyle(Theme.inkSecondary).settingsGroupFooter()
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
