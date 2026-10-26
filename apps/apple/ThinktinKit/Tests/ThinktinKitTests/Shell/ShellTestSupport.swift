import Foundation
import Testing

@testable import ThinktinKit

// 应用框架测试共用的小工具。

/// 演示数据上的 Mock 客户端：不自动回答、不等待。
func makeShellMock(signedIn: Bool = true) -> MockClient {
    MockClient(state: DemoData.state(signedIn: signedIn), stepDelay: 0, autoReply: false)
}

/// 等到条件成立（最多约 5 秒）。`ObservedClient` 的报告异步送到主线程，测试里用它等。
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// 等到异步条件成立（最多约 5 秒）。
@MainActor
func eventuallyAsync(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// 收事件流回调（回调在后台线程上）。
final class StatusCollector: EventListening, Sendable {
    let statuses = Locked<[StreamStatus]>([])
    let events = Locked<[InstanceEvent]>([])

    func onEvent(_ event: InstanceEvent) { events.withLock { $0.append(event) } }
    func onReset(oldestSeq: UInt64, latestSeq: UInt64?) {}
    func onStatus(_ status: StreamStatus) { statuses.withLock { $0.append(status) } }

    /// 等到收到某个状态（最多约 5 秒）。
    func wait(for status: StreamStatus) async -> Bool {
        for _ in 0..<500 {
            if statuses.value.contains(status) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return statuses.value.contains(status)
    }
}

/// 收 `ObservedClient` 的报告。
final class ActivityLog: Sendable {
    let items = Locked<[ClientActivity]>([])

    func record(_ activity: ClientActivity) { items.withLock { $0.append(activity) } }

    var failures: [ClientError] {
        items.value.compactMap {
            if case .failed(let e) = $0 { return e }
            return nil
        }
    }

    var reachableCount: Int {
        items.value.filter {
            if case .reachable = $0 { return true }
            return false
        }.count
    }

    var signedInCount: Int {
        items.value.filter {
            if case .signedIn = $0 { return true }
            return false
        }.count
    }

    var signedOutCount: Int {
        items.value.filter {
            if case .signedOut = $0 { return true }
            return false
        }.count
    }

    var streamStatuses: [StreamStatus] {
        items.value.compactMap {
            if case .stream(let s, _, _) = $0 { return s }
            return nil
        }
    }

    var streamEndedCount: Int {
        items.value.filter {
            if case .streamEnded = $0 { return true }
            return false
        }.count
    }

    func wait(until condition: @Sendable (ActivityLog) -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition(self) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition(self)
    }
}
