import Foundation
import Testing

@testable import ThinktinKit

// 设置中心（WBS 12.12）：分组和入口（跳到各功能的 AppRoute）、通知权限、版本号、关于页的文案。

@MainActor
@Suite("设置中心")
struct SettingsModelTests {
    private func make(
        permission: NotificationPermission = .authorized, user: User? = nil
    ) -> (MockClient, SettingsModel) {
        let mock = makeShellMock()
        let model = SettingsModel(
            client: mock, user: user ?? mock.state.user, preferences: SettingsFixture.preferences(),
            notifications: FixedNotificationPermission(permission), appInfo: AppInfo(version: "0.1.0", build: "7"))
        return (mock, model)
    }

    private func row(_ id: String, in sections: [SettingsSection]) -> SettingsRow? {
        sections.flatMap(\.rows).first { $0.id == id }
    }

    @Test("分组的顺序照参考 53、70、75：账号、连接、Botin、偏好、安全、链接、关于、退出登录")
    func sectionOrder() {
        let (_, model) = make()
        #expect(model.sections(.chinese).map(\.id) == SettingsSection.ID.allCases)
        // 参考里只有“Bot”那一组有标题；ThinkTin 多出来的“安全”也带标题。
        #expect(model.sections(.chinese).map(\.title) == [nil, nil, "Botin", nil, "安全", nil, nil, nil])
        #expect(model.sections(.english).first { $0.id == .security }?.title == "Security")
        let ids = model.sections(.chinese).map { $0.rows.map(\.id) }
        #expect(
            ids == [
                ["account", "credentials", "usage", "vault"], ["connections"], ["approvals", "devices"],
                ["notifications", "appearance", "language", "haptics"], ["stopAll", "signOutOthers"],
                ["terms", "privacy"], ["about", "licenses", "onboarding"], ["signOut"],
            ])
    }

    @Test("入口跳到各功能自己的页面（12.2、12.4、12.13、12.14、12.15、本功能）")
    func routes() {
        let (_, model) = make()
        let sections = model.sections(.chinese)
        let expected: [String: (AppRoute, AppFeature)] = [
            "account": (.account, .account), "devices": (.devices, .account), "credentials": (.credentials, .models),
            "usage": (.usage, .models), "vault": (.vault, .vault),
            "connections": (.connections(category: nil), .connections),
            "approvals": (.approvals, .approvals), "signOutOthers": (.devices, .account),
            "about": (.about, .settings), "licenses": (.licenses, .settings),
        ]
        for (id, (route, feature)) in expected {
            #expect(row(id, in: sections)?.route == route, "\(id)")
            #expect(route.feature == feature)
            // 设置中心进去的页面都是压栈的（不是 sheet、不是整页状态）。
            #expect(route.presentation == .push)
        }
        #expect(row("appearance", in: sections)?.action == .appearance)
        #expect(row("language", in: sections)?.action == .language)
        #expect(row("haptics", in: sections)?.action == .haptics)
        #expect(row("notifications", in: sections)?.action == .systemNotificationSettings)
        #expect(row("terms", in: sections)?.action == .link(LegalLinks.termsOfService))
        #expect(row("privacy", in: sections)?.action == .link(LegalLinks.privacyPolicy))
        #expect(row("signOut", in: sections)?.action == .signOut)
        #expect(row("stopAll", in: sections)?.action == .stopAll)
        // 注销账号挪进账号页（参考 54），根页不放。
        #expect(row("deleteAccount", in: sections) == nil)
        // 行的 id 不重复。
        let ids = sections.flatMap(\.rows).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(AppRoute.settings.offlinePolicy == .local)
    }

    @Test("危险操作和要联网的")
    func flags() {
        let (_, model) = make()
        let sections = model.sections(.chinese)
        #expect(row("stopAll", in: sections)?.isDestructive == true)
        #expect(row("stopAll", in: sections)?.needsNetwork == true)
        // 退出登录是红字（参考 75），离线也能做（本地照样清掉，`AppModel.signOut()`）。
        #expect(row("signOut", in: sections)?.needsNetwork == false)
        #expect(row("signOut", in: sections)?.isDestructive == true)
        #expect(sections.flatMap(\.rows).filter(\.isProfile).map(\.id) == ["account"])
    }

    @Test("账号行：昵称、打码的手机号；没昵称时写打码的手机号")
    func account() {
        let (mock, model) = make()
        let sections = model.sections(.chinese)
        #expect(row("account", in: sections)?.title == "张三")
        #expect(row("account", in: sections)?.subtitle == "138****8000")
        #expect(model.maskedPhone == "138****8000")

        var unnamed = mock.state.user
        unnamed.displayName = nil
        let (_, other) = make(user: unnamed)
        #expect(row("account", in: other.sections(.chinese))?.title == unnamed.nameForDisplay)
    }

    @Test("审批一行：有等你批准的写条数，没有时说明")
    func approvals() {
        let (_, model) = make()
        #expect(row("approvals", in: model.sections(.chinese, pendingApprovals: 2))?.subtitle == "2 条等你批准")
        #expect(row("approvals", in: model.sections(.english, pendingApprovals: 1))?.subtitle == "1 waiting for you")
        #expect(row("approvals", in: model.sections(.english, pendingApprovals: 3))?.subtitle == "3 waiting for you")
        #expect(row("approvals", in: model.sections(.chinese))?.subtitle == "Botin 做有风险的操作前先问你")
    }

    @Test("用量一行：今天的用量拉到之前没有值，离线时留着原来的")
    func usageValue() async {
        let (mock, model) = make()
        #expect(row("usage", in: model.sections(.chinese))?.value == nil)
        await model.refreshUsage()
        let total = model.todayUsage?.total.totalTokens ?? -1
        #expect(total >= 0)
        #expect(
            row("usage", in: model.sections(.chinese))?.value == "今天 " + Formatting.tokens(total, language: .chinese))
        mock.failNext(with: .network(message: "offline"))
        await model.refreshUsage()
        #expect(model.todayUsage?.total.totalTokens == total)
    }

    @Test("版本区：名字和版本（构建号）")
    func versionFooter() {
        let (_, model) = make()
        #expect(model.versionFooter(.chinese) == ("ThinkTin", "0.1.0（7）"))
        #expect(model.versionFooter(.english).version == "0.1.0 (7)")
    }

    @Test("通知：读到权限之前没有值，读到之后显示状态和说明")
    func notifications() async {
        let (_, model) = make(permission: .denied)
        #expect(model.notificationPermission == nil)
        #expect(row("notifications", in: model.sections(.chinese))?.value == nil)
        #expect(model.sections(.chinese).first { $0.id == .preferences }?.footer == nil)
        await model.refreshNotificationPermission()
        #expect(model.notificationPermission == .denied)
        #expect(row("notifications", in: model.sections(.chinese))?.value == "已关闭")
        #expect(model.sections(.chinese).first { $0.id == .preferences }?.footer?.contains("系统设置") == true)
    }

    @Test("刷新：静默拉最新的用户；离线时留着原来的")
    func refresh() async {
        let (mock, model) = make()
        mock.update { $0.user.displayName = "李四" }
        await model.refresh()
        #expect(model.user?.displayName == "李四")
        #expect(model.notificationPermission == .authorized)

        mock.update { $0.user.displayName = "王五" }
        mock.failNext(with: .network(message: "offline"))
        await model.refreshUser()
        #expect(model.user?.displayName == "李四")

        var renamed = mock.state.user
        renamed.displayName = "赵六"
        model.apply(renamed)
        #expect(model.user?.displayName == "赵六")
        model.apply(nil)
        #expect(model.user?.displayName == "赵六")
    }

    @Test("外观、语言、触感那几行显示当前选的")
    func displayRows() {
        let (_, model) = make()
        #expect(row("appearance", in: model.sections(.chinese))?.value == "跟随系统")
        #expect(row("language", in: model.sections(.chinese))?.value == "跟随系统（中文）")
        #expect(row("haptics", in: model.sections(.chinese))?.value == "开启")
        model.preferences.setAppearance(.dark)
        model.preferences.setLanguage(.english)
        model.preferences.setHapticsEnabled(false)
        #expect(row("appearance", in: model.sections(.english))?.value == "Dark")
        #expect(row("language", in: model.sections(.english))?.value == "English")
        #expect(row("haptics", in: model.sections(.english))?.value == "Off")
    }

    // MARK: 通知权限

    @Test("通知权限：能不能送到、每种状态的文案都不一样")
    func permission() async {
        #expect(NotificationPermission.authorized.canDeliver)
        #expect(NotificationPermission.provisional.canDeliver)
        #expect(!NotificationPermission.denied.canDeliver)
        #expect(!NotificationPermission.notDetermined.canDeliver)
        #expect(!NotificationPermission.unknown.canDeliver)
        let all: [NotificationPermission] = [.notDetermined, .denied, .authorized, .provisional, .unknown]
        for language in DisplayLanguage.allCases {
            #expect(Set(all.map { $0.title(language) }).count == all.count)
            #expect(Set(all.map { $0.detail(language) }).count == all.count)
        }
        #expect(await FixedNotificationPermission(.provisional).currentPermission() == .provisional)
    }

    // MARK: 版本号与关于

    @Test("版本号、构建号从 Info.plist 读；没有或没展开时是“—”")
    func appInfo() {
        let info = AppInfo(infoDictionary: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": " 45 "])
        #expect(info.version == "1.2.3")
        #expect(info.build == "45")
        #expect(info.versionText(.chinese) == "1.2.3（45）")
        #expect(info.versionText(.english) == "1.2.3 (45)")
        #expect(info.footer(.english) == "ThinkTin 1.2.3 (45)")

        let missing = AppInfo(infoDictionary: ["CFBundleShortVersionString": "$(MARKETING_VERSION)"])
        #expect(missing.version == "—")
        #expect(missing.build == "—")
        #expect(AppInfo(infoDictionary: nil).version == "—")
        #expect(AppInfo(infoDictionary: ["CFBundleVersion": 3]).build == "—")
    }

    @Test("备案号：办下来之前显示办理中，办下来后显示号码")
    func icpFiling() {
        let pending = AppInfo(version: "0.1.0", build: "1", icpFilingNumber: nil)
        #expect(!pending.hasICPFiling)
        #expect(pending.icpFilingText(.chinese) == "办理中")
        #expect(pending.icpFilingText(.english) == "Pending")
        #expect(!AppInfo(version: "0.1.0", build: "1", icpFilingNumber: "  ").hasICPFiling)

        let filed = AppInfo(version: "0.1.0", build: "1", icpFilingNumber: "京ICP备12345678号-1A")
        #expect(filed.hasICPFiling)
        #expect(filed.icpFilingText(.english) == "京ICP备12345678号-1A")
        #expect(AppInfo.icpLookupURL.scheme == "https")
    }

    @Test("AI 生成内容说明：标识文字和服务端一致，中英文都有")
    func aiContent() {
        for language in DisplayLanguage.allCases {
            let paragraphs = AboutText.aiContentParagraphs(language)
            #expect(paragraphs.count >= 3)
            #expect(paragraphs.contains { $0.contains(language.aiGeneratedLabel) })
            #expect(!AboutText.tagline(language).isEmpty)
        }
        #expect(AboutText.aiContentParagraphs(.chinese).contains { $0.contains("【AI 生成】") })
        #expect(AboutText.aiContentParagraphs(.english).contains { $0.contains("[AI-generated]") })
        // 品牌是 ThinkTin，不出现第三方的名字。
        let all = (AboutText.aiContentParagraphs(.chinese) + AboutText.aiContentParagraphs(.english)).joined()
        #expect(!all.contains("Claude"))
        #expect(!all.contains("Anthropic"))
    }
}
