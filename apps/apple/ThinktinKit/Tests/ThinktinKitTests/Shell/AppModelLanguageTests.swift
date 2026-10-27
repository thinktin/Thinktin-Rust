import Foundation
import Testing

@testable import ThinktinKit

// 应用框架接上 12.12 的语言：启动时最先换请求语言（没登录也换，新用户按界面语言注册），确认完账号、登录成功、解冻之后
// 比较服务端的用户语言和界面语言，不一致才调 setLocale（LanguageSettingsModel.syncOnLaunch）；失败不挡启动。
// 别的页面拿到的新用户（setLocale、updateProfile、me）换进 AppModel.user（ClientActivity.userUpdated）。
// 演示数据的用户语言是中文（zh-CN）。

@MainActor
@Suite("应用框架：界面语言和服务端同步（12.12）")
struct AppModelLanguageTests {
    private func make(signedIn: Bool = true, system: DisplayLanguage) -> (MockClient, AppModel) {
        let mock = makeShellMock(signedIn: signedIn)
        let prefs = SettingsPreferences(defaults: nil, systemLanguage: { system })
        return (mock, AppModel(client: mock, defaults: nil, preferences: prefs))
    }

    @Test("启动：界面语言和 me().locale 不一致，调一次 setLocale，用户换成改过的")
    func launchOutOfSync() async {
        let (mock, model) = make(system: .english)
        #expect(mock.state.user.locale == .zhCN)
        await model.start()
        #expect(mock.callCount("setLocale(_:)") == 1)
        #expect(mock.state.user.locale == .en)
        #expect(model.user?.locale == .en)
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)
        // 照常刷新。
        #expect(model.phase == .signedIn)
        #expect(model.instances.count == 2)
    }

    @Test("启动：一致时不调 setLocale")
    func launchInSync() async {
        let (mock, model) = make(system: .chinese)
        await model.start()
        #expect(mock.callCount("me()") == 1, "用确认账号时拿到的用户，不另外调 me()")
        #expect(mock.callCount("setLocale(_:)") == 0)
        #expect(model.user?.locale == .zhCN)
        #expect(mock.state.acceptLanguage?.hasPrefix("zh-CN") == true)
    }

    @Test("设置里固定选了中文：系统是英文也按中文，不调 setLocale")
    func fixedLanguage() async {
        let mock = makeShellMock()
        let prefs = SettingsPreferences(defaults: nil, systemLanguage: { .english })
        prefs.setLanguage(.chinese)
        let model = AppModel(client: mock, defaults: nil, preferences: prefs)
        await model.start()
        #expect(mock.callCount("setLocale(_:)") == 0)
        #expect(mock.state.acceptLanguage?.hasPrefix("zh-CN") == true)
    }

    @Test("没登录：启动时最先换请求语言，不调 me、setLocale；新用户按界面语言注册，登录后也不用改")
    func signedOutNewUser() async throws {
        let (mock, model) = make(signedIn: false, system: .english)
        await model.start()
        #expect(model.phase == .signedOut)
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)
        #expect(mock.callCount("me()") == 0 && mock.callCount("setLocale(_:)") == 0)

        _ = try await model.client.login(phone: "+8613900139000", code: mock.state.verificationCode)
        #expect(await eventually { model.phase == .signedIn && model.instances.count == 2 })
        #expect(model.user?.locale == .en, "Mock 和服务端一样按 Accept-Language 定新用户的语言")
        #expect(mock.callCount("setLocale(_:)") == 0)
    }

    @Test("登录老用户、语言不一致：登录后调一次 setLocale")
    func signInOutOfSync() async throws {
        let (mock, model) = make(signedIn: false, system: .english)
        await model.start()
        _ = try await model.client.login(phone: "+8613800138000", code: mock.state.verificationCode)
        #expect(await eventually { model.phase == .signedIn && model.user?.locale == .en })
        #expect(mock.callCount("setLocale(_:)") == 1)
        #expect(mock.state.user.locale == .en)
    }

    @Test("账号冻结时不同步")
    func frozen() async {
        let (mock, model) = make(system: .english)
        mock.update { $0.user.status = .frozen }
        await model.start()
        #expect(model.phase == .frozen)
        #expect(mock.callCount("setLocale(_:)") == 0)
        // 请求语言不联网，照样换上。
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)
    }

    @Test("启动时 me() 拿不到（离线）：不再多等一次 me()、不调 setLocale，照常刷新")
    func launchOffline() async {
        let (mock, model) = make(system: .english)
        mock.failNext("me()", with: .network(message: "offline"))
        await model.start()
        #expect(mock.callCount("me()") == 1)
        #expect(mock.callCount("setLocale(_:)") == 0)
        #expect(model.phase == .signedIn)
        #expect(model.instances.count == 2, "实例照样刷新")
        // 请求语言不联网，照样换上。
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)
    }

    @Test("setLocale 失败不挡启动：静默，照常刷新，用户还是服务端原来的语言")
    func launchSyncFails() async {
        let (mock, model) = make(system: .english)
        mock.failNext(
            "setLocale(_:)", with: .api(status: 503, code: .unavailable, message: "busy", retryAfterSecs: nil))
        await model.start()
        #expect(mock.callCount("setLocale(_:)") == 1)
        #expect(model.phase == .signedIn)
        #expect(model.instances.count == 2)
        #expect(model.user?.locale == .zhCN)
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)
    }

    @Test("冻结着启动：解冻后同步一次")
    func syncAfterUnfreeze() async {
        let (mock, model) = make(system: .english)
        mock.update { $0.user.status = .frozen }
        await model.start()
        #expect(model.phase == .frozen)
        mock.update { $0.user.status = .active }
        await model.recheckAccount()
        #expect(model.phase == .signedIn)
        #expect(mock.callCount("setLocale(_:)") == 1)
        #expect(model.user?.locale == .en)
    }

    @Test("设置里换了语言：AppModel.user 跟上，再进语言页拿到的是新的，换回来照样同步")
    func settingsChangeUpdatesUser() async {
        let mock = makeShellMock()
        let prefs = SettingsPreferences(defaults: nil, systemLanguage: { .chinese })
        let model = AppModel(client: mock, defaults: nil, preferences: prefs)
        await model.start()
        #expect(mock.callCount("setLocale(_:)") == 0)

        // 语言页每次进来都按 AppModel.user 新建（SettingsScreen）。
        await LanguageSettingsModel(client: model.client, preferences: prefs, user: model.user).select(.english)
        #expect(mock.state.user.locale == .en)
        #expect(await eventually { model.user?.locale == .en })

        let again = LanguageSettingsModel(client: model.client, preferences: prefs, user: model.user)
        await again.select(.chinese)
        #expect(mock.callCount("setLocale(_:)") == 2, "拿的是新的用户：服务端是英文，要改回中文")
        #expect(mock.state.user.locale == .zhCN)
        #expect(await eventually { model.user?.locale == .zhCN })
    }

    @Test("别的页面改了昵称、拉了 me()：AppModel.user 换成新的；退出登录后的不要")
    func userUpdates() async throws {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        _ = try await model.client.updateProfile(displayName: "新名字")
        #expect(await eventually { model.user?.displayName == "新名字" })

        try await model.signOut()
        #expect(model.phase == .signedOut && model.user == nil)
        // 本地又有了会话（不经过登录），这时拉到的用户也不换上。
        mock.update { $0.session = DemoData.state().session }
        _ = try await model.client.me()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.user == nil, "没登录时不换上")
    }

    @Test("没传偏好（测试、预览）：不换请求语言，也不同步")
    func withoutPreferences() async {
        let mock = makeShellMock()
        let model = AppModel(client: mock, defaults: nil)
        await model.start()
        #expect(mock.callCount("setAcceptLanguage(_:)") == 0)
        #expect(mock.callCount("setLocale(_:)") == 0)
        #expect(model.user?.locale == .zhCN)
    }
}
