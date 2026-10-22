import Foundation
import Observation

/// 登录流程（WBS 12.2）：欢迎页（同意用户协议和隐私政策）→ 手机号（区号，默认 +86）→ 验证码（6 位，自动填充、
/// 倒计时重发）。和安卓的两步登录一致（docs/android-design.md 4.1）。
///
/// - 登录成功后不用自己切页面：客户端是 `ObservedClient`，`login` 成功会报给 `AppModel` 切到主界面（docs/ios.md 9.1）。
///   `onSignedIn` 在这之后调一次，新用户（`isNewUser`）进引导的入口在这里（12.17）。
/// - 发码限流（429）：按 `Retry-After` 倒数，按钮和提示上显示剩余秒数；之前已经给这个号码发过码的，照样进验证码页
///   （那个码还能用，5 分钟有效）。
/// - 错误：号码不对、验证码不对（`invalid`）显示在输入框下面；其余按 `ClientError` 的分类给横幅（`error`）。
///   账号被冻结时登录就被拒、没有会话，`AppModel` 不接管，横幅里说明。
@Observable @MainActor
public final class SignInModel {
    /// 输入框下面的错误。
    public enum FieldError: Hashable, Sendable {
        /// 手机号的位数、格式不对（本地检查，或服务端说不对）。
        case invalidPhone
        /// 验证码不对、过期了或试错太多次作废了（服务端都返回 `invalid`）。
        case incorrectCode

        public nonisolated func message(_ language: DisplayLanguage = .current) -> String {
            let zh = language == .chinese
            switch self {
            case .invalidPhone:
                return zh ? "手机号格式不正确，请检查区号和号码。" : "That phone number doesn't look right. Check the country code."
            case .incorrectCode:
                return zh
                    ? "验证码不正确或已失效，请重新输入或重新获取。"
                    : "That code is incorrect or has expired. Re-enter it or request a new one."
            }
        }
    }

    // MARK: 欢迎页

    /// 勾选了“我已阅读并同意用户协议和隐私政策”。同意过现行版本的，打开时就是勾上的。
    public private(set) var hasAgreedToTerms: Bool
    /// 进手机号页（导航用，界面绑 `navigationDestination(isPresented:)`）。
    public var showsPhoneEntry = false
    /// 没勾选就点了“手机号登录”：弹出“请先同意”的提示。
    public var showsConsentPrompt = false

    // MARK: 手机号

    public private(set) var region: PhoneRegion
    /// 手机号框里的文字（`updatePhone(_:)` 整理过的：只有数字，或者认不出区号时的“+数字”）。
    public private(set) var phoneText = ""
    public private(set) var isSendingCode = false
    /// 进验证码页（导航用）。
    public var showsCodeEntry = false

    // MARK: 验证码

    /// 验证码发到了哪个号码（E.164）。登录用它，不用框里正在改的号码。
    public private(set) var codeSentTo: String?
    public private(set) var code = ""
    public private(set) var isSigningIn = false
    public private(set) var signInResult: LoginResult?

    // MARK: 错误与倒计时

    /// 横幅里的错误（网络、限流、服务不可用、冻结、其他）。
    public private(set) var error: ClientError?
    /// 输入框下面的错误。
    public private(set) var fieldError: FieldError?
    /// 上一次发码被限流了（显示“请 N 秒后再试”，倒数到 0 就不显示）。
    public private(set) var isRateLimited = false
    /// 重发倒计时（只管 `cooldownPhone` 这个号码；换了号码不用等）。
    public private(set) var cooldown = CodeCooldown()
    public private(set) var cooldownPhone: String?

    /// 登录成功之后调（`AppModel` 已经在切主界面）。新用户进引导（12.17）由设置它的界面决定。
    @ObservationIgnored public var onSignedIn: (@MainActor (LoginResult) -> Void)?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let consent: AccountConsentStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pushRegistration: @MainActor @Sendable () async -> PushRegistration?
    /// 最近一次提交的验证码：自动提交时同一个码不重复交（错了要用户改了再交）。
    @ObservationIgnored private var lastSubmittedCode: String?

