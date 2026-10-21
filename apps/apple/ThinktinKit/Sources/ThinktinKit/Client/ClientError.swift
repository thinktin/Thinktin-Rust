import Foundation

/// 客户端错误：ThinktinCore 的 `ClientError`（和配对验签的 `PairingError`）在适配层转成它。
/// 界面按 `recovery` 决定做什么（docs/ios.md 第 6 节）。
public enum ClientError: Error, Hashable, Sendable {
    /// 网络不通、超时：稍后重试，离线时用缓存。
    case network(message: String)
    /// 没有登录，或登录已失效（刷新令牌被吊销、设备被远程下线）：回到登录页。
    case signedOut
    /// 客户端版本太老：提示升级。
    case upgradeRequired
    /// 账号被冻结（4.6）：冻结提示页，登录状态保留。
    case accountFrozen
    /// 服务端返回的错误。`message` 是英文、给开发者看的，界面按 `code` 显示本地化的文案。
    case api(status: Int, code: APIErrorCode, message: String, retryAfterSecs: Int?)
    /// 响应解析失败（服务端和客户端版本不匹配）。
    case decode(message: String)
    /// 本地缓存读写失败。
    case cache(message: String)
    /// 消息里有像密码、key 的内容（11.6），没有发出去。
    case containsSecrets(count: Int)
    /// 调用方传的参数不对（id 格式、枚举取值）。
    case invalidArgument(message: String)
    /// client-core 内部错误。
    case `internal`(message: String)
    /// 配对、签名的内容格式不对（二维码、公钥、字段、签名的编码）。
    case malformed(message: String)
    /// 配对、签名的内容过期了。
    case expired
    /// 签名验不过。
    case badSignature
    /// 这个功能 client-core 还没提供（11.7 落地前的方法，`CoreClient` 里抛它；`MockClient` 照常实现）。
    /// `feature` 是给开发者看的功能名（比如 `listDevices`），界面不显示它。
    case unsupported(feature: String)
}

/// 出错后界面该怎么处理（docs/ios.md 第 6 节的表）。
public enum ErrorRecovery: Hashable, Sendable {
    /// 清状态、回登录页。
    case signIn
    /// 冻结提示页（保留登录态）。
    case accountFrozen
    /// 全屏“请升级”，带 App Store 链接。
    case upgrade
    /// 限流：过一会儿再试（`after` 秒，服务端没给时为 nil）。
    case retryLater(after: TimeInterval?)
    /// 冲突：刷新后重试。
    case refreshAndRetry
    /// 参数不对：显示表单错误。
    case showFormError
    /// 对象不存在：回上一级。
    case goBack
    /// 网络问题：行内可重试的提示，列表页显示缓存并标“离线”。
    case offline
    /// 发送前的密码拦截弹层。
    case interceptSecrets(count: Int)
    /// 功能暂未开放：提示“暂不支持”，不重试（入口最好直接隐藏或置灰）。
    case featureUnavailable
    /// 通用错误提示，带“复制详情”。
    case generic
}

extension ClientError {
    /// 服务端的错误码（只有 `api` 有）。
    public var apiCode: APIErrorCode? {
        if case .api(_, let code, _, _) = self { return code }
        return nil
    }

    /// 要重新登录。
    public var requiresSignIn: Bool {
        switch self {
        case .signedOut: true
        case .api(_, .sessionRevoked, _, _): true
        default: false
        }
    }

    /// 账号被冻结。
    public var isAccountFrozen: Bool {
        switch self {
        case .accountFrozen, .api(_, .accountFrozen, _, _): true
        default: false
        }
    }

    /// 要升级 App。
    public var requiresUpgrade: Bool {
        switch self {
        case .upgradeRequired, .api(_, .upgradeRequired, _, _): true
        default: false
        }
    }

    /// 退避后可以原样重试（和 client-core 的 `retryable` 一致）。
    public var isRetryable: Bool {
        switch self {
        case .network: true
        case .api(_, let code, _, _): code == .rateLimited || code == .unavailable || code == .internal
        default: false
        }
    }

    /// 网络不通：显示缓存、标“离线”。
    public var isOffline: Bool {
        if case .network = self { return true }
        return false
    }

    public var isNotFound: Bool { apiCode == .notFound }
    public var isConflict: Bool { apiCode == .conflict }
    public var isRateLimited: Bool { apiCode == .rateLimited }

    /// 表单错误（参数不对）。
    public var isInvalidInput: Bool {
        switch self {
        case .invalidArgument, .api(_, .invalid, _, _): true
        default: false
        }
    }

    /// 服务端建议的退避时间（秒）。
    public var retryAfter: TimeInterval? {
        if case .api(_, _, _, let secs?) = self { return TimeInterval(secs) }
        return nil
    }

