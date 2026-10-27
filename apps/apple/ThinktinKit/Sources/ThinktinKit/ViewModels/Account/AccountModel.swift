import Foundation
import Observation

/// 账号页（WBS 12.2）：昵称、打码的手机号，进登录设备、全部停止、退出登录、注销账号。
///
/// 先显示应用框架已经拿到的用户（`AppModel.user`），再 `me()` 拉最新的。退出登录用 `AppModel.signOut()`（离线时本地
/// 照样清掉），这里不重复做。账号不缓存（docs/ios.md 6.2），离线又没有用户时页面显示空状态。
@Observable @MainActor
public final class AccountModel {
    public private(set) var user: User?
    public private(set) var isLoading = false
    public private(set) var loadError: ClientError?

    @ObservationIgnored private let client: any ClientProtocol

    /// - Parameter user: 已经知道的用户（`AppModel.user`），拉到之前先显示它。
    public init(client: any ClientProtocol, user: User? = nil) {
        self.client = client
        self.user = user
    }

    /// 拉最新的用户。
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            user = try await client.me()
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = DevicesModel.clientError(error)
        }
    }

    /// 改完昵称（`DisplayNameModel` 保存成功）后换上新的用户。
    public func apply(_ user: User) {
        self.user = user
    }

    /// 打码的手机号（`138****8000`）；注销后的空手机号显示空。
    public var maskedPhone: String {
        guard let phone = user?.phone, !phone.isEmpty else { return "" }
        return User.maskedPhone(phone)
    }

    /// 退出登录的确认说明：退出只下线这台设备，agent 照常运行（docs/architecture-v3.md 第 4 节）。
    public nonisolated static func signOutMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "退出后这台设备不再收到通知。agent 的任务和计划照常在云端运行；要让它们停下来，请用“全部停止”。"
            : "This device will stop getting notifications. Your agents' tasks and plans keep running in the cloud; "
                + "to stop them, use Stop everything."
    }
}

/// 改昵称（WBS 12.2，`updateProfile`）：去掉首尾空白，1 到 64 个字符（服务端按 Unicode 标量数）；清空就是不要昵称，
/// 界面改显示打码的手机号。
@Observable @MainActor
public final class DisplayNameModel {
    /// 输入框里的文字。
    public var draft: String
    public private(set) var isSaving = false
    public private(set) var error: ClientError?
    /// 保存成功后的用户。
    public private(set) var savedUser: User?

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let original: String?

    public init(client: any ClientProtocol, user: User?) {
        self.client = client
        self.original = user?.displayName
        self.draft = user?.displayName ?? ""
    }

    /// 去掉首尾空白之后的名字；空的是 nil（清掉昵称）。
    public var normalizedName: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 字数（和服务端一样按 Unicode 标量数）。
    public var characterCount: Int { normalizedName?.unicodeScalars.count ?? 0 }

    public var isTooLong: Bool { characterCount > User.maxDisplayNameLength }

    /// 和原来的不一样（空的和没有昵称算一样）。
    public var hasChanges: Bool {
        let before = original.flatMap { $0.isEmpty ? nil : $0 }
        return normalizedName != before
    }

    public var canSave: Bool { hasChanges && !isTooLong && !isSaving }

    /// 字数提示：“12/64”。
    public var counterText: String { "\(characterCount)/\(User.maxDisplayNameLength)" }

    /// 输入框下面的提示：太长了说明上限。
    public func validationMessage(_ language: DisplayLanguage = .current) -> String? {
        guard isTooLong else { return nil }
        return language == .chinese
            ? "昵称最多 \(User.maxDisplayNameLength) 个字。"
            : "Names can be up to \(User.maxDisplayNameLength) characters."
    }

    /// 保存。成功返回新的用户。
    @discardableResult
    public func save() async -> User? {
        guard canSave else { return nil }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let user = try await client.updateProfile(displayName: normalizedName)
            savedUser = user
            return user
        } catch is CancellationError {
            return nil
        } catch {
            self.error = DevicesModel.clientError(error)
            return nil
        }
    }
}

/// App 内注销账号（WBS 12.2，App Store 审核指南 5.1.1(v)；16.4）：先说明会删掉什么、勾选“我已了解”，再给本人手机号
/// 发专用验证码（`sendSelfCode(purpose: .deleteAccount)`），输入后注销。
///
/// 注销成功后本地登录状态和缓存都清掉了，`ObservedClient` 报给 `AppModel` 回到登录页，这里不用管。
@Observable @MainActor
public final class DeleteAccountModel {
    /// 勾选了“我已了解注销后无法恢复”。
    public var hasAcknowledged = false
    public private(set) var isSendingCode = false
    /// 验证码发出去了（显示验证码框）。
    public private(set) var codeSent = false
    public private(set) var code = ""
    public private(set) var isDeleting = false
    public private(set) var error: ClientError?
    /// 验证码不对、过期了。
    public private(set) var codeIncorrect = false
    public private(set) var isRateLimited = false
    public private(set) var cooldown = CodeCooldown()
    /// 注销完了。
    public private(set) var isDeleted = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let now: () -> Date

    public init(client: any ClientProtocol, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    public func secondsUntilResend(at date: Date) -> Int { cooldown.remainingSeconds(at: date) }

    public func canSendCode(at date: Date) -> Bool {
        hasAcknowledged && !isSendingCode && !isDeleting && !cooldown.isWaiting(at: date)
    }

    public var canDelete: Bool {
        hasAcknowledged && codeSent && VerificationCode.isComplete(code) && !isDeleting
    }

    /// 限流提示（剩余秒数跟着 `date` 走）。
    public func rateLimitMessage(at date: Date, language: DisplayLanguage = .current) -> String? {
        guard isRateLimited else { return nil }
        let seconds = cooldown.remainingSeconds(at: date)
        guard seconds > 0 else { return nil }
        return language == .chinese
            ? "验证码发送太频繁，请 \(seconds) 秒后再试。"
            : "Too many codes requested. Try again in \(seconds) s."
    }

    public func updateCode(_ text: String) {
        code = VerificationCode.sanitize(text)
        codeIncorrect = false
    }

    /// 给本人手机号发验证码（或重发）。
    public func sendCode() async {
        guard canSendCode(at: now()) else { return }
        isSendingCode = true
        error = nil
        defer { isSendingCode = false }
        do {
            try await client.sendSelfCode(purpose: .deleteAccount)
            codeSent = true
            isRateLimited = false
            cooldown.start(at: now())
        } catch is CancellationError {
            return
        } catch {
            let clientError = DevicesModel.clientError(error)
            if clientError.isRateLimited, let seconds = clientError.retryAfter {
                isRateLimited = true
                cooldown.start(at: now(), seconds: seconds)
            } else {
                self.error = clientError
            }
        }
    }

    /// 注销。返回成功没有。
    @discardableResult
    public func deleteAccount() async -> Bool {
        guard canDelete else { return false }
        isDeleting = true
        error = nil
        codeIncorrect = false
        defer { isDeleting = false }
        do {
            try await client.deleteAccount(code: code)
            isDeleted = true
            return true
        } catch is CancellationError {
            return false
        } catch {
            let clientError = DevicesModel.clientError(error)
            if clientError.isInvalidInput {
                codeIncorrect = true
            } else {
                self.error = clientError
            }
            return false
        }
    }

    public func dismissError() {
        error = nil
    }

    /// 验证码不对时的提示。
    public nonisolated static func incorrectCodeMessage(_ language: DisplayLanguage = .current) -> String {
        SignInModel.FieldError.incorrectCode.message(language)
    }
}
