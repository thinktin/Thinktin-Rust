import Foundation
import Testing
import ThinktinCore
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 回调桥接（Bridges.swift）：直接喂 ThinktinCore 的回调，看 ThinktinKit 一侧收到什么。
@Suite("回调桥接")
struct BridgeTests {
    typealias F = AdapterFixture

    static func event(_ seq: UInt64, kind: String = "agent.message") -> ThinktinCore.InstanceEvent {
        ThinktinCore.InstanceEvent(
            instanceId: F.instanceID, seq: seq, runId: F.runID, kind: kind, payloadJson: #"{"text":"第 \#(seq) 条"}"#,
            aiGenerated: true, createdAtMs: F.createdMs + Int64(seq))
    }

    @Test("事件转成 ThinktinKit 的模型；afterSeq 之前（含）的不回调")
    func eventsAfterSeq() {
        let listener = RecordingListener()
        let bridge = EventListenerBridge(listener, afterSeq: 4)
        for seq: UInt64 in [3, 4, 5, 6] { bridge.onEvent(event: Self.event(seq)) }
        #expect(listener.seqs == [5, 6])
        guard case .event(let first)? = listener.callbacks.first else {
            Issue.record("第一条回调应该是事件：\(listener.callbacks)")
            return
        }
        #expect(first.instanceID == InstanceID(F.instanceID))
        #expect(first.runID == RunID(F.runID))
        #expect(first.kind == .agentMessage)
        #expect(first.payloadJSON == #"{"text":"第 5 条"}"#)
        #expect(first.isAIGenerated)
        #expect(first.createdAt.unixMilliseconds == F.createdMs + 5)
    }

    @Test("afterSeq 为 nil：全部回调")
    func allEvents() {
        let listener = RecordingListener()
        let bridge = EventListenerBridge(listener, afterSeq: nil)
        for seq: UInt64 in [1, 2, 3] { bridge.onEvent(event: Self.event(seq)) }
        #expect(listener.seqs == [1, 2, 3])
    }

    @Test("onReset 之后旧的过滤条件作废：重新补发的事件全部回调")
    func resetClearsFilter() {
        let listener = RecordingListener()
        let bridge = EventListenerBridge(listener, afterSeq: 10)
        bridge.onEvent(event: Self.event(9))
        bridge.onReset(oldestSeq: 7, latestSeq: 12)
        bridge.onEvent(event: Self.event(7))
        bridge.onEvent(event: Self.event(8))
        #expect(listener.seqs == [7, 8])
        #expect(listener.callbacks.first == .reset(oldestSeq: 7, latestSeq: 12))
    }

    @Test("状态转成 ThinktinKit 的 StreamStatus")
    func statuses() {
        let listener = RecordingListener()
        let bridge = EventListenerBridge(listener, afterSeq: nil)
        bridge.onStatus(status: .connecting)
        bridge.onStatus(status: .live)
        bridge.onStatus(status: .reconnecting(retryInMs: 2500))
        bridge.onStatus(status: .accountFrozen)
        #expect(
            listener.callbacks == [
                .status(.connecting), .status(.live), .status(.reconnecting(retryIn: 2.5)), .status(.accountFrozen),
            ])
    }

    @Test("会话存储：client-core 存的会话转成 ThinktinKit 的放进 SessionStoring，读出来再转回去")
    func sessionStore() {
        let store = InMemorySessionStore()
        let bridge = SessionStoreBridge(store)
        #expect(bridge.load() == nil)

        let core = ThinktinCore.Session(
            userId: F.userID, deviceId: F.deviceID, accessToken: "a-1", refreshToken: "r-1")
        bridge.save(session: core)
        #expect(store.load() == F.session.with(accessToken: "a-1", refreshToken: "r-1"))
        #expect(bridge.load() == core)

        bridge.save(session: nil)
        #expect(store.load() == nil)
        #expect(bridge.load() == nil)
    }
}

extension ThinktinKit.Session {
    fileprivate func with(accessToken: String, refreshToken: String) -> ThinktinKit.Session {
        var s = self
        s.accessToken = accessToken
        s.refreshToken = refreshToken
        return s
    }
}
