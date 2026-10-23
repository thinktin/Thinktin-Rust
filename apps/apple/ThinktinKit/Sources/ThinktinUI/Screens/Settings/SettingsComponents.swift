import SwiftUI
import ThinktinKit

// 设置页面（WBS 12.12）共用的小组件。分组、行、头像、滚动容器沿用 12.2 账号页的（`AccountSection`、`AccountRow`、
// `AccountRowDivider`、`AccountAvatar`、`AccountScrollPage`），版式和 Claude iOS App 的设置页一样：纸色底上一组组圆角卡片。

/// 单选的一行（外观、语言）：图标、名字、可选的说明，选中的右边打勾。读屏读成“已选中”的按钮。
struct SettingsOptionRow: View {
    let systemImage: String?
    let title: String
    var detail: String?
    let isSelected: Bool
    let select: @MainActor () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Metrics.Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: Metrics.Spacing.xl)
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(title)
                        .typography(.body)
                        .foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail)
                            .typography(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Metrics.Spacing.xs)
                Image(systemName: "checkmark")
                    .font(Typography.body.font.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.Spacing.m)
            .padding(.vertical, Metrics.Spacing.s)
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 一组单选项：中间有分隔线。
struct SettingsOptionGroup<Option: Hashable, Row: View>: View {
    let options: [Option]
    @ViewBuilder let row: (Option) -> Row

    var body: some View {
        ForEach(Array(options.enumerated()), id: \.element) { index, option in
            if index > 0 { AccountRowDivider() }
            row(option)
        }
    }
}

/// 页面最底下居中的一行小字（版本号）。
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .typography(.caption)
            .foregroundStyle(Theme.inkTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
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