    /// - Parameters:
    ///   - client: 环境里的客户端（`ObservedClient`）。
    ///   - region: 默认的区号（中国大陆 +86）。
    ///   - consent: 同意记录（测试、预览传 `AccountConsentStore(defaults: nil)`）。
    ///   - now: 现在的时间（倒计时用；测试传固定值）。
    ///   - pushRegistration: 登录时带上的推送令牌（12.8 拿到 APNs 令牌后给；没有就登录后再 `setPushToken`）。
    public init(
        client: any ClientProtocol, region: PhoneRegion = .mainland, consent: AccountConsentStore = .init(),
        now: @escaping () -> Date = Date.init,
        pushRegistration: @escaping @MainActor @Sendable () async -> PushRegistration? = { nil }
    ) {
        self.client = client
        self.region = region
        self.consent = consent
        self.now = now
        self.pushRegistration = pushRegistration
        self.hasAgreedToTerms = consent.hasAgreed
    }

    // MARK: 欢迎页

    /// 勾选 / 取消勾选同意。
    public func setAgreedToTerms(_ agreed: Bool) {
        hasAgreedToTerms = agreed
        if agreed {
            consent.recordAgreement(at: now())
        } else {
            consent.withdraw()
        }
    }

    /// “手机号登录”：同意了就进手机号页，没同意先弹提示。
    public func continueWithPhone() {
        if hasAgreedToTerms {
            showsPhoneEntry = true
        } else {
            showsConsentPrompt = true
        }
    }

    /// 提示里的“同意并继续”。
    public func agreeAndContinue() {
        setAgreedToTerms(true)
        showsConsentPrompt = false
        showsPhoneEntry = true
    }

    // MARK: 手机号

    /// 手机号框改了：整理成只有数字；粘贴、自动填充带区号（`+86 138…`）的切到对应的区号。
    public func updatePhone(_ text: String) {
        let normalized = PhoneNumberInput.normalize(text, region: region)
        region = normalized.region
        phoneText = normalized.text
        if fieldError == .invalidPhone { fieldError = nil }
    }

    /// 选了区号。
    public func selectRegion(_ newRegion: PhoneRegion) {
        region = newRegion
        if phoneText.hasPrefix("+") { updatePhone(phoneText) }
        if fieldError == .invalidPhone { fieldError = nil }
    }

    /// 框里的号码对应的 E.164；不像手机号时为 nil。
    public var phoneNumber: String? { PhoneNumberInput.e164(phoneText, region: region) }

    /// 给人看的号码（验证码页的“已发送至 +86 138 0013 8000”）。
    public var displayPhone: String {
        guard let sent = codeSentTo else { return PhoneNumberInput.display(phoneText, region: region) }
        return Self.display(e164: sent, region: region)
    }

    /// 框里的号码还要等几秒才能再发码（别的号码不用等）。
    public func secondsUntilResend(at date: Date) -> Int {
        guard let phone = phoneNumber, phone == cooldownPhone else { return 0 }
        return cooldown.remainingSeconds(at: date)
    }

    /// “获取验证码”能不能点。
    public func canRequestCode(at date: Date) -> Bool {
        phoneNumber != nil && !isSendingCode && !isSigningIn && hasAgreedToTerms && secondsUntilResend(at: date) == 0
    }

    /// 限流时的提示：“发送太频繁，请 N 秒后再试”（剩余秒数跟着 `date` 走）；没被限流、已经倒数完了为 nil。
    public func rateLimitMessage(at date: Date, language: DisplayLanguage = .current) -> String? {
        guard isRateLimited else { return nil }
        let seconds = cooldown.remainingSeconds(at: date)
        guard seconds > 0 else { return nil }
        return language == .chinese
            ? "验证码发送太频繁，请 \(seconds) 秒后再试。"
            : "Too many codes requested. Try again in \(seconds) s."
    }

