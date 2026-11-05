import SwiftUI
import ThinktinKit

/// 设置中心（WBS 12.12，`.settings`；首页左上的头像弹出的 sheet，左上的 × 由应用框架加）。改版照参考 53、70、75
/// （规范 4.9.1）：没有标题，insetGrouped 的分组，行里不放图标，最底下是版本区（Logo、名字、版本号）。
/// 分组和每一行去哪由 `SettingsModel.sections(_:pendingApprovals:)` 定（ThinktinKit 里测）：别的功能的页面压进 sheet 的栈
/// （`AppRoute`），外观、语言、触感是本功能的子页面，通知开关跳系统设置，用户协议、隐私政策在浏览器里打开，
/// 退出登录、全部停止用 12.2 的做法。实时活动（12.10）的两个开关接在“Botin”那组后面。
///
/// 设置中心不联网也能用（`OfflinePolicy.local`，没有离线横幅）：要联网的操作（全部停止）离线时禁用。
struct SettingsScreen: View {
    @Environment(\.client) private var client
    @Environment(AppModel.self) private var app
    @Environment(\.settingsPreferences) private var preferences
    @Environment(\.notificationPermissionReader) private var notifications

    var body: some View {
        SettingsContent(
            model: SettingsModel(
                client: client, user: app.user, preferences: preferences ?? .shared, notifications: notifications),
            client: client)
    }
}

private struct SettingsContent: View {
    @State private var model: SettingsModel
    @State private var stopAll: StopAllModel
    let client: any ClientProtocol

    @Environment(AppModel.self) private var app
    @Environment(\.displayLanguage) private var language
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var confirmsSignOut = false
    @State private var isSigningOut = false
    @State private var signOutError: ClientError?

    init(model: SettingsModel, client: any ClientProtocol) {
        _model = State(initialValue: model)
        _stopAll = State(initialValue: StopAllModel(client: client))
        self.client = client
    }

    var body: some View {
        let zh = language == .chinese
        List {
            if let signOutError {
                Section {
                    ErrorBanner(signOutError, onDismiss: { self.signOutError = nil })
                }
                .clearListRow()
            }
            ForEach(model.sections(language, pendingApprovals: app.badges.pendingApprovals)) { section in
                Section {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                } header: {
                    if let title = section.title {
                        Text(title).textCase(nil)
                    }
                } footer: {
                    if let footer = section.footer {
                        Text(footer)
                    }
                }
                .themedRow()
                // 实时活动（12.10，只在支持的设备上有）：参考“Bot”组里开关的位置。
                if section.id == .botins, let live = app.liveActivities {
                    LiveActivitySettingsSection(model: live)
                }
            }
            Section {
                SettingsVersionFooter(footer: model.versionFooter(language))
            }
            .clearListRow()
        }
        .insetGroupedList()
        .themedGroupedBackground()
        .inlineNavigationTitle(AppRoute.settings.title(language)) {
            // 参考 53 没有标题；返回按钮的长按菜单照样写“设置”。
            EmptyView()
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) {
            // 从系统设置回来：通知权限可能改了。
            if scenePhase == .active { Task { await model.refreshNotificationPermission() } }
        }
        .onChange(of: app.user) { model.apply(app.user) }
        .confirmationDialog(zh ? "退出登录？" : "Sign out?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button(zh ? "退出登录" : "Sign out", role: .destructive) { signOut() }
            Button(zh ? "取消" : "Cancel", role: .cancel) {}
        } message: {
            Text(AccountModel.signOutMessage(language))
        }
    }

    @ViewBuilder
    private func rowView(_ row: SettingsRow) -> some View {
        let zh = language == .chinese
        switch row.action {
        case .open(let route)? where row.isProfile:
            NavigationLink(value: route) { SettingsProfileRow(title: row.title, subtitle: row.subtitle) }
        case .open(let route)?:
            NavigationLink(value: route) { SettingsRowLabel(row) }
        case .appearance?:
            NavigationLink {
                AppearanceSettingsView(preferences: model.preferences)
            } label: {
                SettingsRowLabel(row)
            }
        case .language?:
            NavigationLink {
                LanguageSettingsView(
                    model: LanguageSettingsModel(client: client, preferences: model.preferences, user: model.user))
            } label: {
                SettingsRowLabel(row)
            }
        case .haptics?:
            NavigationLink {
                HapticsSettingsView(preferences: model.preferences)
            } label: {
                SettingsRowLabel(row)
            }
        case .systemNotificationSettings?:
            notificationToggle(row)
        case .link(let url)?:
            ExternalLinkRow(title: row.title, url: url)
        case .signOut?:
            Button(role: .destructive) {
                confirmsSignOut = true
            } label: {
                HStack {
                    Text(row.title)
                    if isSigningOut {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .foregroundStyle(Theme.danger)
            .disabled(isSigningOut)
            .accessibilityHint(Text(zh ? "先确认再退出" : "Asks before signing out"))
        case .stopAll?:
            // 12.2 的那一行：二次确认、结果弹窗、刷新角标、离线禁用都在里面。
            StopAllRow(model: stopAll)
        case nil:
            SettingsRowLabel(row)
        }
    }

    /// 通知（参考 70 是开关）：开关的状态是系统的通知权限，App 自己改不了，拨它就去系统设置里改；回来时重新读。
    @ViewBuilder
    private func notificationToggle(_ row: SettingsRow) -> some View {
        let zh = language == .chinese
        if let url = SystemSettingsLink.notifications {
            Toggle(
                isOn: Binding(
                    get: { model.notificationPermission?.canDeliver ?? false },
                    set: { _ in openURL(url) })
            ) {
                Text(row.title)
            }
            .accessibilityValue(Text(row.value ?? ""))
            .accessibilityHint(Text(zh ? "在系统设置里打开或关闭" : "Change this in Settings"))
        } else {
            LabeledContent(row.title, value: row.value ?? "")
        }
    }

    /// 退出登录用 `AppModel.signOut()`：网络不通时本地照样清掉，之后应用框架回到登录页。
    private func signOut() {
        isSigningOut = true
        signOutError = nil
        Task {
            defer { isSigningOut = false }
            do {
                try await app.signOut()
            } catch {
                signOutError = (error as? ClientError) ?? .internal(message: String(describing: error))
            }
        }
    }
}

/// 账号行（参考 53 的第一行）：44pt 头像、名字、打码的手机号。系统 `NavigationLink` 画右边的箭头。
struct SettingsProfileRow: View {
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: Metrics.Spacing.s) {
            InstanceAvatar(title, size: SettingsMetrics.profileAvatar)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(.vertical, Metrics.Spacing.unit)
        .accessibilityElement(children: .combine)
    }
}

#Preview("设置 · 浅色中文") {
    SettingsScreen()
        .settingsPreviewEnvironment()
        .previewShell()
}

#Preview("设置 · 深色英文、通知关着") {
    SettingsScreen()
        .settingsPreviewEnvironment(
            SettingsPreviewSupport.preferences(appearance: .dark, language: .english), notifications: .denied
        )
        .previewShell(.english, scheme: .dark)
}
