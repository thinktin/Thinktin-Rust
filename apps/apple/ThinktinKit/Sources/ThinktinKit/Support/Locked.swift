import Foundation

/// 用锁保护的可变状态。iOS 17 还没有 `Synchronization.Mutex`，这里用 `NSLock`（Linux 的 Foundation 也有）。
///
/// 闭包在锁里同步执行，不要在里面等异步操作，也不要回调可能再拿同一把锁的代码。
package final class Locked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    package init(_ state: State) {
        self.state = state
    }

    package func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    /// 当前值的拷贝。
    package var value: State {
        withLock { $0 }
    }
}
