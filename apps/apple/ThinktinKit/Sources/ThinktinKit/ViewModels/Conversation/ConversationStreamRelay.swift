import Foundation

/// 事件流回调（后台线程）→ 主线程按批提交：回调先放进队列，队列从空变成不空时通知一次（`onPending`），主线程上
/// `drain()` 一次取走全部。事件流重置（`onReset`）后服务端会把保留期内的事件一下子补发过来，按批提交时一批只重新归并、
/// 刷新一次界面（docs/ios-packages.md 12.5 “on_reset 之后……视图模型要按批提交”）。
///
/// 顺序：队列是先进先出，主线程每次取走全部，所以不管通知的任务谁先跑，处理的顺序都和回调的顺序一致。
final class ConversationStreamRelay: EventListening, Sendable {
    private struct Queue {
        var items: [EventStreamElement] = []
        var notified = false
    }

    private let queue = Locked(Queue())
    private let onPending: @Sendable (ConversationStreamRelay) -> Void

    /// - Parameter onPending: 队列里有了新东西（每批只调一次）：切到主线程调 `drain()`。
    init(onPending: @escaping @Sendable (ConversationStreamRelay) -> Void) {
        self.onPending = onPending
    }

    func onEvent(_ event: InstanceEvent) { enqueue(.event(event)) }

    func onReset(oldestSeq: UInt64, latestSeq: UInt64?) {
        enqueue(.reset(oldestSeq: oldestSeq, latestSeq: latestSeq))
    }

    func onStatus(_ status: StreamStatus) { enqueue(.status(status)) }

    /// 取走队列里的全部（按回调的顺序）。
    func drain() -> [EventStreamElement] {
        queue.withLock { q in
            defer {
                q.items = []
                q.notified = false
            }
            return q.items
        }
    }

    private func enqueue(_ element: EventStreamElement) {
        let notify = queue.withLock { q -> Bool in
            q.items.append(element)
            guard !q.notified else { return false }
            q.notified = true
            return true
        }
        if notify { onPending(self) }
    }
}
