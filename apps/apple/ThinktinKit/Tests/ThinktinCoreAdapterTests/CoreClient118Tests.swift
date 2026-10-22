import Foundation
import Testing
import ThinktinCore
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 11.8（client-core 补漏）接进适配层：新字段的转换、跨实例的运行列表、缓存往前翻、`Accept-Language`、版本太老、
/// 日志。请求经真实的 client-core 发到本机的 `StubHTTPServer`；路由照 crates/gateway/src/routes/mod.rs，
/// 查询参数照 crates/gateway/src/routes/runs.rs 的 `ListAllQuery`，字段名照 client-core 的 api.rs 和 proto 的 domain.rs。
@Suite("11.8：转换、跨实例运行、Accept-Language、版本太老、日志（经真实核心）")
struct CoreClient118Tests {
    typealias F = AdapterFixture
    typealias R = StubHTTPServer.Response
    typealias H = CoreClientAppAPIHTTPTests

    static let created = H.created
    static let finished = H.finished

    static func client(
        _ server: StubHTTPServer, acceptLanguage: String? = "zh-Hans-CN, en;q=0.9",
        sessions: InMemorySessionStore = InMemorySessionStore(AdapterFixture.session), cachePath: String? = nil
    ) throws -> CoreClient {
        try CoreClient(
            baseURL: server.baseURL, cachePath: cachePath, deviceName: "测试设备", timeout: 10,
            acceptLanguage: acceptLanguage, sessions: sessions)
    }

