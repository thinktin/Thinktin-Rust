import Foundation
import Testing

@testable import ThinktinKit

// ObservedClient：原样转发，同时把错误、登录状态、事件流状态报给应用框架。

@Suite("包了一层的客户端")
struct ObservedClientTests {
    private func make(signedIn: Bool = true) -> (MockClient, ObservedClient, ActivityLog) {
        let mock = makeShellMock(signedIn: signedIn)
        let log = ActivityLog()
        let client = ObservedClient(mock) { log.record($0) }
        return (mock, client, log)
    }

    @Test("原样转发结果和错误")
    func forwards() async throws {
        let (mock, client, log) = make()
        #expect(client.signedIn())
        #expect(try await client.instances().map(\.id) == mock.state.instances.map(\.id))
        #expect(try client.cachedUnread() == mock.state.unreadCount)
        #expect(try await client.getRun(DemoData.postRunID).id == DemoData.postRunID)
        mock.failNext(with: .api(status: 404, code: .notFound, message: "x", retryAfterSecs: nil))
        await #expect(throws: ClientError.api(status: 404, code: .notFound, message: "x", retryAfterSecs: nil)) {
            try await client.getPlan(DemoData.digestPlanID)
        }
        #expect(log.failures == [.api(status: 404, code: .notFound, message: "x", retryAfterSecs: nil)])
        // 协议扩展里的便捷方法也经过这一层。
        mock.failNext(with: .signedOut)
        await #expect(throws: ClientError.signedOut) {
            try await client.sendMessage(instanceID: DemoData.writerID, text: "hi")
        }
        #expect(log.failures.last == .signedOut)
        #expect(client.secretDetector.detectSecrets(in: "hello").isEmpty)
    }

    @Test("同步的缓存方法出错也报")
    func syncFailures() {
        let (mock, client, log) = make()
        mock.failNext(with: .cache(message: "disk"))
        #expect(throws: ClientError.cache(message: "disk")) { try client.cachedInstances() }
        #expect(log.failures == [.cache(message: "disk")])
    }

    @Test("网络恢复只报一次")
    func reachability() async throws {
        let (mock, client, log) = make()
        _ = try await client.instances()
        #expect(log.reachableCount == 0)
        mock.failNext(with: .network(message: "offline"))
        _ = try? await client.instances()
        mock.failNext(with: .network(message: "offline"))
        _ = try? await client.agents()
        _ = try await client.instances()
        _ = try await client.instances()
        #expect(log.reachableCount == 1)
        #expect(log.failures == [.network(message: "offline"), .network(message: "offline")])
    }

    @Test("登录、退出、注销、下线本机")
    func sessionChanges() async throws {
        let (mock, client, log) = make(signedIn: false)
        _ = try await client.login(phone: "+8613800138000", code: mock.state.verificationCode)
        #expect(log.signedInCount == 1)
        // 下线别的设备不算退出。
        try await client.revokeDevice(DemoData.iPadDeviceID)
        #expect(log.signedOutCount == 0)
        try await client.revokeDevice(DemoData.deviceID)
        #expect(log.signedOutCount == 1)
        _ = try await client.login(phone: "+8613800138000", code: mock.state.verificationCode)
        try await client.logout()
        #expect(log.signedOutCount == 2)
        // 登录失败不报登录。
        _ = try? await client.login(phone: "+8613800138000", code: "000000")
        #expect(log.signedInCount == 2)

        _ = try await client.login(phone: "+8613800138000", code: mock.state.verificationCode)
        try await client.sendSelfCode(purpose: .deleteAccount)
        try await client.deleteAccount(code: mock.state.verificationCode)
        #expect(log.signedOutCount == 3)
    }

    @Test("事件流：转发回调、报连接状态、停了报结束")
    func streams() async throws {
        let (mock, client, log) = make()
        let collector = StatusCollector()
        let handle = try client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: collector)
        #expect(await collector.wait(for: .live))
        #expect(!collector.events.value.isEmpty)
        #expect(client.activeStreamCount == 1)
        #expect(await log.wait { $0.streamStatuses.contains(.live) })
        #expect(log.streamStatuses.first == .connecting)

        mock.play(MockEventScript(steps: [.status(.reconnecting(retryIn: 3))]), instanceID: DemoData.writerID)
        await mock.waitForPlayback()
        #expect(await collector.wait(for: .reconnecting(retryIn: 3)))
        #expect(await log.wait { $0.streamStatuses.contains(.reconnecting(retryIn: 3)) })

        handle.stop()
        handle.stop()
        #expect(client.activeStreamCount == 0)
        #expect(log.streamEndedCount == 1)
    }

    @Test("事件流收到终止状态就从表里拿掉")
    func finalStatus() async throws {
        let (_, client, log) = make()
        let collector = StatusCollector()
        let handle = try client.subscribe(instanceID: "no-such-instance", afterSeq: nil, listener: collector)
        #expect(await collector.wait(for: .notFound))
        #expect(await log.wait { $0.streamEndedCount == 1 })
        #expect(client.activeStreamCount == 0)
        handle.stop()
        #expect(log.streamEndedCount == 1)
    }

    @Test("强制升级：停掉所有事件流，之后不能再订阅")
    func halt() async throws {
        let (_, client, log) = make()
        let a = StatusCollector()
        let b = StatusCollector()
        let handles = [
            try client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: a),
            try client.subscribe(instanceID: DemoData.reviewerID, afterSeq: nil, listener: b),
        ]
        #expect(await a.wait(for: .live))
        #expect(await b.wait(for: .live))
        client.haltStreams()
        #expect(client.isHalted)
        #expect(client.activeStreamCount == 0)
        // 每个订阅的一方收到一次 upgradeRequired（和 client-core 遇到 426 时一样，stopped 只表示调用方停的）。
        #expect(a.statuses.value.last == .upgradeRequired)
        #expect(b.statuses.value.last == .upgradeRequired)
        #expect(log.streamEndedCount == 2)
        #expect(throws: ClientError.upgradeRequired) {
            try client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: StatusCollector())
        }
        #expect(log.failures.last == .upgradeRequired)
        for handle in handles { handle.stop() }
        #expect(log.streamEndedCount == 2)
    }

    @Test("订阅失败不留登记")
    func subscribeFailure() {
        let (mock, client, _) = make()
        mock.failNext(with: .invalidArgument(message: "bad id"))
        #expect(throws: ClientError.invalidArgument(message: "bad id")) {
            try client.subscribe(instanceID: DemoData.writerID, afterSeq: nil, listener: StatusCollector())
        }
        #expect(client.activeStreamCount == 0)
    }
}
