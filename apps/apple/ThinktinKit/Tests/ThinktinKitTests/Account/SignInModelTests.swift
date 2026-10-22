import Foundation
import Testing

@testable import ThinktinKit

// 登录流程（WBS 12.2）：同意协议、区号、发码倒计时、429、验证码、登录后应用框架切到主界面。

@MainActor
@Suite("登录")
struct SignInModelTests {
    /// 没登录的 Mock（验证码固定 123456），包进 `AppModel`，模型用 `AppModel.client`（`ObservedClient`）。
    private func make(clock: Locked<Date> = Locked(Fixture.now), agreed: Bool = true) -> (
        MockClient, AppModel, SignInModel
    ) {
        let mock = makeShellMock(signedIn: false)
        let app = AppModel(client: mock, defaults: nil)
        let model = SignInModel(
            client: app.client, consent: AccountConsentStore(defaults: nil), now: { clock.value })
        if agreed { model.setAgreedToTerms(true) }
        return (mock, app, model)
    }

    @Test("没勾选同意就点“手机号登录”：先弹提示；同意并继续后进手机号页")
    func consentGate() {
        let (_, _, model) = make(agreed: false)
        #expect(!model.hasAgreedToTerms)
        model.continueWithPhone()
        #expect(model.showsConsentPrompt)
        #expect(!model.showsPhoneEntry)
        model.agreeAndContinue()
        #expect(model.hasAgreedToTerms)
        #expect(!model.showsConsentPrompt)
        #expect(model.showsPhoneEntry)
    }

    @Test("同意记录：记进 UserDefaults，下次打开就是勾上的；取消勾选就撤回")
    func consentPersists() throws {
        let suite = "SignInModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountConsentStore(defaults: defaults)
        let mock = makeShellMock(signedIn: false)

        let first = SignInModel(client: mock, consent: store, now: { Fixture.now })
        #expect(!first.hasAgreedToTerms)
        first.setAgreedToTerms(true)
        #expect(store.hasAgreed)
        #expect(store.agreedAt == Fixture.now)

        let second = SignInModel(client: mock, consent: store)
        #expect(second.hasAgreedToTerms)
        second.setAgreedToTerms(false)
        #expect(!store.hasAgreed)
        #expect(store.agreedAt == nil)

        // 协议改版：存的版本不对就当没同意。
        defaults.set("2020-01", forKey: AccountConsentStore.versionKey)
        #expect(!SignInModel(client: mock, consent: store).hasAgreedToTerms)
    }

    @Test("号码不对：本地就拦下，不发请求")
    func invalidPhone() async {
        let (mock, _, model) = make()
        model.updatePhone("1380013")
        #expect(model.phoneNumber == nil)
        #expect(!model.canRequestCode(at: Fixture.now))
        mock.failNext(with: .network(message: "should not be called"))
        await model.requestCode()
        #expect(model.fieldError == .invalidPhone)
        #expect(model.error == nil)
        #expect(!model.showsCodeEntry)
        #expect(model.fieldError?.message(.chinese).contains("手机号") == true)
        // 改了号码，错误提示就收起来。
        model.updatePhone("13800138000")
        #expect(model.fieldError == nil)
        // 刚才排的错误还在（没发过请求）。
        await #expect(throws: ClientError.self) { try await mock.me() }
    }

    @Test("没同意不能发码")
    func codeNeedsConsent() async {
        let (_, _, model) = make(agreed: false)
        model.updatePhone("13800138000")
        #expect(!model.canRequestCode(at: Fixture.now))
        await model.requestCode()
        #expect(model.showsConsentPrompt)
        #expect(model.codeSentTo == nil)
    }

    @Test("发码：进验证码页，60 秒内这个号码不能再发，换个号码不用等")
    func requestCode() async {
        let clock = Locked(Fixture.now)
        let (_, _, model) = make(clock: clock)
        model.updatePhone("138 0013 8000")
        #expect(model.phoneNumber == "+8613800138000")
        #expect(model.canRequestCode(at: Fixture.now))
        await model.requestCode()
        #expect(model.codeSentTo == "+8613800138000")
        #expect(model.showsCodeEntry)
        #expect(model.displayPhone == "+86 138 0013 8000")
        #expect(model.secondsUntilResend(at: Fixture.now) == 60)
        #expect(!model.canRequestCode(at: Fixture.now.addingTimeInterval(30)))
        #expect(model.canRequestCode(at: Fixture.now.addingTimeInterval(60)))
        // 倒计时没完时再点什么都不做。
        await model.requestCode()
        #expect(model.secondsUntilResend(at: Fixture.now.addingTimeInterval(1)) == 59)

        model.updatePhone("13900139000")
        #expect(model.secondsUntilResend(at: Fixture.now) == 0)
        #expect(model.canRequestCode(at: Fixture.now))
        // 验证码页上显示的还是发码的那个号码。
        #expect(model.displayPhone == "+86 138 0013 8000")
    }

