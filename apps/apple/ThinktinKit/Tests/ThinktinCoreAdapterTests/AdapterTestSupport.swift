import Foundation
import Testing
import ThinktinKit

@testable import ThinktinCoreAdapter

// 适配层测试共用的小工具。
//
// 这个目标里有的文件同时 import ThinktinKit 和 ThinktinCore（构造 ThinktinCore 的记录），
// 两边同名的类型（`Run`、`Plan`、`ClientError`……）一律写全 `ThinktinKit.X` / `ThinktinCore.X`。

enum AdapterFixture {
    /// 本机一个没人监听的端口：连接立即被拒（`network`），测试不依赖服务端，也不出本机。
    static let unreachableBaseURL = "http://127.0.0.1:9"

    /// 2023-11-14 22:13:20.123 UTC（带毫秒，检查毫秒没丢）。
    static let createdMs: Int64 = 1_700_000_000_123
    static let startedMs: Int64 = 1_700_000_060_000
    static let finishedMs: Int64 = 1_700_000_360_500

    /// UUID 形式的 id（client-core 解析 id 时要求是 UUID）。
    static let userID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a01"
    static let deviceID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a02"
    static let instanceID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a03"
    static let runID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a04"
    static let rootRunID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a05"
    static let planID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a06"
    static let approvalID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a07"
    static let itemID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a08"

    /// 一个看起来已经登录的会话（令牌是假的，只在本机用）。
    static var session: ThinktinKit.Session {
        ThinktinKit.Session(
            userID: UserID(userID), deviceID: DeviceID(deviceID), accessToken: "access-token",
            refreshToken: "refresh-token")
    }

    /// 经真实 Rust 核心建的客户端。
    static func client(sessions: InMemorySessionStore = InMemorySessionStore(), cachePath: String? = nil) throws
        -> CoreClient
    {
        try CoreClient(
            baseURL: unreachableBaseURL, cachePath: cachePath, deviceName: "测试设备", timeout: 5, sessions: sessions)
    }

    /// 毫秒 → Date（测试里写期望值用）。
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}

/// 超时了还没结束。
struct TimedOut: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "timed out after \(seconds)s" }
}

/// 在 `seconds` 秒内跑完 `body`，否则抛 `TimedOut`（事件流的测试别因为核心没回调就卡住）。
func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOut(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimedOut(seconds: seconds) }
        return first
    }
}

/// 记下收到的回调，同时转成 `AsyncStream`（测试里按顺序等）。
final class RecordingListener: EventListening, Sendable {
    enum Callback: Hashable, Sendable {
        case event(ThinktinKit.InstanceEvent)
        case reset(oldestSeq: UInt64, latestSeq: UInt64?)
        case status(ThinktinKit.StreamStatus)
    }

    let stream: AsyncStream<Callback>
    private let continuation: AsyncStream<Callback>.Continuation
    private let log = Locked<[Callback]>([])

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Callback.self, bufferingPolicy: .unbounded)
    }

    /// 到现在为止收到的回调。
    var callbacks: [Callback] { log.value }

    /// 收到的事件的序号。
    var seqs: [UInt64] {
        callbacks.compactMap { if case .event(let e) = $0 { e.seq } else { nil } }
    }

    private func record(_ c: Callback) {
        log.withLock { $0.append(c) }
        continuation.yield(c)
    }

    func onEvent(_ event: ThinktinKit.InstanceEvent) { record(.event(event)) }
    func onReset(oldestSeq: UInt64, latestSeq: UInt64?) { record(.reset(oldestSeq: oldestSeq, latestSeq: latestSeq)) }
    func onStatus(_ status: ThinktinKit.StreamStatus) {
        record(.status(status))
        if status.isFinal { continuation.finish() }
    }
}
