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

    @Test("分组的顺序：账号、模型 key 与用量、保险箱、通知、外观与语言、安全、关于")
    func sectionOrder() {
        let (_, model) = make()
        #expect(model.sections(.chinese).map(\.id) == SettingsSection.ID.allCases)
        #expect(model.sections(.chinese).map(\.title) == ["账号", "模型 key 与用量", "保险箱", "通知", "外观与语言", "安全", "关于"])
        #expect(model.sections(.english).first?.title == "Account")
    }

    @Test("入口跳到各功能自己的页面（12.2、12.4、12.13、12.14、本功能）")
    func routes() {
        let (_, model) = make()
        let sections = model.sections(.chinese)
        let expected: [String: (AppRoute, AppFeature)] = [
            "name": (.account, .account), "devices": (.devices, .account), "credentials": (.credentials, .models),
            "usage": (.usage, .models), "vault": (.vault, .vault), "imChannels": (.imChannels, .imChannels),
            "signOutOthers": (.devices, .account), "about": (.about, .settings), "licenses": (.licenses, .settings),
        ]
        for (id, (route, feature)) in expected {
            #expect(row(id, in: sections)?.route == route, "\(id)")
            #expect(route.feature == feature)
            // 设置中心进去的页面都是压栈的（不是 sheet、不是整页状态）。
            #expect(route.presentation == .push)
        }
        #expect(row("appearance", in: sections)?.action == .appearance)
        #expect(row("language", in: sections)?.action == .language)
        #expect(row("systemNotifications", in: sections)?.action == .systemNotificationSettings)
        #expect(row("signOut", in: sections)?.action == .signOut)
        #expect(row("deleteAccount", in: sections)?.action == .deleteAccount)
        #expect(row("stopAll", in: sections)?.action == .stopAll)
        // 手机号只读（换手机号还没有接口，ios-packages.md 12.2）。
        #expect(row("phone", in: sections)?.action == nil)
        // 行的 id 不重复。
        let ids = sections.flatMap(\.rows).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(AppRoute.settings.offlinePolicy == .local)
    }

    @Test("危险操作和要联网的")
    func flags() {
        let (_, model) = make()
        let sections = model.sections(.chinese)
        #expect(row("deleteAccount", in: sections)?.isDestructive == true)
        #expect(row("deleteAccount", in: sections)?.needsNetwork == true)
        #expect(row("stopAll", in: sections)?.isDestructive == true)
        #expect(row("stopAll", in: sections)?.needsNetwork == true)
        // 退出登录离线也能做（本地照样清掉，`AppModel.signOut()`）。
        #expect(row("signOut", in: sections)?.needsNetwork == false)
        #expect(row("signOut", in: sections)?.isDestructive == false)
    }

    @Test("账号一栏：昵称、打码的手机号；没昵称时写未设置")
    func account() {
        let (mock, model) = make()
        let sections = model.sections(.chinese)
        #expect(row("name", in: sections)?.value == "张三")
        #expect(row("phone", in: sections)?.value == "138****8000")
        #expect(model.maskedPhone == "138****8000")

        var unnamed = mock.state.user
        unnamed.displayName = nil
        let (_, other) = make(user: unnamed)
        #expect(row("name", in: other.sections(.chinese))?.value == "未设置")
        #expect(row("name", in: other.sections(.english))?.value == "Not set")
    }

    @Test("通知：读到权限之前没有值，读到之后显示状态和说明")
    func notifications() async {
        let (_, model) = make(permission: .denied)
        #expect(model.notificationPermission == nil)
        #expect(row("systemNotifications", in: model.sections(.chinese))?.value == nil)
        #expect(model.sections(.chinese).first { $0.id == .notifications }?.footer == nil)
        await model.refreshNotificationPermission()
        #expect(model.notificationPermission == .denied)
        #expect(row("systemNotifications", in: model.sections(.chinese))?.value == "已关闭")
        #expect(model.sections(.chinese).first { $0.id == .notifications }?.footer?.contains("系统设置") == true)
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

    @Test("外观、语言那两行显示当前选的")
    func displayRows() {
        let (_, model) = make()
        #expect(row("appearance", in: model.sections(.chinese))?.value == "跟随系统")
        #expect(row("language", in: model.sections(.chinese))?.value == "跟随系统（中文）")
        model.preferences.setAppearance(.dark)
        model.preferences.setLanguage(.english)
        #expect(row("appearance", in: model.sections(.english))?.value == "Dark")
        #expect(row("language", in: model.sections(.english))?.value == "English")
        #expect(row("about", in: model.sections(.english))?.value == "0.1.0")
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
