import Foundation

/// 会话的存储（App 里是 Keychain，见 Thinktin/Platform）。`save(nil)` 表示退出登录或会话失效，要删掉。
///
/// 和 ThinktinCore 的 `SessionStore` 一一对应；client-core 在自己的后台线程上调用它。
public protocol SessionStoring: AnyObject, Sendable {
    func load() -> Session?
    func save(_ session: Session?)
}

/// 只放内存里的会话存储（测试、预览用；App 重启后就没了）。
public final class InMemorySessionStore: SessionStoring, @unchecked Sendable {
    private let state: Locked<Session?>

    public init(_ session: Session? = nil) {
        state = Locked(session)
    }

    public func load() -> Session? { state.value }

    public func save(_ session: Session?) {
        state.withLock { $0 = session }
    }
}
