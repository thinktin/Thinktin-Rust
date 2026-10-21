import Foundation
import Testing
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 经真实的 Rust 核心（ThinktinCore 包；Linux 上链 `libclient_core.so`）。不连服务端：接口地址是本机一个没人监听的端口，
/// 没登录时 client-core 不发请求就返回 `SignedOut`，登录了的请求连接被拒（`Network`）。
@Suite("CoreClient（经真实核心）")
struct CoreClientTests {
    // MARK: 新建与登录状态

    @Test("新建的客户端没有登录")
    func newClientIsSignedOut() throws {
        let client = try AdapterFixture.client()
        #expect(!client.signedIn())
        #expect(client.secretDetector is CoreSecretDetector)
    }

    @Test("平台名不对时 client-core 拒绝，抛 invalidArgument")
    func badPlatformIsRejected() throws {
        let error = #expect(throws: ThinktinKit.ClientError.self) {
            _ = try CoreClient(
                baseURL: AdapterFixture.unreachableBaseURL, platform: .unknown("watchos"), deviceName: "测试设备",
                sessions: InMemorySessionStore())
        }
        guard case .invalidArgument(let message)? = error else {
            Issue.record("应该是 invalidArgument，实际是 \(String(describing: error))")
            return
        }
        #expect(message.contains("watchos"))
    }

    @Test("超时换成整数秒：向上取整，负数当 0，NaN 和无穷大用 30 秒")
    func timeoutSeconds() {
        #expect(CoreClient.wholeSeconds(30) == 30)
        #expect(CoreClient.wholeSeconds(2.1) == 3)
        #expect(CoreClient.wholeSeconds(-1) == 0)
        #expect(CoreClient.wholeSeconds(.infinity) == 30)
        #expect(CoreClient.wholeSeconds(.nan) == 30)
        #expect(CoreClient.wholeSeconds(1e12) == UInt32.max)
    }

    @Test("未登录时 me() 抛 signedOut")
    func meWhenSignedOut() async throws {
        let client = try AdapterFixture.client()
        await #expect(throws: ThinktinKit.ClientError.signedOut) {
            _ = try await client.me()
        }
        #expect(!client.signedIn())
    }

    @Test("未登录时其他要登录的接口也抛 signedOut")
    func otherCallsWhenSignedOut() async throws {
        let client = try AdapterFixture.client()
        await #expect(throws: ThinktinKit.ClientError.signedOut) { _ = try await client.instances() }
        await #expect(throws: ThinktinKit.ClientError.signedOut) { _ = try await client.syncInbox(limit: 20) }
        await #expect(throws: ThinktinKit.ClientError.signedOut) {
            _ = try await client.usage(
                group: .day, from: Date(timeIntervalSince1970: 0), to: Date(), timeZone: .current)
        }
    }

    @Test("id 格式不对：client-core 先校验参数，抛 invalidArgument")
    func malformedIDs() async throws {
        let client = try AdapterFixture.client()
        let error = await #expect(throws: ThinktinKit.ClientError.self) {
            _ = try await client.getRun("not-a-uuid")
        }
        guard case .invalidArgument(let message)? = error else {
            Issue.record("应该是 invalidArgument，实际是 \(String(describing: error))")
            return
        }
        #expect(message.contains("not-a-uuid"))
        #expect(error?.recovery == .showFormError)

        #expect {
            _ = try client.subscribe(instanceID: "bad id", afterSeq: nil, listener: RecordingListener())
        } throws: { error in
            guard case .invalidArgument = error as? ThinktinKit.ClientError else { return false }
            return true
        }
    }

    // MARK: 会话存储

    @Test("会话从 SessionStoring 恢复；退出登录时服务端连不上也清掉本地会话")
    func sessionRestoreAndLogout() async throws {
        let store = InMemorySessionStore(AdapterFixture.session)
        let client = try AdapterFixture.client(sessions: store)
        #expect(client.signedIn())

        // 接口地址连不上：client-core 报 Network，但本地会话照样清掉（经 SessionStoreBridge.save(nil)）。
        let error = await #expect(throws: ThinktinKit.ClientError.self) {
            try await client.logout()
        }
        guard case .network? = error else {
            Issue.record("应该是 network，实际是 \(String(describing: error))")
            return
        }
        #expect(error?.isOffline == true)
        #expect(!client.signedIn())
        #expect(store.load() == nil)
    }

    @Test("登录了但服务端连不上：抛 network")
    func networkErrorWhenSignedIn() async throws {
        let client = try AdapterFixture.client(sessions: InMemorySessionStore(AdapterFixture.session))
        let error = await #expect(throws: ThinktinKit.ClientError.self) {
            _ = try await client.agents()
        }
        guard case .network? = error else {
            Issue.record("应该是 network，实际是 \(String(describing: error))")
            return
        }
    }

    // MARK: 缓存

    @Test("带缓存库：没登录时缓存接口都返回空")
    func cacheWhenSignedOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thinktin-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = try AdapterFixture.client(cachePath: dir.appendingPathComponent("cache.sqlite").path)
        let instance = InstanceID(AdapterFixture.instanceID)
        #expect(try client.cachedInstances().isEmpty)
        #expect(try client.cachedRuns(instanceID: instance, limit: 20).isEmpty)
        #expect(try client.cachedEvents(instanceID: instance, afterSeq: 0, limit: 100).isEmpty)
        #expect(try client.cachedInbox(before: nil, limit: 20).isEmpty)
        #expect(try client.cachedUnread() == 0)
    }

    @Test("缓存库路径打不开：抛 cache")
    func unopenableCache() throws {
        // 上一级是个普通文件：谁来跑（包括 root）都打不开。
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "thinktin-adapter-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let error = #expect(throws: ThinktinKit.ClientError.self) {
            _ = try AdapterFixture.client(cachePath: file.appendingPathComponent("cache.sqlite").path)
        }
        guard case .cache? = error else {
            Issue.record("应该是 cache，实际是 \(String(describing: error))")
            return
        }
    }

    // MARK: 事件流（EventListener 桥接经真实核心）

    @Test("未登录时订阅：回调 connecting → signedOut，然后停止")
    func subscribeWhenSignedOut() async throws {
        let client = try AdapterFixture.client()
        let stream = try client.events(instanceID: InstanceID(AdapterFixture.instanceID))
        let elements = try await withTimeout(10) {
            var all: [EventStreamElement] = []
            for await element in stream { all.append(element) }
            return all
        }
        #expect(elements == [.status(.connecting), .status(.signedOut)])
    }

    @Test("连不上时在重连；stop() 后回调 stopped")
    func stopWhileReconnecting() async throws {
        let client = try AdapterFixture.client(sessions: InMemorySessionStore(AdapterFixture.session))
        let listener = RecordingListener()
        let handle = try client.subscribe(
            instanceID: InstanceID(AdapterFixture.instanceID), afterSeq: nil, listener: listener)
        let stream = listener.stream
        let statuses = try await withTimeout(20) {
            var statuses: [ThinktinKit.StreamStatus] = []
            for await callback in stream {
                guard case .status(let status) = callback else { continue }
                statuses.append(status)
                if case .reconnecting = status { handle.stop() }
            }
            return statuses
        }
        #expect(statuses.first == .connecting)
        #expect(statuses.last == .stopped)
        let retry = statuses.lazy.compactMap { status -> TimeInterval? in
            if case .reconnecting(let after) = status { after } else { nil }
        }.first
        // client-core 的最小退避 500ms，带 ±25% 抖动；毫秒已经换成秒。
        #expect(retry.map { $0 > 0.3 && $0 < 1 } == true, "重连等待 \(String(describing: retry)) 秒")
        #expect(handle.isStopped)
        #expect(listener.seqs.isEmpty)
    }

    // MARK: 密码检查（经核心的 secrets.rs）

    @Test("detectSecrets：认出 Anthropic key，位置是 UTF-16 下标")
    func detectAPIKey() throws {
        let client = try AdapterFixture.client()
        let key = "sk-ant-api03-AbCdEf0123456789AbCdEf0123456789xyzXYZ"
        let prefix = "帮我用这个 key："
        let text = "\(prefix)\(key)，谢谢"
        let found = client.detectSecrets(in: text)
        try #require(found.count == 1)
        let hit = found[0]
        #expect(hit.kind == .apiKey)
        #expect(hit.value == key)
        #expect(hit.suggestedName == "anthropic")
        #expect(hit.service == "anthropic")
        #expect(hit.isStorable)
        #expect(hit.utf16Range == prefix.utf16.count..<(prefix.utf16.count + key.utf16.count))
        #expect(hit.range(in: text).map { String(text[$0]) } == key)
    }

    @Test("detectSecrets：emoji 在前面时下标仍然对（UTF-16，不是字节）")
    func detectAfterEmoji() {
        let text = "🔑🔑 密码：hunter2!"
        let found = CoreSecretDetector().detectSecrets(in: text)
        #expect(found.count == 1)
        #expect(found.first?.kind == .labeled)
        #expect(found.first?.value == "hunter2!")
        #expect(found.first.flatMap { $0.range(in: text) }.map { String(text[$0]) } == "hunter2!")
    }

    @Test("detectSecrets：私钥不能存进保险箱；普通文字没有命中")
    func detectPrivateKeyAndNothing() {
        let detector = CoreSecretDetector()
        let pem =
            "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----"
        let found = detector.detectSecrets(in: "这是我的私钥\n\(pem)\n帮我配上")
        #expect(found.count == 1)
        #expect(found.first?.kind == .privateKey)
        #expect(found.first?.isStorable == false)
        #expect(detector.detectSecrets(in: "实例 0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a6b 挂了，帮我看看").isEmpty)
    }

    @Test("redactMessage：所有出现的地方都换成引用")
    func redact() throws {
        let client = try AdapterFixture.client()
        let text = "密码是 Abc12345，再说一遍 Abc12345；另一个 Abc123456789"
        let out = client.secretDetector.redactMessage(
            text,
            references: [
                ThinktinKit.SecretReference(value: "Abc12345", name: "github"),
                ThinktinKit.SecretReference(value: "Abc123456789", name: "mail"),
            ])
        #expect(out == "密码是 [vault:github]，再说一遍 [vault:github]；另一个 [vault:mail]")
        #expect(client.detectSecrets(in: out).isEmpty)
    }

    @Test("uniqueVaultName：重名加序号，名字先按规则整理")
    func uniqueName() {
        let detector = CoreSecretDetector()
        #expect(detector.uniqueVaultName(base: "github", taken: ["github", "github_2"]) == "github_3")
        #expect(detector.uniqueVaultName(base: "mail", taken: ["github"]) == "mail")
        #expect(detector.uniqueVaultName(base: "GitHub Token!", taken: []) == "github_token")
    }
}
