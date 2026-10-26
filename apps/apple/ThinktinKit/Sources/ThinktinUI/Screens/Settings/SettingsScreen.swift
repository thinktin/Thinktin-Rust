import SwiftUI
import ThinktinKit

/// 设置中心（WBS 12.12，`.settings`；入口是抽屉底部的头像）：头像和名字，下面一组组入口。版式参考 Claude iOS App 的
/// 设置页。分组和每一行去哪由 `SettingsModel.sections(_:)` 定（ThinktinKit 里测）：别的功能的页面压栈（`AppRoute`），
/// 外观、语言是本功能的子页面，通知跳系统设置，退出登录、注销、全部停止用 12.2 的做法。
///
/// 设置中心不联网也能用（`OfflinePolicy.local`，没有离线横幅）：要联网的操作（注销、全部停止）离线时禁用。
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
        AccountScrollPage {
            header
            if let signOutError {
                ErrorBanner(signOutError, onDismiss: { self.signOutError = nil })
            }
            ForEach(model.sections(language)) { section in
                AccountSection(section.title, footer: section.footer) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { AccountRowDivider() }
                        rowView(row)
                    }
                }
            }
            // 实时活动（12.10，只在支持的设备上有）。
            if let live = app.liveActivities {
                LiveActivitySettingsSection(model: live)
            }
            SettingsFootnote(text: model.appInfo.footer(language))
        }
        .settingsNavigationTitle(AppRoute.settings.title(language))
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

    /// 头像、名字、打码的手机号；点了进账号页。
    private var header: some View {
        let zh = language == .chinese
        let name = model.user?.nameForDisplay ?? ""
        return NavigationLink(value: AppRoute.account) {
            HStack(spacing: Metrics.Spacing.m) {
                AccountAvatar(name: name.isEmpty ? AppInfo.appName : name)
                VStack(alignment: .leading, spacing: Metrics.Spacing.unit / 2) {
                    Text(name.isEmpty ? AppRoute.account.title(language) : name)
                        .typography(.title2)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    if !model.maskedPhone.isEmpty {
                        Text(verbatim: model.maskedPhone)
                            .font(Typography.subheadline.font.monospacedDigit())
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Typography.footnote.font.weight(.semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(zh ? "打开账号页" : "Opens your account"))
    }

    @ViewBuilder
    private func rowView(_ row: SettingsRow) -> some View {
        let zh = language == .chinese
        let disabledOffline = row.needsNetwork && app.isOffline
        switch row.action {
        case .open(let route)?:
            NavigationLink(value: route) { label(row, chevron: true) }
                .buttonStyle(.plain)
        case .appearance?:
            NavigationLink {
                AppearanceSettingsView(preferences: model.preferences)
            } label: {
                label(row, chevron: true)
            }
            .buttonStyle(.plain)
        case .language?:
            NavigationLink {
                LanguageSettingsView(
                    model: LanguageSettingsModel(client: client, preferences: model.preferences, user: model.user))
            } label: {
                label(row, chevron: true)
            }
            .buttonStyle(.plain)
        case .systemNotificationSettings?:
            if let url = SystemSettingsLink.notifications {
                Link(destination: url) {
                    AccountRow(
                        systemImage: row.systemImage, title: row.title, subtitle: row.subtitle, value: row.value,
                        showsChevron: false)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(zh ? "打开系统设置" : "Opens Settings"))
            } else {
                label(row, chevron: false)
            }
        case .signOut?:
            Button {
                confirmsSignOut = true
            } label: {
                HStack {
                    label(row, chevron: false)
                    if isSigningOut {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, Metrics.Spacing.m)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut)
        case .deleteAccount?:
            NavigationLink {
                DeleteAccountView(client: client, maskedPhone: model.maskedPhone)
            } label: {
                label(row, chevron: true)
            }
            .buttonStyle(.plain)
            .disabled(disabledOffline)
        case .stopAll?:
            // 12.2 的那一行：二次确认、结果弹窗、刷新角标、离线禁用都在里面。
            StopAllRow(model: stopAll)
        case nil:
            label(row, chevron: false)
        }
    }

    private func label(_ row: SettingsRow, chevron: Bool) -> some View {
        AccountRow(
            systemImage: row.systemImage, title: row.title, subtitle: row.subtitle, value: row.value,
            tone: row.isDestructive ? .destructive : .normal, showsChevron: chevron)
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
