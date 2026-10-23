import Foundation
import Testing

@testable import ThinktinKit

// 账号页、改昵称、注销账号（WBS 12.2）。

@MainActor
@Suite("账号、昵称与注销")
struct AccountModelTests {
    private func make() -> (MockClient, AppModel) {
        let mock = makeShellMock()
        return (mock, AppModel(client: mock, defaults: nil))
    }

    // MARK: 账号页

    @Test("先显示已知的用户，再拉最新的；手机号打码")
    func account() async {
        let (mock, app) = make()
        let stale = User(id: DemoData.userID, phone: "+8613800138000", displayName: "旧名字", createdAt: Fixture.now)
        let model = AccountModel(client: app.client, user: stale)
        #expect(model.user?.displayName == "旧名字")
        #expect(model.maskedPhone == "138****8000")
        await model.load()
        #expect(model.user == mock.state.user)
        #expect(model.loadError == nil)

        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.loadError?.isOffline == true)
        #expect(model.user != nil)

        var renamed = mock.state.user
        renamed.displayName = "李四"
        model.apply(renamed)
        #expect(model.user?.nameForDisplay == "李四")
        #expect(AccountModel(client: app.client).maskedPhone == "")
        #expect(AccountModel.signOutMessage(.chinese).contains("全部停止"))
    }

    // MARK: 昵称

    @Test("昵称：去掉首尾空白；没改不能保存；太长提示上限")
    func displayNameValidation() {
        let (mock, app) = make()
        let model = DisplayNameModel(client: app.client, user: mock.state.user)
        #expect(model.draft == "张三")
        #expect(!model.hasChanges)
        #expect(!model.canSave)
        model.draft = "  张三  "
        #expect(!model.hasChanges)
        model.draft = " 张三丰 "
        #expect(model.normalizedName == "张三丰")
        #expect(model.counterText == "3/64")
        #expect(model.canSave)
        model.draft = String(repeating: "名", count: 65)
        #expect(model.isTooLong)
        #expect(!model.canSave)
        #expect(model.validationMessage(.chinese) == "昵称最多 64 个字。")
        #expect(model.validationMessage(.english) == "Names can be up to 64 characters.")
        model.draft = String(repeating: "名", count: 64)
        #expect(!model.isTooLong)
        #expect(model.validationMessage() == nil)
        // 和服务端一样按 Unicode 标量数：带变体选择符的表情算两个。
        model.draft = "❤️"
        #expect(model.characterCount == 2)
    }

    @Test("保存昵称：服务端改了；清空就是去掉昵称，显示打码的手机号")
    func saveDisplayName() async {
        let (mock, app) = make()
        let model = DisplayNameModel(client: app.client, user: mock.state.user)
        model.draft = "张三丰"
        let saved = await model.save()
        #expect(saved?.displayName == "张三丰")
        #expect(mock.state.user.displayName == "张三丰")
        #expect(model.savedUser == saved)

        let clear = DisplayNameModel(client: app.client, user: mock.state.user)
        clear.draft = "   "
        #expect(clear.normalizedName == nil)
        #expect(clear.canSave)
        let cleared = await clear.save()
        #expect(cleared?.displayName == nil)
        #expect(cleared?.nameForDisplay == "138****8000")

        // 本来就没有昵称、框里也是空的：没改。
        let none = DisplayNameModel(client: app.client, user: cleared)
        #expect(none.draft == "")
        #expect(!none.hasChanges)
        #expect(await none.save() == nil)
    }

    @Test("保存昵称失败：提示错误，可以再试")
    func saveDisplayNameError() async {
        let (mock, app) = make()
        let model = DisplayNameModel(client: app.client, user: mock.state.user)
        model.draft = "王五"
        mock.failNext(with: .network(message: "offline"))
        #expect(await model.save() == nil)
        #expect(model.error?.isOffline == true)
        #expect(!model.isSaving)
        #expect(await model.save()?.displayName == "王五")
        #expect(model.error == nil)
    }

    // MARK: 注销

    @Test("注销：要先勾选“我已了解”才能发码；发码后 60 秒倒计时")
    func deleteAccountCode() async {
        let clock = Locked(Fixture.now)
        let (_, app) = make()
        let model = DeleteAccountModel(client: app.client, now: { clock.value })
        #expect(!model.canSendCode(at: Fixture.now))
        await model.sendCode()
        #expect(!model.codeSent)
        model.hasAcknowledged = true
        #expect(model.canSendCode(at: Fixture.now))
        await model.sendCode()
        #expect(model.codeSent)
        #expect(model.secondsUntilResend(at: Fixture.now) == 60)
        #expect(!model.canSendCode(at: Fixture.now.addingTimeInterval(10)))
        #expect(model.canSendCode(at: Fixture.now.addingTimeInterval(60)))
    }

    @Test("注销发码被限流：显示剩余秒数；倒数完了才能再发")
    func deleteAccountRateLimited() async {
        let clock = Locked(Fixture.now)
        let (mock, app) = make()
        let model = DeleteAccountModel(client: app.client, now: { clock.value })
        model.hasAcknowledged = true
        mock.failNext(with: .api(status: 429, code: .rateLimited, message: "too many codes", retryAfterSecs: 30))
        await model.sendCode()
        #expect(!model.codeSent)
        #expect(model.isRateLimited)
        #expect(model.error == nil)
        #expect(model.rateLimitMessage(at: Fixture.now, language: .chinese) == "验证码发送太频繁，请 30 秒后再试。")
        #expect(model.rateLimitMessage(at: Fixture.now.addingTimeInterval(30)) == nil)

        mock.failNext(with: .network(message: "offline"))
        await model.sendCode()
        #expect(model.error == nil)  // 还在倒计时，没发
        clock.withLock { $0 = $0.addingTimeInterval(30) }
        await model.sendCode()
        #expect(model.error?.isOffline == true)
        #expect(!model.codeSent)
        model.dismissError()
        await model.sendCode()
        #expect(model.codeSent)
        #expect(!model.isRateLimited)
    }

    @Test("注销：验证码不对提示重输；对了就注销，应用框架回到登录页")
    func deleteAccount() async {
        let (mock, app) = make()
        await app.start()
        let model = DeleteAccountModel(client: app.client, now: { Fixture.now })
        model.hasAcknowledged = true
        await model.sendCode()
        model.updateCode("000 000")
        #expect(model.code == "000000")
        #expect(model.canDelete)
        #expect(await !model.deleteAccount())
        #expect(model.codeIncorrect)
        #expect(app.phase == .signedIn)
        model.updateCode(mock.state.verificationCode)
        #expect(!model.codeIncorrect)
        #expect(await model.deleteAccount())
        #expect(model.isDeleted)
        #expect(!mock.signedIn())
        #expect(await eventually { app.phase == .signedOut })
        #expect(DeleteAccountModel.incorrectCodeMessage(.english).contains("incorrect"))
    }

    @Test("注销没发码、码没输满：不能点")
    func deleteAccountGuards() async {
        let (_, app) = make()
        let model = DeleteAccountModel(client: app.client)
        model.hasAcknowledged = true
        model.updateCode("123456")
        #expect(!model.canDelete)
        #expect(await !model.deleteAccount())
        await model.sendCode()
        model.updateCode("1234")
        #expect(!model.canDelete)
    }
}