    /// 消息里拦下的密码个数（`containsSecrets`）。
    public var secretCount: Int? {
        if case .containsSecrets(let n) = self { return n }
        return nil
    }

    /// 界面该怎么处理。
    public var recovery: ErrorRecovery {
        if requiresSignIn { return .signIn }
        if isAccountFrozen { return .accountFrozen }
        if requiresUpgrade { return .upgrade }
        switch self {
        case .network: return .offline
        case .containsSecrets(let n): return .interceptSecrets(count: n)
        case .invalidArgument: return .showFormError
        case .unsupported: return .featureUnavailable
        case .api(_, let code, _, let secs):
            switch code {
            case .rateLimited, .unavailable: return .retryLater(after: secs.map(TimeInterval.init))
            case .conflict: return .refreshAndRetry
            case .invalid: return .showFormError
            case .notFound: return .goBack
            default: return .generic
            }
        default: return .generic
        }
    }

    /// 给开发者看的详情（“复制详情”）：英文原文，不含用户数据。
    public var debugDetails: String {
        switch self {
        case .network(let m): "network: \(m)"
        case .signedOut: "signed out"
        case .upgradeRequired: "upgrade required"
        case .accountFrozen: "account frozen"
        case .api(let status, let code, let m, let secs):
            "api \(status) \(code.rawValue): \(m)" + (secs.map { " (retry after \($0)s)" } ?? "")
        case .decode(let m): "bad response: \(m)"
        case .cache(let m): "cache: \(m)"
        case .containsSecrets(let n): "contains \(n) secret(s)"
        case .invalidArgument(let m): "invalid argument: \(m)"
        case .internal(let m): "internal: \(m)"
        case .malformed(let m): "malformed: \(m)"
        case .expired: "expired"
        case .badSignature: "bad signature"
        case .unsupported(let feature): "unsupported: \(feature)"
        }
    }

    /// 给用户看的文案（按错误码本地化，不用接口的英文 `message`）。
    public func localizedMessage(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .network: return zh ? "网络连接不可用，请稍后重试。" : "You're offline. Try again in a moment."
        case .signedOut: return zh ? "登录已失效，请重新登录。" : "You've been signed out. Please sign in again."
        case .upgradeRequired:
            return zh ? "当前版本过旧，请到 App Store 更新。" : "This version is too old. Please update from the App Store."
        case .accountFrozen:
            return zh ? "账号已被冻结，请联系客服。" : "Your account is frozen. Please contact support."
        case .containsSecrets(let n):
            return zh
                ? "消息里有 \(n) 处像密码或 key 的内容，对话里不收明文密码。"
                : "This message looks like it contains \(n) password(s) or key(s). Passwords don't belong in chat."
        case .invalidArgument: return zh ? "填写的内容不正确。" : "Some of the details aren't valid."
        case .malformed: return zh ? "二维码或签名格式不正确。" : "The code or signature is malformed."
        case .expired: return zh ? "已过期，请重新发起。" : "This has expired. Please start again."
        case .badSignature: return zh ? "签名校验失败。" : "The signature couldn't be verified."
        case .unsupported: return zh ? "这个功能暂未开放，敬请期待。" : "This feature isn't available yet."
        case .decode, .cache, .internal:
            return zh ? "出了点问题，请稍后重试。" : "Something went wrong. Please try again."
        case .api(_, let code, _, let secs):
            switch code {
            case .rateLimited:
                if let s = secs {
                    return zh ? "操作太频繁，请 \(s) 秒后再试。" : "Too many requests. Try again in \(s) seconds."
                }
                return zh ? "操作太频繁，请稍后再试。" : "Too many requests. Try again later."
            case .conflict: return zh ? "内容已被修改，请刷新后重试。" : "This changed in the meantime. Refresh and try again."
            case .invalid: return zh ? "填写的内容不正确。" : "Some of the details aren't valid."
            case .notFound: return zh ? "内容不存在或已被删除。" : "This no longer exists."
            case .forbidden: return zh ? "没有权限执行这个操作。" : "You don't have permission to do that."
            case .unavailable: return zh ? "服务暂时不可用，请稍后重试。" : "The service is temporarily unavailable."
            case .sessionRevoked, .unauthenticated:
                return zh ? "登录已失效，请重新登录。" : "You've been signed out. Please sign in again."
            case .accountFrozen: return zh ? "账号已被冻结，请联系客服。" : "Your account is frozen. Please contact support."
            case .upgradeRequired:
                return zh ? "当前版本过旧，请到 App Store 更新。" : "This version is too old. Please update from the App Store."
            case .internal, .unknown: return zh ? "出了点问题，请稍后重试。" : "Something went wrong. Please try again."
            }
        }
    }
}

extension ClientError: LocalizedError {
    public var errorDescription: String? { localizedMessage() }
    public var failureReason: String? { debugDetails }
}
