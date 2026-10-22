import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 注册登录与设备管理（WBS 12.2）的界面：每个页面在浅色中文、深色英文下都能布局，登录页的协议链接、没登录时
/// 应用框架显示登录页。逻辑（发码、倒计时、登录、下线、注销）在 ThinktinKitTests/Account 里测。
@MainActor
@Suite("账号与设备的界面")
struct AccountScreensTests {
    /// 浅色中文、深色英文各布局一次（放进带 Mock 的应用框架环境）。
    private func layoutBoth(_ view: some View, client: (any ClientProtocol)? = nil) {
        hostAndLayout(view.previewShell(client: client))
        hostAndLayout(view.previewShell(.english, scheme: .dark, client: client))
    }

    @Test("接入点：登录、账号、登录设备")
    func destinations() {
        layoutBoth(AccountDestination(route: .signIn), client: AccountPreviewClients.signedOut())
        layoutBoth(AccountDestination(route: .account))
        layoutBoth(AccountDestination(route: .devices))
        layoutBoth(AccountDestination(route: .devices), client: AccountPreviewClients.singleDevice())
    }

    @Test("登录三页和选区号")
    func signInPages() async {
        let welcome = SignInModel(
            client: AccountPreviewClients.signedOut(), consent: AccountConsentStore(defaults: nil))
        layoutBoth(WelcomeView(model: welcome))
        welcome.continueWithPhone()
        #expect(welcome.showsConsentPrompt)
        layoutBoth(WelcomeView(model: welcome))

        let phone = SignInPreviewModels.phone()
        layoutBoth(PhoneEntryView(model: phone))
        let limited = SignInPreviewModels.phone(rateLimited: true)
        await limited.requestCode()
        #expect(limited.isRateLimited)
        layoutBoth(PhoneEntryView(model: limited))

        await phone.requestCode()
        #expect(phone.showsCodeEntry)
        layoutBoth(CodeEntryView(model: phone))
        phone.updateCode("000000")
        await phone.signIn()
        #expect(phone.fieldError == .incorrectCode)
        layoutBoth(CodeEntryView(model: phone))

        layoutBoth(RegionPickerView(selected: .mainland) { _ in })
    }

    @Test("账号页的子页面：改昵称、注销、全部停止")
    func accountPages() async {
        let mock = AccountPreviewClients.signedIn()
        layoutBoth(DisplayNameEditor(client: mock, user: mock.state.user) { _ in })
        layoutBoth(DeleteAccountView(client: mock, maskedPhone: "138****8000"))
        let stopAll = StopAllModel(client: mock)
        layoutBoth(AccountSection("安全") { StopAllRow(model: stopAll) })
        await stopAll.stopAll()
        #expect(stopAll.result != nil)
        layoutBoth(AccountSection("安全") { StopAllRow(model: stopAll) })
    }

    @Test("登录设备：下线其他设备的 sheet、设备行")
    func devicePages() async {
        let model = DevicesModel(client: AccountPreviewClients.signedIn())
        await model.load()
        layoutBoth(SignOutOthersSheet(model: model))
        for device in model.devices {
            layoutBoth(DeviceRow(device: device) {})
        }
        layoutBoth(DeviceRow(device: model.devices[0], isRevoking: true) {})
    }

    @Test("没登录时应用框架显示登录页")
    func signedOutShell() async {
        let model = AppModel(client: AccountPreviewClients.signedOut(), defaults: nil)
        await model.start()
        #expect(model.phase == .signedOut)
        hostAndLayout(AppShell(model: model))
        hostAndLayout(AppShell(model: model).environment(\.displayLanguage, .english).preferredColorScheme(.dark))
    }

    @Test("同意协议那一句带用户协议和隐私政策两个链接（https）")
    func consentLinks() {
        for language in DisplayLanguage.allCases {
            let text = AttributedString.termsConsent(language)
            let links = text.runs.compactMap(\.link)
            #expect(links == [AccountLinks.userAgreement, AccountLinks.privacyPolicy])
        }
        #expect(AccountLinks.userAgreement.scheme == "https")
        #expect(AccountLinks.privacyPolicy.scheme == "https")
        #expect(String(AttributedString.termsConsent(.chinese).characters) == "我已阅读并同意《用户协议》和《隐私政策》")
    }

    @Test("登录时带的推送令牌：默认不带，可以注入")
    func pushRegistration() async {
        #expect(await EnvironmentValues().signInPushRegistration.fetch() == nil)
        let push = PushRegistration(channel: .apns, token: "abcd")
        #expect(await SignInPushRegistration { push }.fetch() == push)
    }
}