    /// 服务端 JSON 里的一个运行。
    static func runJSON(
        id: String, instanceID: String, state: String = "running", planID: String? = nil, parentID: String? = nil,
        waitCode: String? = nil
    ) -> String {
        let plan = planID.map { "\"\($0)\"" } ?? "null"
        let parent = parentID.map { "\"\($0)\"" } ?? "null"
        let wait = waitCode.map { #","wait_code":"\#($0)""# } ?? ""
        return """
            {"id":"\(id)","kind":"agent","instance_id":"\(instanceID)","plan_id":\(plan),"parent_run_id":\(parent),
             "root_run_id":"\(parentID ?? id)","step_key":null,"source":"plan","prompt":"整理周报","state":"\(state)",
             "state_reason":null,"attempt":1,"tokens_used":12,"summary":null,"error":null,
             "created_at":"\(created)","started_at":"\(created)","finished_at":null\(wait)}
            """
    }

    // MARK: 转换

    @Test("Run.waitCode：认识的、不认识的（原样保留）、没有")
    func runWaitCodeConversion() {
        func run(_ code: String?) -> ThinktinKit.Run {
            ThinktinKit.Run(
                core: ThinktinCore.Run(
                    id: F.runID, kind: "agent", instanceId: F.instanceID, planId: nil, parentRunId: nil,
                    rootRunId: F.runID, stepKey: nil, source: "user", prompt: "p", state: "waiting_quota",
                    stateReason: "欠费", attempt: 1, tokensUsed: 0, summary: nil, error: nil, createdAtMs: F.createdMs,
                    startedAtMs: nil, finishedAtMs: nil, waitCode: code))
        }
        #expect(run("no_balance").waitCode == .noBalance)
        #expect(run("rate_limited").waitCode == .rateLimited)
        #expect(run("device_offline").waitCode == .deviceOffline)
        #expect(run("solar_flare").waitCode == .unknown("solar_flare"))
        #expect(run(nil).waitCode == nil)
        #expect(run("invalid").state == .waitingQuota)
    }

    @Test("AgentInfo：介绍、上游、许可说明、协议（含不认识的）、运行时用的协议；老的默认值")
    func agentInfoConversion() {
        let agent = ThinktinKit.AgentInfo(
            core: ThinktinCore.AgentInfo(
                id: "hermes", name: "Hermes Agent", version: "0.19.0", license: "MIT", sites: ["cn"],
                harnesses: ["acp"], defaultHarness: "acp", versions: ["0.19.0"], description: "通用 agent",
                upstream: "https://github.com/NousResearch/hermes-agent", licenseNote: "说明",
                protocols: ["chat", "anthropic", "gemini"], activeProtocol: "chat"))
        #expect(agent.id == AgentID("hermes"))
        #expect(agent.description == "通用 agent")
        #expect(agent.upstream == "https://github.com/NousResearch/hermes-agent")
        #expect(agent.upstreamURL?.host == "github.com")
        #expect(agent.licenseNote == "说明")
        #expect(agent.protocols == [.chat, .anthropic, .unknown("gemini")])
        #expect(agent.activeProtocol == .chat)

        // UniFFI 的默认值（老的服务端没给这些字段）。
        let old = ThinktinKit.AgentInfo(
            core: ThinktinCore.AgentInfo(
                id: "pi", name: "Pi", version: "1", license: nil, sites: [], harnesses: ["acp"], defaultHarness: "acp",
                versions: []))
        #expect(old.description.isEmpty)
        #expect(old.upstream.isEmpty)
        #expect(old.licenseNote == nil)
        #expect(old.protocols.isEmpty)
        #expect(old.activeProtocol == nil)
    }

    @Test("Credential.protocols；RunFilter 反向转换")
    func credentialAndFilterConversion() {
        let credential = ThinktinKit.Credential(
            core: ThinktinCore.Credential(
                id: F.itemID, vendor: "custom", label: "自建", last4: "abcd", dailyTokenLimit: nil, disabled: false,
                createdAtMs: F.createdMs, protocols: ["anthropic", "responses"]))
        #expect(credential.protocols == [.anthropic, .responses])
        #expect(!credential.supports(.chat))

        let all = ThinktinKit.RunFilter.all.core
        #expect(all.planId == nil && !all.activeOnly && !all.rootsOnly)
        let plan = ThinktinKit.RunFilter(planID: PlanID(F.planID), activeOnly: true, rootsOnly: true).core
        #expect(plan.planId == F.planID)
        #expect(plan.activeOnly)
        #expect(plan.rootsOnly)
    }

    @Test("Accept-Language：ThinktinKit 的 AcceptLanguage.header 和 client-core 的 accept_language_header 逐条一致")
    func acceptLanguageMatchesCore() {
        let cases: [[String]] = [
            ["zh-Hans-CN", "en-US", "en"],
            [" en_US ", "", "中文", "x y", "zh;q=1", "ja"],
            [],
            [String(repeating: "a", count: 35), String(repeating: "b", count: 36), "fr"],
            (0..<12).map { "l\($0)" },
            ["\tde-DE\n", "pt_BR", "zh-Hant-TW"],
        ]
        for tags in cases {
            #expect(AcceptLanguage.header(tags: tags) == (CoreClient.acceptLanguageHeader(tags: tags) ?? ""), "\(tags)")
        }
        #expect(CoreClient.acceptLanguageHeader(tags: ["中文"]) == nil)
        #expect(CoreClient.systemAcceptLanguage == AcceptLanguage.system)
    }

    // MARK: 跨实例的运行列表

    /// `{"runs":[…]}`。
    static func runsBody(_ runs: String...) -> String {
        #"{"runs":["# + runs.joined(separator: ",") + "]}"
    }

    @Test("listRuns：GET /v1/runs，limit 总是带，条件给了才带（plan_id、active=true、roots=true、before）")
    func listRunsQuery() async throws {
        let body = Self.runsBody(
            Self.runJSON(
                id: F.runID, instanceID: F.instanceID, state: "waiting_quota", planID: F.planID, waitCode: "no_balance"),
            Self.runJSON(id: F.rootRunID, instanceID: F.otherInstanceID, state: "queued"))
        let server = try StubHTTPServer(routes: ["GET /v1/runs": R(200, json: body)])
        defer { server.stop() }
        let client = try Self.client(server)

        let runs = try await client.listRuns(filter: .all, before: nil, limit: 50)
        try #require(runs.count == 2)
        #expect(runs[0].id == RunID(F.runID))
        #expect(runs[0].instanceID == InstanceID(F.instanceID))
        #expect(runs[0].planID == PlanID(F.planID))
        #expect(runs[0].state == .waitingQuota)
        #expect(runs[0].waitCode == .noBalance)
        #expect(runs[0].createdAt.unixMilliseconds == F.createdMs)
        #expect(runs[1].instanceID == InstanceID(F.otherInstanceID))
        #expect(runs[1].waitCode == nil)

        _ = try await client.listRuns(filter: .active, limit: 20)
        _ = try await client.listRuns(filter: .plan(PlanID(F.planID)), before: RunID(F.rootRunID), limit: 10)
        _ = try await client.listRuns(
            filter: ThinktinKit.RunFilter(planID: PlanID(F.planID), activeOnly: true), limit: -1)

        #expect(H.routes(server) == Array(repeating: "GET /v1/runs", count: 4))
        let queries = server.requests.map(\.query)
        #expect(queries[0] == ["limit": "50"])
        #expect(queries[1] == ["limit": "20", "active": "true"])
        #expect(queries[2] == ["limit": "10", "plan_id": F.planID, "roots": "true", "before": F.rootRunID])
        // 负数当 0，服务端再夹到 1。
        #expect(queries[3] == ["limit": "0", "plan_id": F.planID, "active": "true"])
        #expect(server.requests[0].headers["authorization"] == "Bearer access-token")
    }

    @Test("listRuns：顺便更新缓存，每个实例的 cachedRuns 跟着新")
    func listRunsUpdatesCache() async throws {
        let body = Self.runsBody(
            Self.runJSON(id: F.runID, instanceID: F.instanceID),
            Self.runJSON(id: F.rootRunID, instanceID: F.otherInstanceID, state: "backoff"))
        let server = try StubHTTPServer(routes: ["GET /v1/runs": R(200, json: body)])
        defer { server.stop() }
        try await H.withCacheDirectory { path in
            let client = try Self.client(server, cachePath: path)
            #expect(try client.cachedRuns(instanceID: InstanceID(F.instanceID), limit: 10).isEmpty)
            let runs = try await client.listRuns(filter: .active, limit: 50)
            #expect(try client.cachedRuns(instanceID: InstanceID(F.instanceID), limit: 10) == [runs[0]])
            #expect(try client.cachedRuns(instanceID: InstanceID(F.otherInstanceID), limit: 10) == [runs[1]])
        }
    }

    @Test("listRuns：计划 id、游标不是 UUID 时不发请求，抛 invalidArgument；空列表照常")
    func listRunsBadIDs() async throws {
        let server = try StubHTTPServer(routes: ["GET /v1/runs": R(200, json: #"{"runs":[]}"#)])
        defer { server.stop() }
        let client = try Self.client(server)

        for call in [
            { _ = try await client.listRuns(filter: .plan("not-a-plan"), limit: 10) },
            { _ = try await client.listRuns(filter: .all, before: "not-a-run", limit: 10) },
        ] as [@Sendable () async throws -> Void] {
            let error = await #expect(throws: ThinktinKit.ClientError.self) { try await call() }
            guard case .invalidArgument? = error else {
                Issue.record("应该是 invalidArgument，实际是 \(String(describing: error))")
                continue
            }
        }
        #expect(server.requests.isEmpty)
        #expect(try await client.listRuns(filter: .plan(PlanID(F.planID)), limit: 10).isEmpty)
    }

    // MARK: 缓存往前翻

    @Test("cachedEventsBefore：没缓存、没登录、缓存里没有时返回空；实例 id 不对抛 invalidArgument")
    func cachedEventsBefore() async throws {
        let instance = InstanceID(F.instanceID)
        let noCache = try F.client(sessions: InMemorySessionStore(F.session))
        #expect(try noCache.cachedEventsBefore(instanceID: instance, beforeSeq: nil, limit: 50).isEmpty)
        #expect(try noCache.latestCachedEvents(instanceID: instance, limit: 50).isEmpty)
        let error = #expect(throws: ThinktinKit.ClientError.self) {
            _ = try noCache.cachedEventsBefore(instanceID: "bad id", beforeSeq: 10, limit: 50)
        }
        guard case .invalidArgument? = error else {
            Issue.record("应该是 invalidArgument，实际是 \(String(describing: error))")
            return
        }

        try await H.withCacheDirectory { path in
            let signedIn = try F.client(sessions: InMemorySessionStore(F.session), cachePath: path)
            #expect(try signedIn.cachedEventsBefore(instanceID: instance, beforeSeq: 100, limit: 50).isEmpty)
            let signedOut = try F.client(cachePath: path)
            #expect(try signedOut.cachedEventsBefore(instanceID: instance, beforeSeq: nil, limit: 50).isEmpty)
        }
    }

    // MARK: Accept-Language

    @Test("Accept-Language：建客户端时给的每个请求都带；setAcceptLanguage 换掉、清掉；不合法的抛 invalidArgument、原来的不变")
    func acceptLanguageHeader() async throws {
        let server = try StubHTTPServer(routes: ["GET /v1/vendors": R(200, json: #"{"vendors":[]}"#)])
        defer { server.stop() }
        let client = try Self.client(server, acceptLanguage: "zh-Hans-CN, en;q=0.9")

        _ = try await client.vendors()
        try client.setAcceptLanguage(" en-US ")
        _ = try await client.vendors()
        let error = #expect(throws: ThinktinKit.ClientError.self) { try client.setAcceptLanguage("en\r\nX-Evil: 1") }
        guard case .invalidArgument? = error else {
            Issue.record("应该是 invalidArgument，实际是 \(String(describing: error))")
            return
        }
        #expect(throws: ThinktinKit.ClientError.self) {
            try client.setAcceptLanguage(String(repeating: "a", count: AcceptLanguage.maxLength + 1))
        }
        _ = try await client.vendors()
        try client.setAcceptLanguage(nil)
        _ = try await client.vendors()
        try client.setAcceptLanguage("   ")
        _ = try await client.vendors()

        let languages = server.requests.map { $0.headers["accept-language"] }
        #expect(languages == ["zh-Hans-CN, en;q=0.9", "en-US", "en-US", nil, nil])
    }

    @Test("Accept-Language：默认是系统的语言偏好；给 nil 不带；不合法的值建客户端时就抛 invalidArgument")
    func acceptLanguageAtInit() async throws {
        let server = try StubHTTPServer(routes: ["GET /v1/vendors": R(200, json: #"{"vendors":[]}"#)])
        defer { server.stop() }
        let byDefault = try CoreClient(
            baseURL: server.baseURL, deviceName: "测试设备", sessions: InMemorySessionStore(F.session))
        _ = try await byDefault.vendors()
        let none = try Self.client(server, acceptLanguage: nil)
        _ = try await none.vendors()
        #expect(server.requests.map { $0.headers["accept-language"] } == [CoreClient.systemAcceptLanguage, nil])

        let error = #expect(throws: ThinktinKit.ClientError.self) {
            _ = try Self.client(server, acceptLanguage: "zh\nX: y")
        }
        guard case .invalidArgument? = error else {
            Issue.record("应该是 invalidArgument，实际是 \(String(describing: error))")
            return
        }
    }

    @Test("agents()：介绍、上游、许可说明、协议经接口转过来；请求带着设备语言")
    func agentsOverHTTP() async throws {
        let agents = """
            {"agents":[{"id":"codex","name":"Codex","version":"2.2.2","license":"Apache-2.0","sites":["cn","global"],
             "harnesses":["acp"],"default_harness":"acp","versions":["2.2.2"],
             "description":"Coding agent using OpenAI Codex.","upstream":"https://github.com/agentclientprotocol/codex-acp",
             "protocols":["responses"],"active_protocol":"responses"},
             {"id":"pi","name":"Pi","version":"0.1.0","harnesses":["acp"],"default_harness":"acp"}]}
            """
        let credentials = """
            {"credentials":[{"id":"\(F.itemID)","vendor":"anthropic","label":"主力","last4":"abcd",
             "daily_token_limit":null,"disabled":false,"created_at":"\(Self.created)","protocols":["anthropic","chat"]}]}
            """
        let server = try StubHTTPServer(routes: [
            "GET /v1/agents": R(200, json: agents), "GET /v1/credentials": R(200, json: credentials),
        ])
        defer { server.stop() }
        let client = try Self.client(server, acceptLanguage: "en-US, zh-CN;q=0.9")

        let list = try await client.agents()
        try #require(list.count == 2)
        let codex = list[0]
        #expect(codex.description == "Coding agent using OpenAI Codex.")
        #expect(codex.upstreamURL?.absoluteString == "https://github.com/agentclientprotocol/codex-acp")
        #expect(codex.licenseNote == nil)
        #expect(codex.protocols == [.responses])
        #expect(codex.activeProtocol == .responses)
        // 老的服务端没给的字段：默认值。
        #expect(list[1].description.isEmpty)
        #expect(list[1].activeProtocol == nil)

        let keys = try await client.credentials()
        let key = try #require(keys.first)
        #expect(key.protocols == [.anthropic, .chat])
        #expect(!codex.canUse(key))
        #expect(list[1].canUse(key))

        #expect(server.requests.allSatisfy { $0.headers["accept-language"] == "en-US, zh-CN;q=0.9" })
    }

    // MARK: 版本太老

    @Test("upgradeRequired：任何请求收到 426 后一直是 true；之后订阅直接 stopped、不连", .timeLimit(.minutes(1)))
    func upgradeRequiredAfterREST() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/vendors": R(426, json: #"{"code":"upgrade_required","message":"too old"}"#),
            "GET /v1/agents": R(200, json: #"{"agents":[]}"#),
        ])
        defer { server.stop() }
        let client = try Self.client(server)
        #expect(!client.upgradeRequired())
        _ = try await client.agents()
        #expect(!client.upgradeRequired())

        await #expect(throws: ThinktinKit.ClientError.upgradeRequired) { _ = try await client.vendors() }
        #expect(client.upgradeRequired())
        _ = try await client.agents()
        #expect(client.upgradeRequired())

        let stream = try client.events(instanceID: InstanceID(F.instanceID))
        let elements = try await withTimeout(20) {
            var all: [EventStreamElement] = []
            for await element in stream { all.append(element) }
            return all
        }
        #expect(elements == [.status(.stopped)])
        // 事件流没去连（没有握手请求）。
        #expect(!H.routes(server).contains { $0.hasSuffix("/events/ws") })
    }

    @Test("事件流握手收到 426：以 stopped 结束、不重连，upgradeRequired 变成 true；握手也带 Accept-Language", .timeLimit(.minutes(1)))
    func upgradeRequiredOnHandshake() async throws {
        let ws = "/v1/instances/\(F.instanceID)/events/ws"
        let server = try StubHTTPServer(routes: ["GET \(ws)": R(426, json: #"{"code":"upgrade_required"}"#)])
        defer { server.stop() }
        let client = try Self.client(server, acceptLanguage: "en")

        let stream = try client.events(instanceID: InstanceID(F.instanceID))
        let elements = try await withTimeout(20) {
            var all: [EventStreamElement] = []
            for await element in stream { all.append(element) }
            return all
        }
        #expect(elements == [.status(.connecting), .status(.stopped)])
        #expect(client.upgradeRequired())
        #expect(H.routes(server) == ["GET \(ws)"])
        let handshake = try #require(server.requests.first)
        #expect(handshake.headers["accept-language"] == "en")
        #expect(handshake.headers["authorization"] == "Bearer access-token")
    }

    // MARK: 日志

    @Test("日志：级别一一对应；标准错误里的一行；Linux 上写一条不出错")
    func logLevels() {
        for level in CoreLogging.Level.allCases {
            #expect(CoreLogging.Level(core: level.core) == level)
        }
        #expect(CoreLogging.Level.allCases.sorted() == [.error, .warn, .info, .debug, .trace])
        #expect(CoreLogging.Level.error < .trace)
        #expect(
            OSLogSink.line(level: .warn, target: "client_core::events", message: "event stream refused")
                == "[WARN] client_core::events: event stream refused")
        OSLogSink().log(record: LogRecord(level: .trace, target: "client_core::test", message: "只是测试"))
    }

    @Test("CoreLogging.install：装上；同一个级别再调什么都不做；换级别；client-core 的日志真的交出来了", .timeLimit(.minutes(1)))
    func installAndRecords() async throws {
        #expect(CoreLogging.install(maxLevel: .warn))
        #expect(CoreLogging.currentLevel == .warn)
        #expect(CoreLogging.install(maxLevel: .warn))
        #expect(CoreLogging.install(maxLevel: .error))
        #expect(CoreLogging.currentLevel == .error)

        // 临时换成记录用的 sink，看 client-core 的 warn 日志是不是交出来了（模块名、抹过的正文）。
        let recorder = RecordingLogSink()
        let swapped = Core.initLogging(sink: recorder, maxLevel: .warn)
        #expect(swapped)
        defer {
            // 换回系统日志（级别变了，CoreLogging 会重新交给自己的 sink）。
            CoreLogging.install(maxLevel: .info)
        }
        // 接口地址不是 http(s)：事件流每次连之前都打一条 warn（然后退避重连）。
        let client = try CoreClient(
            baseURL: "ftp://127.0.0.1:9", deviceName: "测试设备", timeout: 5, acceptLanguage: nil,
            sessions: InMemorySessionStore(F.session))
        let handle = try client.subscribe(
            instanceID: InstanceID(F.instanceID), afterSeq: nil, listener: RecordingListener())
        defer { handle.stop() }
        let record = try await withTimeout(20) {
            while true {
                if let r = recorder.records.first(where: { $0.message.contains("bad base url") }) { return r }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        #expect(record.level == .warn)
        #expect(record.target == "client_core::events")
        #expect(record.message.contains("unsupported scheme"))
    }
}

/// 记下 client-core 交出来的日志（测试用的 `LogSink`）。
final class RecordingLogSink: ThinktinCore.LogSink {
    private let received = Locked<[LogRecord]>([])

    var records: [LogRecord] { received.value }

    func log(record: LogRecord) {
        received.withLock { $0.append(record) }
    }
}