    @Test("发码被限流（429）：按 Retry-After 倒数，提示里有剩余秒数；倒数完提示消失")
    func rateLimited() async {
        let (mock, _, model) = make()
        model.updatePhone("13800138000")
        mock.failNext(with: .api(status: 429, code: .rateLimited, message: "too many codes", retryAfterSecs: 42))
        await model.requestCode()
        #expect(model.isRateLimited)
        #expect(model.error == nil)
        // 之前没给这个号码发过码：留在手机号页。
        #expect(!model.showsCodeEntry)
        #expect(model.secondsUntilResend(at: Fixture.now) == 42)
        #expect(model.rateLimitMessage(at: Fixture.now, language: .chinese) == "验证码发送太频繁，请 42 秒后再试。")
        #expect(
            model.rateLimitMessage(at: Fixture.now.addingTimeInterval(40), language: .english)
                == "Too many codes requested. Try again in 2 s.")
        #expect(model.rateLimitMessage(at: Fixture.now.addingTimeInterval(42)) == nil)
        #expect(!model.canRequestCode(at: Fixture.now.addingTimeInterval(41)))
    }

    @Test("重发被限流、之前给这个号码发过码：照样在验证码页（那个码还能用）")
    func rateLimitedResend() async {
        let clock = Locked(Fixture.now)
        let (mock, _, model) = make(clock: clock)
        model.updatePhone("13800138000")
        await model.requestCode()
        model.showsCodeEntry = false  // 用户返回了手机号页
        clock.withLock { $0 = $0.addingTimeInterval(61) }
        mock.failNext(with: .api(status: 429, code: .rateLimited, message: "daily limit", retryAfterSecs: 3600))
        await model.requestCode()
        #expect(model.showsCodeEntry)
        #expect(model.isRateLimited)
        #expect(model.secondsUntilResend(at: clock.value) == 3600)
        // 下一次发成功了，限流提示就没了。
        clock.withLock { $0 = $0.addingTimeInterval(3600) }
        await model.requestCode()
        #expect(!model.isRateLimited)
        #expect(model.rateLimitMessage(at: clock.value) == nil)
    }

    @Test("发码时服务端说号码不对：显示在输入框下面；网络、服务不可用给横幅")
    func sendCodeErrors() async {
        let (mock, _, model) = make()
        model.updatePhone("13800138000")
        mock.failNext(with: .api(status: 422, code: .invalid, message: "invalid phone number", retryAfterSecs: nil))
        await model.requestCode()
        #expect(model.fieldError == .invalidPhone)
        #expect(model.error == nil)

        mock.failNext(with: .network(message: "offline"))
        await model.requestCode()
        #expect(model.error == .network(message: "offline"))
        #expect(model.fieldError == nil)
        model.dismissError()
        #expect(model.error == nil)

        let unavailable = ClientError.api(status: 503, code: .unavailable, message: "sms down", retryAfterSecs: nil)
        mock.failNext(with: unavailable)
        await model.requestCode()
        #expect(model.error == unavailable)
        #expect(!model.isRateLimited)
    }

    @Test("验证码：只留 6 位数字；输满自动登录，同一个错码不重复交")
    func autoSubmit() async {
        let (_, _, model) = make()
        model.updatePhone("13800138000")
        await model.requestCode()
        model.updateCode("12 34")
        #expect(model.code == "1234")
        #expect(!model.shouldAutoSubmit)
        #expect(!model.canSignIn)
        model.updateCode("6543219")
        #expect(model.code == "654321")
        #expect(model.shouldAutoSubmit)
        await model.signIn()
        #expect(model.fieldError == .incorrectCode)
        #expect(model.error == nil)
        #expect(!model.shouldAutoSubmit)
        #expect(model.canSignIn)
        // 改了一位：提示收起，可以再自动交。
        model.updateCode("65432")
        #expect(model.fieldError == nil)
        model.updateCode("654320")
        #expect(model.shouldAutoSubmit)
    }

    @Test("登录成功：应用框架切到主界面，回调拿到结果；带上推送令牌")
    func signInSucceeds() async {
        let mock = makeShellMock(signedIn: false)
        let app = AppModel(client: mock, defaults: nil)
        let push = PushRegistration(channel: .apns, token: "abcd1234")
        let model = SignInModel(
            client: app.client, consent: AccountConsentStore(defaults: nil), now: { Fixture.now },
            pushRegistration: { push })
        model.setAgreedToTerms(true)
        let results = Locked<[LoginResult]>([])
        model.onSignedIn = { result in results.withLock { $0.append(result) } }
        #expect(app.phase == .signedOut)

        model.updatePhone(mock.state.user.phone)
        #expect(model.region == .mainland)
        await model.requestCode()
        model.updateCode(mock.state.verificationCode)
        await model.signIn()
        #expect(model.error == nil)
        #expect(model.fieldError == nil)
        #expect(model.signInResult?.isNewUser == false)
        #expect(results.value.count == 1)
        #expect(mock.signedIn())
        #expect(mock.state.devices.first { $0.id == DemoData.deviceID }?.pushChannel == .apns)
        #expect(await eventually { app.phase == .signedIn })
        #expect(app.user?.id == DemoData.userID)
    }

    @Test("新手机号登录就是新用户（引导的入口看 isNewUser）")
    func newUser() async {
        let (mock, app, model) = make()
        model.updatePhone("+852 9123 4567")
        #expect(model.region.id == "HK")
        await model.requestCode()
        #expect(model.codeSentTo == "+85291234567")
        model.updateCode(mock.state.verificationCode)
        await model.signIn()
        #expect(model.signInResult?.isNewUser == true)
        #expect(await eventually { app.phase == .signedIn })
    }

    @Test("新用户登录后弹出引导：还没切到主界面时先记下，切过去再弹；老用户不弹")
    func onboardingAfterSignIn() async {
        let (mock, app, model) = make()
        model.onSignedIn = { result in
            if let next = SignInModel.destination(after: result) { app.router.show(next) }
        }
        model.updatePhone("13900139000")
        await model.requestCode()
        model.updateCode(mock.state.verificationCode)
        await model.signIn()
        #expect(await eventually { app.phase == .signedIn })
        #expect(await eventually { app.router.sheet == .onboarding })
        #expect(app.router.pendingRoute == nil)

        let returning = LoginResult(user: mock.state.user, isNewUser: false)
        #expect(SignInModel.destination(after: returning) == nil)
    }

    @Test("账号被冻结时登录被拒：没有会话，横幅里说明，应用框架不切换")
    func frozenAtSignIn() async {
        let (mock, app, model) = make()
        model.updatePhone("13800138000")
        await model.requestCode()
        model.updateCode("123456")
        let frozen = ClientError.api(status: 403, code: .accountFrozen, message: "frozen", retryAfterSecs: nil)
        mock.failNext(with: frozen)
        await model.signIn()
        #expect(model.error == frozen)
        #expect(model.fieldError == nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(app.phase == .signedOut)
    }

    @Test("登录时网络断了、新号注册太频繁：横幅（限流的带秒数）")
    func signInErrors() async {
        let (mock, _, model) = make()
        model.updatePhone("13800138000")
        await model.requestCode()
        model.updateCode("123456")
        mock.failNext(with: .network(message: "timed out"))
        await model.signIn()
        #expect(model.error?.isOffline == true)
        let limited = ClientError.api(status: 429, code: .rateLimited, message: "signups", retryAfterSecs: 120)
        mock.failNext(with: limited)
        await model.signIn()
        #expect(model.error == limited)
        #expect(model.error?.localizedMessage(.chinese) == "操作太频繁，请 120 秒后再试。")
        #expect(!model.isSigningIn)
    }

    @Test("横幅上的“重试”重做出错的那一步")
    func retry() async {
        let clock = Locked(Fixture.now)
        let (mock, app, model) = make(clock: clock)
        await model.retry()  // 没出过错：什么都不做
        #expect(model.codeSentTo == nil)

        model.updatePhone("13800138000")
        mock.failNext(with: .network(message: "offline"))
        await model.requestCode()
        #expect(model.error?.isOffline == true)
        await model.retry()
        #expect(model.error == nil)
        #expect(model.codeSentTo == "+8613800138000")

        model.updateCode(mock.state.verificationCode)
        mock.failNext(with: .network(message: "offline"))
        await model.signIn()
        #expect(model.error?.isOffline == true)
        await model.retry()
        #expect(model.error == nil)
        #expect(await eventually { app.phase == .signedIn })
    }

    @Test("换区号：保留号码；“+”开头的按新区号重新认")
    func selectRegion() {
        let (_, _, model) = make()
        let ca = PhoneRegion.region(id: "CA")!
        model.updatePhone("4165550123")
        model.selectRegion(ca)
        #expect(model.phoneText == "4165550123")
        #expect(model.phoneNumber == "+14165550123")
        model.selectRegion(.mainland)
        #expect(model.phoneNumber == nil)
        model.updatePhone("+999")
        model.selectRegion(ca)
        #expect(model.phoneText == "+999")
    }
}
