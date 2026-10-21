import Foundation
import Testing
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 整条链路：CoreClient → 真实的 client-core → 本机的 `StubHTTPServer` → JSON 解析 → 适配层转换。
/// 检查参数（id、时间、枚举）到了请求里是什么样，响应和错误到了 ThinktinKit 一侧是什么样。
@Suite("CoreClient（经真实核心和本机 HTTP 服务端）")
struct CoreClientHTTPTests {
    typealias F = AdapterFixture
    typealias R = StubHTTPServer.Response

    /// 带着已登录会话的客户端，接口地址指向 `server`。
    static func client(
        _ server: StubHTTPServer, sessions: InMemorySessionStore = InMemorySessionStore(AdapterFixture.session),
        cachePath: String? = nil
    ) throws -> CoreClient {
        try CoreClient(
            baseURL: server.baseURL, cachePath: cachePath, deviceName: "测试设备", timeout: 10, sessions: sessions)
    }

    static let instanceJSON = """
        {"id":"\(F.instanceID)","agent_id":"claude","agent_version":"2.0.1","harness":"acp","name":"写周报的",
         "state":"paused","created_at":"2023-11-14T22:13:20.123Z","last_active_at":"2023-11-14T22:19:20.500Z"}
        """

    @Test("me()：带上访问令牌；User 的枚举和毫秒时间都对")
    func me() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/me": R(
                200,
                json: """
                    {"id":"\(F.userID)","phone":"+8613800138000","display_name":"小明","status":"frozen",
                     "locale":"en","created_at":"2023-11-14T22:13:20.123Z"}
                    """)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let user = try await client.me()
        #expect(user.id == UserID(F.userID))
        #expect(user.phone == "+8613800138000")
        #expect(user.displayName == "小明")
        #expect(user.status == .frozen)
        #expect(user.locale == .en)
        #expect(user.createdAt.unixMilliseconds == F.createdMs)

        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/me")
        #expect(request.headers["authorization"] == "Bearer access-token")
    }

    @Test("instances()：转成 ThinktinKit 的 Instance，并写进缓存（cachedInstances 读得到）")
    func instancesAndCache() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/instances": R(200, json: #"{"instances":[\#(Self.instanceJSON)]}"#)
        ])
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thinktin-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try Self.client(server, cachePath: dir.appendingPathComponent("cache.sqlite").path)

        #expect(try client.cachedInstances().isEmpty)
        let instances = try await client.instances()
        try #require(instances.count == 1)
        let instance = instances[0]
        #expect(instance.id == InstanceID(F.instanceID))
        #expect(instance.agentID == AgentID("claude"))
        #expect(instance.name == "写周报的")
        #expect(instance.state == .paused)
        #expect(instance.createdAt.unixMilliseconds == F.createdMs)
        #expect(instance.lastActiveAt.unixMilliseconds == 1_700_000_360_500)
        #expect(try client.cachedInstances() == instances)
    }

    @Test("usage()：Date 换成 RFC 3339、时区换成 IANA 名称；响应的数字换成 Int")
    func usage() async throws {
        let bucket = """
            {"key":"anthropic/claude-sonnet","requests":3,"input_tokens":1000,"cache_read_tokens":200,
             "cache_write_tokens":50,"output_tokens":400,"charged_tokens":1650,"estimated_requests":1,"failed_requests":0}
            """
        let server = try StubHTTPServer(routes: [
            "GET /v1/usage": R(200, json: #"{"buckets":[\#(bucket)],"total":\#(bucket)}"#)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let summary = try await client.usage(
            group: .model, from: F.date(1_700_000_000_000), to: F.date(1_700_086_400_000),
            timeZone: TimeZone(identifier: "Asia/Shanghai"))
        #expect(summary.buckets.map(\.key) == ["anthropic/claude-sonnet"])
        #expect(summary.total.requests == 3)
        #expect(summary.total.chargedTokens == 1650)
        #expect(summary.total.totalTokens == 1650)

        let query = try #require(server.requests.first).query
        #expect(query["group"] == "model")
        #expect(query["tz"] == "Asia/Shanghai")
        #expect(query["from"].flatMap { ISO8601DateFormatter().date(from: $0) } == F.date(1_700_000_000_000))
        #expect(query["to"].flatMap { ISO8601DateFormatter().date(from: $0) } == F.date(1_700_086_400_000))
    }

    @Test("artifactContent()：原始字节原样变成 Data")
    func artifactContent() async throws {
        let bytes = Data([0x00, 0xFF, 0x10, 0x80]) + Data("报告".utf8)
        let server = try StubHTTPServer(routes: [
            "GET /v1/artifacts/\(F.itemID)/content": R(200, bytes: bytes, contentType: "application/octet-stream")
        ])
        defer { server.stop() }
        let client = try Self.client(server)
        #expect(try await client.artifactContent(ArtifactID(F.itemID)) == bytes)
    }

    @Test("接口错误：状态码、错误码、退避秒数都带过来")
    func apiErrors() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/runs/\(F.runID)": R(404, json: #"{"code":"not_found","message":"no such run"}"#),
            "GET /v1/agents": R(429, json: #"{"code":"rate_limited","message":"slow down","retry_after_secs":30}"#),
            "GET /v1/approvals": R(403, json: #"{"code":"account_frozen","message":"frozen"}"#),
            "GET /v1/vendors": R(426, json: "upgrade, please"),
            "GET /v1/credentials": R(200, json: #"{"credentials":"not a list"}"#),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        await #expect(
            throws: ThinktinKit.ClientError.api(
                status: 404, code: .notFound, message: "no such run", retryAfterSecs: nil)
        ) {
            _ = try await client.getRun(RunID(F.runID))
        }
        let limited = await #expect(throws: ThinktinKit.ClientError.self) { _ = try await client.agents() }
        #expect(limited == .api(status: 429, code: .rateLimited, message: "slow down", retryAfterSecs: 30))
        #expect(limited?.recovery == .retryLater(after: 30))
        await #expect(throws: ThinktinKit.ClientError.accountFrozen) { _ = try await client.approvals() }
        await #expect(throws: ThinktinKit.ClientError.upgradeRequired) { _ = try await client.vendors() }
        let decode = await #expect(throws: ThinktinKit.ClientError.self) { _ = try await client.credentials() }
        guard case .decode? = decode else {
            Issue.record("应该是 decode，实际是 \(String(describing: decode))")
            return
        }
        // 这些都不是登录失效：会话还在。
        #expect(client.signedIn())
    }

    @Test("会话被吊销：抛 signedOut，并经 SessionStoring 删掉本地会话")
    func sessionRevoked() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/me": R(401, json: #"{"code":"session_revoked","message":"revoked"}"#)
        ])
        defer { server.stop() }
        let store = InMemorySessionStore(F.session)
        let client = try Self.client(server, sessions: store)
        #expect(client.signedIn())

        await #expect(throws: ThinktinKit.ClientError.signedOut) { _ = try await client.me() }
        #expect(!client.signedIn())
        #expect(store.load() == nil)
    }
}
