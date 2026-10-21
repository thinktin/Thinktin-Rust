import Foundation
import ThinktinKit

// ThinktinKit 的协议 ↔ ThinktinCore（UniFFI）的回调协议。client-core 在自己的后台线程上调这些方法，
// 所以每个桥接类都是 `Sendable`，可变状态放在 `Locked` 里。

/// 把 ThinktinKit 的 `SessionStoring`（App 里是 Keychain）交给 client-core 当 `SessionStore` 用。
final class SessionStoreBridge: Core.SessionStore {
    let store: any SessionStoring

    init(_ store: any SessionStoring) {
        self.store = store
    }

    func load() -> Core.Session? {
        store.load()?.core
    }

    func save(session: Core.Session?) {
        store.save(session.map { ThinktinKit.Session(core: $0) })
    }
}

/// 把 client-core 的事件回调转成 ThinktinKit 的模型，交给 `EventListening`（视图模型）。
///
/// - `afterSeq`：这个序号之前（含）的事件不再回调（界面已经从 `cachedEvents` 显示过）。client-core 的 `subscribe`
///   从缓存的续传位置开始补发，没有缓存时从头补发，所以在这里过滤。
/// - `onReset` 之后本地的旧事件全部作废，界面会清空重新加载，过滤条件随之取消：之后补发的事件全部回调。
final class EventListenerBridge: Core.EventListener {
    let listener: any EventListening
    private let afterSeq: Locked<UInt64?>

    init(_ listener: any EventListening, afterSeq: UInt64?) {
        self.listener = listener
        self.afterSeq = Locked(afterSeq)
    }

    func onEvent(event: Core.InstanceEvent) {
        let alreadyShown = afterSeq.withLock { after in after.map { event.seq <= $0 } ?? false }
        if alreadyShown { return }
        listener.onEvent(ThinktinKit.InstanceEvent(core: event))
    }

    func onReset(oldestSeq: UInt64, latestSeq: UInt64?) {
        afterSeq.withLock { $0 = nil }
        listener.onReset(oldestSeq: oldestSeq, latestSeq: latestSeq)
    }

    func onStatus(status: Core.StreamStatus) {
        listener.onStatus(ThinktinKit.StreamStatus(core: status))
    }
}

/// 发送前的密码检查（11.6）：规则在 client-core 的 `secrets.rs`，不联网，不需要客户端实例。
public struct CoreSecretDetector: SecretDetector {
    public init() {}

    public func detectSecrets(in text: String) -> [ThinktinKit.DetectedSecret] {
        Core.detectSecrets(text).map { ThinktinKit.DetectedSecret(core: $0) }
    }

    public func redactMessage(_ text: String, references: [ThinktinKit.SecretReference]) -> String {
        Core.redactMessage(text, references: references.map(\.core))
    }

    public func uniqueVaultName(base: String, taken: [String]) -> String {
        Core.uniqueVaultName(base: base, taken: taken)
    }
}