    /// 发验证码（手机号页的“获取验证码”、验证码页的“重新获取”）。成功后进验证码页，开始 60 秒倒计时。
    public func requestCode() async {
        guard let phone = phoneNumber else {
            fieldError = .invalidPhone
            return
        }
        guard hasAgreedToTerms else {
            showsConsentPrompt = true
            return
        }
        guard !isSendingCode, secondsUntilResend(at: now()) == 0 else { return }
        isSendingCode = true
        error = nil
        fieldError = nil
        defer { isSendingCode = false }
        do {
            try await client.sendCode(phone: phone)
            if codeSentTo != phone { code = "" }
            codeSentTo = phone
            lastSubmittedCode = nil
            isRateLimited = false
            startCooldown(for: phone, seconds: CodeCooldown.resendInterval)
            showsCodeEntry = true
        } catch is CancellationError {
            return
        } catch {
            handleSendCodeError(error, phone: phone)
        }
    }

    // MARK: 验证码

    /// 验证码框改了：只留 6 位数字。
    public func updateCode(_ text: String) {
        code = VerificationCode.sanitize(text)
        if fieldError == .incorrectCode { fieldError = nil }
    }

    /// 输满 6 位（手动输入、自动填充）就自动登录；同一个码错了不再自动交。
    public var shouldAutoSubmit: Bool {
        VerificationCode.isComplete(code) && code != lastSubmittedCode && !isSigningIn && codeSentTo != nil
    }

    /// “登录”能不能点。
    public var canSignIn: Bool {
        VerificationCode.isComplete(code) && !isSigningIn && codeSentTo != nil
    }

    /// 登录（没注册过的号码自动注册）。
    public func signIn() async {
        guard let phone = codeSentTo, VerificationCode.isComplete(code), !isSigningIn else { return }
        isSigningIn = true
        error = nil
        fieldError = nil
        lastSubmittedCode = code
        defer { isSigningIn = false }
        let push = await pushRegistration()
        do {
            let result = try await client.login(phone: phone, code: code, push: push)
            signInResult = result
            onSignedIn?(result)
        } catch is CancellationError {
            return
        } catch {
            let clientError = Self.clientError(error)
            if clientError.isInvalidInput {
                fieldError = .incorrectCode
            } else {
                self.error = clientError
            }
        }
    }

    public func dismissError() {
        error = nil
    }

    /// 登录成功后接着去哪（界面交给 `router.show(_:)`；还没切到主界面时 `Router` 先记下，切过去再跳）：新用户进引导
    /// （12.17 的入口），老用户直接回到主界面（nil）。老用户换了新手机要不要补引导，由 12.17 在引导里判断。
    public nonisolated static func destination(after result: LoginResult) -> AppRoute? {
        result.isNewUser ? .onboarding : nil
    }

    // MARK: 内部

    private func handleSendCodeError(_ error: any Error, phone: String) {
        let clientError = Self.clientError(error)
        if clientError.isInvalidInput {
            fieldError = .invalidPhone
            return
        }
        if clientError.isRateLimited, let seconds = clientError.retryAfter {
            // 限流：倒数到能再发为止。60 秒内给这个号码发过码的（重发间隔没到），那个码还有效，照样进验证码页。
            isRateLimited = true
            startCooldown(for: phone, seconds: seconds)
            if codeSentTo == phone { showsCodeEntry = true }
            return
        }
        self.error = clientError
    }

    private func startCooldown(for phone: String, seconds: TimeInterval) {
        if cooldownPhone != phone { cooldown.reset() }
        cooldownPhone = phone
        cooldown.start(at: now(), seconds: seconds)
    }

    /// E.164 → “+86 138 0013 8000”（认得出区号的按那里的格式）。
    nonisolated static func display(e164: String, region: PhoneRegion) -> String {
        let digits = PhoneNumberInput.asciiDigits(e164)
        guard let match = PhoneRegion.matching(e164Digits: digits, preferred: region) else { return e164 }
        let national = String(digits.dropFirst(match.dialCode.count))
        return match.dialCodeText + " " + match.formatted(national: national)
    }

    nonisolated static func clientError(_ error: any Error) -> ClientError {
        (error as? ClientError) ?? .internal(message: String(describing: error))
    }
}
