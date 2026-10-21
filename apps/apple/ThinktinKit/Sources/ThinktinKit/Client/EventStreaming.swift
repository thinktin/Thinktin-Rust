import Foundation

/// 收实例事件的一方（视图模型实现）。回调在后台线程上，界面更新要切回主线程。
public protocol EventListening: AnyObject, Sendable {
    func onEvent(_ event: InstanceEvent)
    /// 续传位置已经过了保留期：本地的旧事件作废，清空后从 `cachedEvents` / 服务端重新加载。
    func onReset(oldestSeq: UInt64, latestSeq: UInt64?)
    func onStatus(_ status: StreamStatus)
}

/// 一个实例的事件订阅。`stop()` 或释放就停止。
public final class EventSubscriptionHandle: Sendable {
    private let onStop: Locked<(@Sendable () -> Void)?>

    public init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = Locked(onStop)
    }

    /// 停止订阅（可以重复调用）。
    public func stop() {
        let action = onStop.withLock { stop -> (@Sendable () -> Void)? in
            defer { stop = nil }
            return stop
        }
        action?()
    }

    public var isStopped: Bool { onStop.withLock { $0 == nil } }

    deinit {
        stop()
    }
}

/// 事件流里的一项（`events(instanceID:afterSeq:)` 的元素）。
public enum EventStreamElement: Hashable, Sendable {
    case event(InstanceEvent)
    case reset(oldestSeq: UInt64, latestSeq: UInt64?)
    case status(StreamStatus)
}

/// 把回调转成 `AsyncStream`。
final class StreamListener: EventListening, Sendable {
    let continuation: AsyncStream<EventStreamElement>.Continuation

    init(_ continuation: AsyncStream<EventStreamElement>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(_ event: InstanceEvent) { continuation.yield(.event(event)) }
    func onReset(oldestSeq: UInt64, latestSeq: UInt64?) {
        continuation.yield(.reset(oldestSeq: oldestSeq, latestSeq: latestSeq))
    }
    func onStatus(_ status: StreamStatus) {
        continuation.yield(.status(status))
        if status.isFinal { continuation.finish() }
    }
}
