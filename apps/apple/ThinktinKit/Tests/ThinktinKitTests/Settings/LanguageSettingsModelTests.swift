import Foundation
import Testing

@testable import ThinktinKit

// 语言（WBS 12.12）：App 里选语言时 setLocale + setAcceptLanguage(for:)，启动时比较 me().locale 和界面语言。
//
// MockClient 的 `failNext` 排的错误给下一次任何调用（包括不联网的 setAcceptLanguage）。这里的顺序是先 me / setLocale、
// 最后才换请求语言，所以“排了一个错误、却没有 syncError”说明没有调 setLocale。

@MainActor
@Suite("语言与服务端同步")
struct LanguageSettingsModelTests {
    private func make(system: DisplayLanguage = .chinese) -> (MockClient, SettingsPreferences, LanguageSettingsModel) {
        let mock = makeShellMock()
        let prefs = SettingsFixture.preferences(system: system)
        return (mock, prefs, LanguageSettingsModel(client: mock, preferences: prefs, user: mock.state.user))
    }

    // MARK: 选语言

    @Test("选英文：界面马上换，服务端的语言和请求语言跟上")
    func selectEnglish() async {
        let (mock, prefs, model) = make()
        #expect(mock.state.user.locale == .zhCN)
        #expect(model.serverLocale == .zhCN)
        #expect(!model.isOutOfSync)

        await model.select(.english)
        #expect(prefs.language == .english)
        #expect(model.displayLanguage == .english)
        #expect(mock.state.user.locale == .en)
        #expect(model.serverLocale == .en)
        #expect(model.syncError == nil)
        #expect(!model.isSyncing)
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)

