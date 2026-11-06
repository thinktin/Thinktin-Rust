import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 设置、多语言与开源许可（WBS 12.12）的界面：每个页面在浅色中文、深色英文下都能布局，外观偏好对应的深浅色，
/// 根视图的 `.settingsPreferences()`。逻辑（分组、入口、语言同步、清单解析）在 ThinktinKitTests/Settings 里测。
@MainActor
@Suite("设置的界面")
struct SettingsScreensTests {
    /// 浅色中文、深色英文各布局一次（放进带 Mock 的应用框架环境；偏好只在内存里，通知权限固定）。
    private func layoutBoth(_ view: some View, client: (any ClientProtocol)? = nil) {
        hostAndLayout(view.settingsPreviewEnvironment().previewShell(client: client))
        hostAndLayout(
            view.settingsPreviewEnvironment(notifications: .denied).previewShell(
                .english, scheme: .dark, client: client))
    }

    @Test("接入点：设置中心、关于、开源许可")
    func destinations() {
        layoutBoth(SettingsDestination(route: .settings))
        layoutBoth(SettingsDestination(route: .about))
        layoutBoth(SettingsDestination(route: .licenses))
        layoutBoth(SettingsDestination(route: .licenses).environment(\.licensesDirectory, nil))
    }

    @Test("实时活动（12.10）：运行页的按钮（含系统设置里关了）")
    func liveActivities() async throws {
        let mock = ShellPreviewClients.signedIn()
        let model = LiveActivityModel(client: mock, system: NoLiveActivities(), defaults: nil)
        let run = try await mock.getRun(DemoData.postRunID)
        layoutBoth(LiveActivityRunButton(model: model, run: run, title: "写手"), client: mock)
        await model.resume()
        #expect(model.isSystemDisabled)
        layoutBoth(LiveActivityRunButton(model: model, run: run, title: "写手"), client: mock)
    }

    @Test("设置根页（参考 53、70、75）：版本区、账号行、普通行、链接行")
    func root() {
        let mock = ShellPreviewClients.signedIn()
        layoutBoth(SettingsScreen(), client: mock)
        layoutBoth(SettingsProfileRow(title: "张三", subtitle: "138****8000"))
        layoutBoth(SettingsProfileRow(title: "ThinkTin", subtitle: nil))
        layoutBoth(SettingsVersionFooter(footer: ("ThinkTin", "0.1.0（1）")))
        layoutBoth(List { SettingsRowLabel(title: "用量", subtitle: nil, value: "今天 1.2 万") })
        layoutBoth(List { ExternalLinkRow(title: "隐私政策", url: LegalLinks.privacyPolicy) })
    }

    @Test("子页面：外观（方块）、语言（含没同步上）、触感反馈")
    func displayPages() async {
        layoutBoth(AppearanceSettingsView(preferences: SettingsPreviewSupport.preferences(appearance: .dark)))
        for option in AppearancePreference.allCases {
            layoutBoth(
                AppearanceTile(
                    title: option.title(.chinese), systemImage: AppearanceSettingsView.icon(option),
                    isSelected: option == .system, select: {}))
        }
        let haptics = SettingsPreviewSupport.preferences()
        layoutBoth(HapticsSettingsView(preferences: haptics))
        haptics.setHapticsEnabled(false)
        layoutBoth(HapticsSettingsView(preferences: haptics))
        let mock = ShellPreviewClients.signedIn()
        let model = LanguageSettingsModel(
            client: mock, preferences: SettingsPreviewSupport.preferences(language: .english), user: mock.state.user)
        layoutBoth(LanguageSettingsView(model: model), client: mock)
        // 只让 setLocale 失败：`failNext(with:)` 会被别的调用（视图挂上去后后台的请求）先用掉，Xcode 上偶尔不过。
        mock.failNext("setLocale(_:)", with: .network(message: "offline"))
        await model.retrySync()
        #expect(model.syncError?.isOffline == true)
        layoutBoth(LanguageSettingsView(model: model), client: mock)
    }

    @Test("关于：没有备案号、有备案号")
    func about() {
        layoutBoth(AboutScreen(appInfo: AppInfo(version: "0.1.0", build: "1")))
        layoutBoth(AboutScreen(appInfo: AppInfo(version: "1.0.0", build: "9", icpFilingNumber: "京ICP备00000000号-1A")))
    }

    @Test("开源许可的子页面：组件详情、原文、agent 许可证卡片")
    func licensePages() {
        layoutBoth(LicenseComponentView(component: LicensesPreviewData.component, directory: nil))
        layoutBoth(LicenseTextView(title: "LICENSE", path: "texts/missing", directory: nil))
        for agent in DemoData.agents {
            renderInBothAppearances(AgentLicenseCard(entry: AgentLicenseEntry(agent: agent, language: .chinese)))
        }
        let group = LicenseGroup(license: "Apache-2.0 OR MIT", components: [LicensesPreviewData.component])
        renderInBothAppearances(LicenseGroupHeader(group: group, isExpanded: false))
        renderInBothAppearances(LicenseComponentRow(component: LicensesPreviewData.component))
    }

    @Test("外观偏好对应的深浅色：跟随系统不设")
    func colorScheme() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }

    @Test("根视图套上 .settingsPreferences() 能布局；触感开关进环境")
    func rootScope() {
        let prefs = SettingsPreviewSupport.preferences(appearance: .dark, language: .english)
        prefs.setHapticsEnabled(false)
        let model = AppModel(client: ShellPreviewClients.signedIn(), defaults: nil)
        hostAndLayout(RootView(model: model).settingsPreferences(prefs))
        hostAndLayout(Text("x").appFeedback(.success, trigger: 1).environment(\.hapticsEnabled, false))
        #expect(EnvironmentValues().hapticsEnabled)
    }

    @Test("通知权限：只有 App 包里才去问系统")
    func notificationBundle() async {
        #expect(
            SystemNotificationPermission.isAppBundle(URL(fileURLWithPath: "/x/ThinkTin.app"), identifier: "cn.thinktin")
        )
        #expect(!SystemNotificationPermission.isAppBundle(URL(fileURLWithPath: "/x/ThinkTin.app"), identifier: nil))
        #expect(!SystemNotificationPermission.isAppBundle(URL(fileURLWithPath: "/x/Tests.xctest"), identifier: "a.b"))
        #expect(!SystemNotificationPermission.isAppBundle(URL(fileURLWithPath: "/usr/bin"), identifier: "a.b"))
        #expect(await FixedNotificationPermission(.denied).currentPermission() == .denied)
    }
}

/// 系统设置里关掉了实时活动的设备。
private struct NoLiveActivities: LiveActivityControlling {
    func areActivitiesEnabled() async -> Bool { false }
    func openActivities() async -> [LiveActivityRun] { [] }
    func start(_ activity: LiveActivityRun) async -> Bool { false }
    func update(runID: RunID, state: RunActivityContentState) async {}
    func end(runID: RunID, state: RunActivityContentState?, immediately: Bool) async {}
}
