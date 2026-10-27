import Foundation

/// 用户协议和隐私政策的同意记录（WBS 12.2，16.4）：欢迎页勾选“我已阅读并同意”之后才能用手机号登录（收集手机号之前
/// 必须先同意）。记在 `UserDefaults` 里：再打开欢迎页时显示已勾选；协议改版（`currentVersion` 变了）要重新同意。
///
/// 12.17 的“同意之前不收集信息、不注册推送”可以用 `hasAgreed` 判断。
@MainActor
public struct AccountConsentStore {
    /// 现行协议的版本（协议、政策改版时改它，所有人重新同意）。
    public static let currentVersion = "2026-10"
    static let versionKey = "cn.thinktin.account.consentVersion"
    static let dateKey = "cn.thinktin.account.consentDate"

    /// 为 nil 时不记（测试、预览）：每次都要重新勾选。
    public let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    /// 同意过现行版本。
    public var hasAgreed: Bool {
        defaults?.string(forKey: Self.versionKey) == Self.currentVersion
    }

    /// 同意的时间（同意过现行版本时才有）。
    public var agreedAt: Date? {
        guard hasAgreed else { return nil }
        return defaults?.object(forKey: Self.dateKey) as? Date
    }

    /// 记下同意了现行版本。
    public func recordAgreement(at date: Date = Date()) {
        defaults?.set(Self.currentVersion, forKey: Self.versionKey)
        defaults?.set(date, forKey: Self.dateKey)
    }

    /// 撤回同意（取消了勾选）。
    public func withdraw() {
        defaults?.removeObject(forKey: Self.versionKey)
        defaults?.removeObject(forKey: Self.dateKey)
    }
}

/// 重装 App 之后清掉 Keychain 里上一次安装留下的会话（ios-packages.md 12.2 “Keychain 会话存储：处理重装”）。
///
/// iOS 卸载 App 时删掉 `UserDefaults`，但不删 Keychain：重装后会带着旧会话直接显示已登录，而本地缓存、推送令牌都已经
/// 没了。所以首次启动（`UserDefaults` 里没有安装标记）时先把会话删掉，再记下标记。要在建 `CoreClient` 之前调
/// （client-core 只在构造时读一次会话）。
///
/// 旧会话在服务端还算登录着，会出现在“登录设备”里，用户可以把它下线（它的刷新令牌已经找不回来了）。
public enum FreshInstallGuard {
    static let markerKey = "cn.thinktin.account.installMarker"

    /// 首次启动就清掉 `sessions` 里的会话。返回清掉了没有（本来就没有会话、不是首次启动都是 false）。
    @discardableResult
    public static func clearStaleSession(in sessions: any SessionStoring, defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: markerKey) else { return false }
        defaults.set(true, forKey: markerKey)
        guard sessions.load() != nil else { return false }
        sessions.save(nil)
        return true
    }
}