        await model.select(.system)
        #expect(mock.state.user.locale == .zhCN)
        #expect(mock.state.acceptLanguage?.hasPrefix("zh-CN") == true)
    }

    @Test("界面语言没变、服务端已经一致：不调 setLocale，只换请求语言")
    func selectWithoutChange() async {
        let (mock, prefs, model) = make(system: .chinese)
        mock.failNext(with: .network(message: "should not be used by setLocale"))
        await model.select(.chinese)
        #expect(prefs.language == .chinese)
        #expect(model.syncError == nil)
        #expect(mock.state.user.locale == .zhCN)
        // 排的错误被请求语言那一下用掉了；再选一次，请求语言照样换上。
        await model.select(.chinese)
        #expect(mock.state.acceptLanguage?.hasPrefix("zh-CN") == true)
    }

    @Test("离线时选的：界面照样换，提示没同步上；重试成功后清掉")
    func selectOffline() async {
        let (mock, prefs, model) = make()
        mock.failNext(with: .network(message: "offline"))
        await model.select(.english)
        #expect(prefs.language == .english)
        #expect(model.displayLanguage == .english)
        #expect(model.syncError?.isOffline == true)
        #expect(model.isOutOfSync)
        #expect(mock.state.user.locale == .zhCN)
        // 请求语言不联网，照样换上。
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)

        await model.retrySync()
        #expect(model.syncError == nil)
        #expect(!model.isOutOfSync)
        #expect(mock.state.user.locale == .en)

        mock.failNext(with: .network(message: "offline"))
        await model.select(.chinese)
        #expect(model.syncError != nil)
        model.dismissError()
        #expect(model.syncError == nil)
    }

    @Test("同步还没回来又换了语言：回来后再改一次，最后和界面一致")
    func changeWhileSyncing() async {
        let mock = MockClient(state: DemoData.state(), latency: 0.05, stepDelay: 0, autoReply: false)
        let prefs = SettingsFixture.preferences(system: .chinese)
        let model = LanguageSettingsModel(client: mock, preferences: prefs, user: mock.state.user)
        let first = Task { await model.select(.english) }
        #expect(await eventually { model.isSyncing })
        await model.select(.chinese)
        await first.value
        #expect(!model.isSyncing)
        #expect(model.displayLanguage == .chinese)
        #expect(model.serverLocale == .zhCN)
        #expect(mock.state.user.locale == .zhCN)
        #expect(!model.isOutOfSync)
        #expect(mock.state.acceptLanguage?.hasPrefix("zh-CN") == true)
    }

    @Test("不知道服务端的语言时，选了就调一次 setLocale")
    func unknownServerLocale() async {
        let mock = makeShellMock()
        let prefs = SettingsFixture.preferences(system: .chinese)
        let model = LanguageSettingsModel(client: mock, preferences: prefs)
        #expect(model.serverLocale == nil)
        #expect(!model.isOutOfSync)
        mock.failNext(with: .network(message: "offline"))
        await model.select(.chinese)
        #expect(model.syncError?.isOffline == true)
    }

    // MARK: 启动时

    @Test("启动：服务端是中文、界面是英文，调 setLocale；返回改过的用户")
    func launchMismatch() async {
        let (mock, prefs, model) = make()
        prefs.setLanguage(.english)
        let user = await model.syncOnLaunch(user: mock.state.user)
        #expect(user?.locale == .en)
        #expect(mock.state.user.locale == .en)
        #expect(model.serverLocale == .en)
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)
    }

    @Test("启动：没给用户就自己调 me()")
    func launchFetchesUser() async {
        let mock = makeShellMock()
        let prefs = SettingsFixture.preferences(system: .english)
        let model = LanguageSettingsModel(client: mock, preferences: prefs)
        let user = await model.syncOnLaunch(user: nil)
        #expect(user?.id == DemoData.userID)
        #expect(user?.locale == .en)
        #expect(mock.state.user.locale == .en)
    }

    @Test("启动：已经一致就不调 setLocale")
    func launchInSync() async {
        let (mock, _, model) = make(system: .chinese)
        let known = mock.state.user
        mock.failNext(with: .network(message: "should not be used by setLocale"))
        let user = await model.syncOnLaunch(user: known)
        #expect(user == known)
        #expect(model.syncError == nil)
        #expect(mock.state.user.locale == .zhCN)
    }

    @Test("启动：服务端存的是认不出的语言，也改成界面语言")
    func launchUnknownServerLocale() async {
        let (mock, _, model) = make(system: .chinese)
        var known = mock.state.user
        known.locale = .unknown("ja")
        #expect(LanguageSettingsModel.needsSync(serverLocale: .unknown("ja"), displayLanguage: .chinese))
        #expect(!LanguageSettingsModel.needsSync(serverLocale: .en, displayLanguage: .english))
        let user = await model.syncOnLaunch(user: known)
        #expect(user?.locale == .zhCN)
    }

    @Test("启动：网络不通、setLocale 失败都静默，返回原来的用户；下次再试")
    func launchFailures() async {
        let (mock, prefs, model) = make()
        prefs.setLanguage(.english)

        mock.failNext(with: .network(message: "offline"))
        let fetched = await LanguageSettingsModel(client: mock, preferences: prefs).syncOnLaunch(user: nil)
        #expect(fetched == nil)
        #expect(mock.state.user.locale == .zhCN)

        let known = mock.state.user
        mock.failNext(with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        let kept = await model.syncOnLaunch(user: known)
        #expect(kept == known)
        #expect(model.syncError == nil)
        #expect(mock.state.user.locale == .zhCN)

        let retried = await model.syncOnLaunch(user: known)
        #expect(retried?.locale == .en)
    }

    @Test("启动：没登录时不联网，只换请求语言（新用户注册时服务端按它定语言）")
    func launchSignedOut() async {
        let mock = makeShellMock(signedIn: false)
        let prefs = SettingsFixture.preferences(system: .chinese)
        prefs.setLanguage(.english)
        let model = LanguageSettingsModel(client: mock, preferences: prefs)
        let user = await model.syncOnLaunch(user: nil)
        #expect(user == nil)
        #expect(mock.state.acceptLanguage?.hasPrefix("en") == true)

        prefs.setLanguage(.chinese)
        model.applyAcceptLanguage()
        #expect(mock.state.acceptLanguage?.hasPrefix("zh-CN") == true)
    }

    @Test("经过应用框架的客户端（ObservedClient）也一样")
    func throughAppModel() async {
        let mock = makeShellMock()
        let app = AppModel(client: mock, defaults: nil)
        let prefs = SettingsFixture.preferences(system: .english)
        let model = LanguageSettingsModel(client: app.client, preferences: prefs, user: mock.state.user)
        let user = await model.syncOnLaunch(user: mock.state.user)
        #expect(user?.locale == .en)
        #expect(mock.state.user.locale == .en)
    }

    @Test("说明文字中英文都有")
    func texts() {
        #expect(LanguageSettingsModel.footnote(.chinese).contains("推送"))
        #expect(LanguageSettingsModel.footnote(.english).contains("Notifications"))
        #expect(LanguageSettingsModel.syncFailedMessage(.chinese).contains("重试"))
        #expect(LanguageSettingsModel.syncFailedMessage(.english).contains("Retry"))
    }
}
