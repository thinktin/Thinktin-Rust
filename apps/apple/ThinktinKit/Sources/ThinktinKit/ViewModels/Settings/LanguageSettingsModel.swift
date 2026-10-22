import Foundation
import Observation

/// 语言（WBS 12.12；ios-packages.md 审查结论二之 6）：App 里选界面语言，推送、收件箱、IM 群消息的语言跟着变。
///
/// 两样东西要和界面语言一致：
/// - 服务端存的用户语言（`User.locale`，推送和收件箱用）：不一致就调 `setLocale`；
/// - 每个请求带的 `Accept-Language`（新用户注册时定语言、agent 目录的介绍按它给）：`setAcceptLanguage(for:)`，不联网。
///
/// 选语言（`select(_:)`）时同步一次；另外每次启动由 `AppModel` 调 `syncOnLaunch(user:)`：比较 `me().locale` 和界面语言，
/// 不一致就调 `setLocale`（用户在系统设置里换了 App 的语言、在别的设备上改过、离线时选的语言没同步上，下次启动都会补上）。
/// 同步失败不影响界面语言（已经存在本机），页面上提示一句、可以重试，下次启动也会再试。
@Observable @MainActor
public final class LanguageSettingsModel {
    /// 正在调 `setLocale`。
    public private(set) var isSyncing = false
    /// 最近一次同步失败（网络不通之类）；成功后清掉。
    public private(set) var syncError: ClientError?
    /// 服务端存的用户语言（拿到 `me()`、`setLocale` 的结果之后才知道）。
    public private(set) var serverLocale: UserLocale?

    public let preferences: SettingsPreferences
    @ObservationIgnored private let client: any ClientProtocol

    /// - Parameters:
    ///   - user: 已经知道的用户（`AppModel.user`）：拿它的 `locale` 当服务端的语言，省一次 `me()`。
    public init(client: any ClientProtocol, preferences: SettingsPreferences, user: User? = nil) {
        self.client = client
        self.preferences = preferences
        self.serverLocale = user?.locale
    }

    /// 当前选的。
    public var selection: LanguagePreference { preferences.language }

    /// 界面实际用的语言。
    public var displayLanguage: DisplayLanguage { preferences.displayLanguage }

    /// 服务端的语言和界面语言不一样（还没同步上）。不知道服务端的语言时是 false。
    public var isOutOfSync: Bool {
        guard let serverLocale else { return false }
        return Self.needsSync(serverLocale: serverLocale, displayLanguage: displayLanguage)
    }

    /// 服务端的语言要不要改成界面语言：不一样就要（服务端是认不出的语言时也改）。
    public nonisolated static func needsSync(serverLocale: UserLocale, displayLanguage: DisplayLanguage) -> Bool {
        serverLocale != displayLanguage.userLocale
    }

    // MARK: 选语言

    /// 选一种：先记下来（界面马上换），再让服务端和请求语言跟上。
    ///
    /// 界面语言没变（比如系统是中文，从“跟随系统”换成“中文”）、服务端也已经是这种语言时不联网。
    public func select(_ preference: LanguagePreference) async {
        preferences.setLanguage(preference)
        await syncServerLocale()
    }

    /// 上次同步失败了，再试一次。
    public func retrySync() async {
        await syncServerLocale()
    }

    public func dismissError() {
        syncError = nil
    }

    // MARK: 启动时（AppModel 调）

    /// 请求语言换成界面语言打头的（`AcceptLanguage.header(for:)`）。不联网，没登录时也该调：新用户注册时服务端按它定语言。
    public func applyAcceptLanguage() {
        // `header(for:)` 拼出来的值总是合法的（不超长、没有控制字符），这里不会抛。
        try? client.setAcceptLanguage(for: displayLanguage)
    }

    /// 启动时（`AppModel.start()` 确认完账号之后；登录成功后也调一次）：比较服务端的语言和界面语言，不一致就调 `setLocale`；
    /// 最后把请求语言换成界面语言打头的。
    ///
    /// - Parameter user: 已经拿到的用户（`AppModel` 刚调过 `me()`）；nil 时这里自己调 `me()`。
    /// - Returns: 最新的用户（改过语言的是改过之后的）；没登录、拉不到用户时是传进来的 `user`。
    ///
    /// 静默进行：网络不通、服务端出错都不提示（界面语言已经在本机生效，下次启动再试）；登录失效、冻结这类全局错误
    /// 由 `ObservedClient` 报给 `AppModel`。
    @discardableResult
    public func syncOnLaunch(user: User?) async -> User? {
        defer { applyAcceptLanguage() }
        guard client.signedIn() else { return user }
        var known = user
        if known == nil {
            known = try? await client.me()
        }
        guard let current = known else { return user }
        serverLocale = current.locale
        let target = displayLanguage.userLocale
        guard Self.needsSync(serverLocale: current.locale, displayLanguage: displayLanguage) else { return current }
        do {
            let updated = try await client.setLocale(target)
            serverLocale = updated.locale
            syncError = nil
            return updated
        } catch {
            return current
        }
    }

    // MARK: 内部

    /// 服务端的语言改成界面语言（已经一致就不调），请求语言跟上。
    ///
    /// 正在同步时又选了别的语言：这一次不另发请求，进行中的那一次回来后发现界面语言变了，再改一次（最多几轮，
    /// 服务端回的语言和要的对不上时不会一直转）。
    private func syncServerLocale() async {
        defer { applyAcceptLanguage() }
        guard client.signedIn(), !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for _ in 0..<Self.maxSyncRounds {
            let target = displayLanguage.userLocale
            if serverLocale == target {
                syncError = nil
                return
            }
            do {
                let user = try await client.setLocale(target)
                serverLocale = user.locale
                syncError = nil
            } catch is CancellationError {
                return
            } catch {
                syncError = SettingsSupport.clientError(error)
                return
            }
        }
    }

    /// 一次同步最多调几次 `setLocale`（等的时候用户又换了语言）。
    static let maxSyncRounds = 3
}

extension LanguageSettingsModel {
    /// 语言页底下的说明：推送、收件箱、IM 群消息跟着变；agent 写的内容不翻译。
    public nonisolated static func footnote(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "推送、收件箱和 IM 群消息也会换成这种语言。agent 写的内容保持原样，不翻译。"
                + "“跟随系统”用系统设置里给 ThinkTin 选的语言，系统是中文时中文，其余是英文。"
            : "Notifications, your inbox and IM group messages switch to this language too. What agents write stays as "
                + "written. System uses the language chosen for ThinkTin in iOS Settings: Chinese if that's Chinese, "
                + "English otherwise."
    }

    /// 同步失败时的一句说明（错误横幅上面）。
    public nonisolated static func syncFailedMessage(_ language: DisplayLanguage = .current) -> String {
        language == .chinese
            ? "界面已经换好了，推送和收件箱的语言还没跟上。可以重试，下次打开 App 时也会自动再试。"
            : "The app has switched, but notifications and your inbox haven't caught up yet. Retry now, or it will "
                + "try again the next time you open the app."
    }
}
