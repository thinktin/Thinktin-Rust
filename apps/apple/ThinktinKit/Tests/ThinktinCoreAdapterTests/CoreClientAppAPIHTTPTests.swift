import Foundation
import Testing
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 11.7（App 接口补齐）、10.6（实时活动）、5.5（内容举报）的新方法走通整条链路：CoreClient → 真实的 client-core →
/// 本机的 `StubHTTPServer`。路由照 crates/gateway/src/routes/mod.rs，请求体、响应体照 client-core 的 api.rs 和
/// proto 的 domain.rs（服务端的字段名、RFC 3339 时间）。检查请求的方法、路径、请求体，响应解析成 ThinktinKit 的模型，
/// 以及 ffi.rs 注释里写的本地副作用（注销清会话和缓存、标回未读改缓存）。
@Suite("CoreClient 的 App 接口（经真实核心和本机 HTTP 服务端）")
struct CoreClientAppAPIHTTPTests {
    typealias F = AdapterFixture
    typealias R = StubHTTPServer.Response

    /// 2023-11-14T22:13:20.123Z = `F.createdMs`；22:19:20.500Z = `F.finishedMs`。
    static let created = "2023-11-14T22:13:20.123Z"
    static let finished = "2023-11-14T22:19:20.500Z"

    static func client(
        _ server: StubHTTPServer, sessions: InMemorySessionStore = InMemorySessionStore(AdapterFixture.session),
        cachePath: String? = nil
    ) throws -> CoreClient {
        try CoreClient(
            baseURL: server.baseURL, cachePath: cachePath, deviceName: "测试设备", timeout: 10, sessions: sessions)
    }

    /// 测试用的临时缓存库，`body` 跑完删掉。
    static func withCacheDirectory<T>(_ body: (String) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thinktin-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir.appendingPathComponent("cache.sqlite").path)
    }

    /// 请求体解析成 JSON（不是合法 JSON 时测试失败）。
    static func body(_ request: StubHTTPServer.Request) throws -> JSONValue {
        try #require(JSONValue.parse(request.body), "请求体不是 JSON：\(request.body)")
    }

    /// 收到的请求的“方法 路径”（不含查询串）。
    static func routes(_ server: StubHTTPServer) -> [String] {
        server.requests.map { "\($0.method) \($0.path)" }
    }

    // MARK: 登录设备

    @Test("devices()：GET /v1/devices，当前这台、在线的电脑、推送通道和时间都对")
    func devices() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/devices": R(
                200,
                json: """
                    {"devices":[
                     {"id":"\(F.deviceID)","platform":"ios","name":"小明的 iPhone","push_channel":"apns",
                      "created_at":"\(Self.created)","last_seen_at":"\(Self.finished)","revoked_at":null,
                      "current":true,"online":false},
                     {"id":"\(F.otherDeviceID)","platform":"macos","name":"MacBook","push_channel":null,
                      "created_at":"\(Self.created)","last_seen_at":"\(Self.created)","revoked_at":null,
                      "current":false,"online":true}
                    ]}
                    """)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let devices = try await client.devices()
        try #require(devices.count == 2)
        let phone = devices[0]
        #expect(phone.id == DeviceID(F.deviceID))
        #expect(phone.platform == .ios)
        #expect(phone.name == "小明的 iPhone")
        #expect(phone.pushChannel == .apns)
        #expect(phone.isCurrent)
        #expect(!phone.isOnline)
        #expect(phone.createdAt.unixMilliseconds == F.createdMs)
        #expect(phone.lastSeenAt.unixMilliseconds == F.finishedMs)
        let mac = devices[1]
        #expect(mac.id == DeviceID(F.otherDeviceID))
        #expect(mac.isComputer)
        #expect(mac.pushChannel == nil)
        #expect(!mac.isCurrent)
        #expect(mac.isOnline)

        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/devices")
        #expect(request.headers["authorization"] == "Bearer access-token")
    }

    @Test("revokeDevice：都只发 DELETE；吊销当前这台时 client-core 自己清掉本地会话和缓存（b61abc5），不再另调 logout")
    func revokeDevice() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/instances": R(200, json: #"{"instances":[\#(CoreClientHTTPTests.instanceJSON)]}"#),
            "DELETE /v1/devices/\(F.otherDeviceID)": R(204, json: ""),
            "DELETE /v1/devices/\(F.deviceID)": R(204, json: ""),
        ])
        defer { server.stop() }
        try await Self.withCacheDirectory { cachePath in
            let store = InMemorySessionStore(F.session)
            let client = try Self.client(server, sessions: store, cachePath: cachePath)
            _ = try await client.instances()
            #expect(try client.cachedInstances().count == 1)

            try await client.revokeDevice(DeviceID(F.otherDeviceID))
            #expect(Self.routes(server) == ["GET /v1/instances", "DELETE /v1/devices/\(F.otherDeviceID)"])
            #expect(client.signedIn())
            #expect(store.load() == F.session)
            #expect(try client.cachedInstances().count == 1, "吊销别的设备不动本机的缓存")

            try await client.revokeDevice(DeviceID(F.deviceID))
            #expect(
                Self.routes(server) == [
                    "GET /v1/instances", "DELETE /v1/devices/\(F.otherDeviceID)", "DELETE /v1/devices/\(F.deviceID)",
                ])
            #expect(!client.signedIn())
            #expect(store.load() == nil)
            #expect(try client.cachedInstances().isEmpty, "client-core 退出登录时清掉缓存")
        }
    }

    @Test("sendDeviceMessage、ackDeviceMessages：请求体是种类和内容 JSON、要确认的 id；返回的消息和条数")
    func deviceMessages() async throws {
        let message = """
            {"id":"\(F.messageID)","from_device":"\(F.deviceID)","to_device":"\(F.otherDeviceID)",
             "kind":"approval_decision","body":{"approval_id":"a1","decision":"approve"},
             "created_at":"\(Self.created)","expires_at":"\(Self.finished)"}
            """
        let server = try StubHTTPServer(routes: [
            "POST /v1/devices/\(F.otherDeviceID)/messages": R(200, json: message),
            "GET /v1/devices/current/messages": R(200, json: #"{"messages":[\#(message)]}"#),
            "POST /v1/devices/current/messages/ack": R(200, json: #"{"acknowledged":1}"#),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let sent = try await client.sendDeviceMessage(
            to: DeviceID(F.otherDeviceID), kind: .approvalDecision, body: ["approval_id": "a1", "decision": "approve"])
        #expect(sent.id == DeviceMessageID(F.messageID))
        #expect(sent.fromDeviceID == DeviceID(F.deviceID))
        #expect(sent.toDeviceID == DeviceID(F.otherDeviceID))
        #expect(sent.kind == .approvalDecision)
        #expect(sent.body == ["approval_id": "a1", "decision": "approve"])
        #expect(sent.createdAt.unixMilliseconds == F.createdMs)
        #expect(sent.expiresAt.unixMilliseconds == F.finishedMs)

        let pending = try await client.deviceMessages()
        #expect(pending == [sent])

        #expect(try await client.ackDeviceMessages(ids: [DeviceMessageID(F.messageID)]) == 1)

        try #require(server.requests.count == 3)
        #expect(
            try Self.body(server.requests[0])
                == ["kind": "approval_decision", "body": ["approval_id": "a1", "decision": "approve"]])
        #expect(server.requests[1].method == "GET")
        #expect(try Self.body(server.requests[2]) == ["ids": [.string(F.messageID)]])
    }

    // MARK: 账号

    @Test("sendSelfCode + deleteAccount：请求体是用途和验证码；成功后本地会话和缓存一起清掉")
    func deleteAccount() async throws {
        let instance = """
            {"id":"\(F.instanceID)","agent_id":"claude","agent_version":"2.0.1","harness":"acp","name":"写周报的",
             "state":"running","created_at":"\(Self.created)","last_active_at":"\(Self.finished)"}
            """
        let server = try StubHTTPServer(routes: [
            "GET /v1/instances": R(200, json: #"{"instances":[\#(instance)]}"#),
            "POST /v1/me/code": R(204, json: ""),
            "POST /v1/me/delete": R(204, json: ""),
        ])
        defer { server.stop() }
        try await Self.withCacheDirectory { cachePath in
            let store = InMemorySessionStore(F.session)
            let client = try Self.client(server, sessions: store, cachePath: cachePath)
            _ = try await client.instances()
            #expect(try client.cachedInstances().count == 1)

            try await client.sendSelfCode(purpose: .deleteAccount)
            try await client.deleteAccount(code: "123456")

            #expect(!client.signedIn())
            #expect(store.load() == nil)
            #expect(try client.cachedInstances().isEmpty)
            #expect(
                Self.routes(server) == ["GET /v1/instances", "POST /v1/me/code", "POST /v1/me/delete"])
            #expect(try Self.body(server.requests[1]) == ["purpose": "delete_account"])
            #expect(try Self.body(server.requests[2]) == ["code": "123456"])
        }
    }

    @Test("deleteAccount：验证码不对时抛 invalid，登录状态不动")
    func deleteAccountWrongCode() async throws {
        let server = try StubHTTPServer(routes: [
            "POST /v1/me/delete": R(422, json: #"{"code":"invalid","message":"wrong code"}"#)
        ])
        defer { server.stop() }
        let store = InMemorySessionStore(F.session)
        let client = try Self.client(server, sessions: store)

        await #expect(
            throws: ThinktinKit.ClientError.api(status: 422, code: .invalid, message: "wrong code", retryAfterSecs: nil)
        ) {
            try await client.deleteAccount(code: "000000")
        }
        #expect(client.signedIn())
        #expect(store.load() == F.session)
    }

    // MARK: 计划

    static let planJSON = """
        {"id":"\(F.planID)","instance_id":"\(F.instanceID)","title":"新标题","goal":"每天早上汇总新闻",
         "policy":{"preauthorized_tools":["read"],"approval_timeout_secs":600,"on_approval_timeout":"fail",
                   "budget":{"max_tokens":1000,"max_duration_secs":3600,"max_steps":null},
                   "daily_token_limit":null,"wait_timeout_secs":7200},
         "catch_up":"all","paused":false,"created_by":"user","created_at":"\(created)","revision":4,
         "awaiting_confirmation":false,
         "triggers":[{"id":"\(F.triggerID)","plan_id":"\(F.planID)",
                      "spec":{"kind":"cron","expr":"0 8 * * *","tz":"Asia/Shanghai"},"enabled":true,
                      "next_fire_at":"\(finished)","last_fire_at":null}],
         "steps":[]}
        """

    @Test("updatePlan：PATCH /v1/plans/{id} 只带给了的字段；返回的计划带结构化的策略、补跑方式和触发器")
    func updatePlan() async throws {
        let server = try StubHTTPServer(routes: ["PATCH /v1/plans/\(F.planID)": R(200, json: Self.planJSON)])
        defer { server.stop() }
        let client = try Self.client(server)

        let policy = ThinktinKit.PlanPolicy(
            preauthorizedTools: ["read"], approvalTimeoutSecs: 600, onApprovalTimeout: .fail,
            budget: ThinktinKit.RunBudget(maxTokens: 1000, maxDurationSecs: 3600), waitTimeoutSecs: 7200)
        let plan = try await client.updatePlan(
            PlanID(F.planID), change: ThinktinKit.PlanChange(title: "新标题", policy: policy, catchUp: .all))

        #expect(plan.id == PlanID(F.planID))
        #expect(plan.title == "新标题")
        #expect(plan.revision == 4)
        #expect(plan.policy == policy)
        #expect(plan.catchUp == .all)
        #expect(plan.createdAt.unixMilliseconds == F.createdMs)
        try #require(plan.triggers.count == 1)
        #expect(plan.triggers[0].id == TriggerID(F.triggerID))
        #expect(plan.triggers[0].schedule == .cron(expression: "0 8 * * *", timeZone: "Asia/Shanghai"))
        #expect(plan.triggers[0].nextFireAt?.unixMilliseconds == F.finishedMs)
        #expect(!plan.isPipeline)

        let request = try #require(server.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/v1/plans/\(F.planID)")
        let body = try Self.body(request)
        // 没给的 goal、steps 不发（服务端不改）。
        #expect(body.objectValue.map { Set($0.keys) } == ["title", "policy", "catch_up"])
        #expect(body["title"] == "新标题")
        #expect(body["catch_up"] == "all")
        let sentPolicy = try #require(body["policy"])
        #expect(sentPolicy["preauthorized_tools"] == ["read"])
        #expect(sentPolicy["approval_timeout_secs"]?.intValue == 600)
        #expect(sentPolicy["on_approval_timeout"] == "fail")
        #expect(sentPolicy["budget"]?["max_tokens"]?.intValue == 1000)
        #expect(sentPolicy["budget"]?["max_duration_secs"]?.intValue == 3600)
        #expect(sentPolicy["wait_timeout_secs"]?.intValue == 7200)
        // ThinktinKit 解析服务端 JSON 的结果和发出去的是同一份策略。
        #expect(ThinktinKit.PlanPolicy(json: sentPolicy.compactString()) == policy)
    }

    @Test("updatePlan：steps 给空数组就只发 steps（变回单个 agent 的计划）")
    func updatePlanClearSteps() async throws {
        let server = try StubHTTPServer(routes: ["PATCH /v1/plans/\(F.planID)": R(200, json: Self.planJSON)])
        defer { server.stop() }
        let client = try Self.client(server)

        _ = try await client.updatePlan(PlanID(F.planID), change: ThinktinKit.PlanChange(steps: []))
        #expect(try Self.body(try #require(server.requests.first)) == ["steps": []])
    }

    @Test("addTrigger、deleteTrigger：POST /v1/plans/{id}/triggers 带 spec，DELETE /v1/triggers/{id}")
    func triggers() async throws {
        let server = try StubHTTPServer(routes: [
            "POST /v1/plans/\(F.planID)/triggers": R(
                200,
                json: """
                    {"id":"\(F.triggerID)","plan_id":"\(F.planID)","spec":{"kind":"once","at":"\(Self.finished)"},
                     "enabled":true,"next_fire_at":"\(Self.finished)","last_fire_at":null}
                    """),
            "DELETE /v1/triggers/\(F.triggerID)": R(204, json: ""),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let trigger = try await client.addTrigger(planID: PlanID(F.planID), schedule: .once(F.date(F.finishedMs)))
        #expect(trigger.id == TriggerID(F.triggerID))
        #expect(trigger.schedule == .once(F.date(F.finishedMs)))
        #expect(trigger.isEnabled)
        try await client.deleteTrigger(TriggerID(F.triggerID))

        #expect(
            Self.routes(server) == ["POST /v1/plans/\(F.planID)/triggers", "DELETE /v1/triggers/\(F.triggerID)"])
        let spec = try #require(try Self.body(server.requests[0])["spec"])
        #expect(spec["kind"] == "once")
        #expect(spec["at"]?.stringValue.flatMap { Self.parseDate($0) }?.unixMilliseconds == F.finishedMs)
    }

    /// RFC 3339，带不带毫秒都认。
    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: 团队

    static let teamJSON = """
        {"id":"\(F.teamID)","name":"发版小组",
         "members":[{"instance_id":"\(F.instanceID)","role":"lead","position":0},
                    {"instance_id":"\(F.otherInstanceID)","role":"member","position":1}],
         "created_at":"\(created)"}
        """

    @Test("teams()：GET /v1/teams，成员的角色和顺序、时间都对")
    func teams() async throws {
        let server = try StubHTTPServer(routes: ["GET /v1/teams": R(200, json: #"{"teams":[\#(Self.teamJSON)]}"#)])
        defer { server.stop() }
        let client = try Self.client(server)

        let teams = try await client.teams()
        try #require(teams.count == 1)
        let team = teams[0]
        #expect(team.id == TeamID(F.teamID))
        #expect(team.name == "发版小组")
        #expect(team.createdAt.unixMilliseconds == F.createdMs)
        #expect(
            team.members == [
                ThinktinKit.TeamMember(instanceID: InstanceID(F.instanceID), role: .lead, position: 0),
                ThinktinKit.TeamMember(instanceID: InstanceID(F.otherInstanceID), role: .member, position: 1),
            ])
        #expect(team.lead?.instanceID == InstanceID(F.instanceID))

        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/teams")
    }

    @Test("createTeam：POST /v1/teams 带名字和成员（服务端的字段名）")
    func createTeam() async throws {
        let server = try StubHTTPServer(routes: ["POST /v1/teams": R(200, json: Self.teamJSON)])
        defer { server.stop() }
        let client = try Self.client(server)

        let members = ThinktinKit.Team.members([InstanceID(F.instanceID), InstanceID(F.otherInstanceID)])
        let team = try await client.createTeam(name: "发版小组", members: members)
        #expect(team.members == members)

        let body = try Self.body(try #require(server.requests.first))
        #expect(
            body == [
                "name": "发版小组",
                "members": [
                    ["instance_id": .string(F.instanceID), "role": "lead", "position": 0],
                    ["instance_id": .string(F.otherInstanceID), "role": "member", "position": 1],
                ],
            ])
    }

    // MARK: 收件箱

    static func inboxItemJSON(_ id: String, read: Bool) -> String {
        """
        {"id":"\(id)","instance_id":null,"run_id":null,"plan_id":null,"approval_id":null,"kind":"info",
         "title":"t","body":"b","ai_generated":false,"read":\(read),"created_at":"\(created)"}
        """
    }

    @Test("markInboxUnread（没有缓存）：POST /v1/inbox/{id}/unread，再问服务端未读数")
    func markInboxUnreadWithoutCache() async throws {
        let server = try StubHTTPServer(routes: [
            "POST /v1/inbox/\(F.itemID)/unread": R(204, json: ""),
            "GET /v1/inbox": R(200, json: #"{"items":[],"unread":5}"#),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        #expect(try await client.markInboxUnread(InboxItemID(F.itemID)) == 5)
        #expect(Self.routes(server) == ["POST /v1/inbox/\(F.itemID)/unread", "GET /v1/inbox"])
        #expect(server.requests[1].query["unread"] == "true")
        #expect(server.requests[1].query["limit"] == "1")
    }

    @Test("markInboxUnread、deleteInboxItem（有缓存）：未读数取缓存里的，删掉的从缓存里去掉")
    func inboxWithCache() async throws {
        let otherItemID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a11"
        let server = try StubHTTPServer(routes: [
            "GET /v1/inbox": R(
                200,
                json: """
                    {"items":[\(Self.inboxItemJSON(F.itemID, read: true)),\(Self.inboxItemJSON(otherItemID, read: false))],
                     "unread":1}
                    """),
            "POST /v1/inbox/\(F.itemID)/unread": R(204, json: ""),
            "DELETE /v1/inbox/\(otherItemID)": R(204, json: ""),
        ])
        defer { server.stop() }
        try await Self.withCacheDirectory { cachePath in
            let client = try Self.client(server, cachePath: cachePath)
            #expect(try await client.syncInbox(limit: 20).unread == 1)

            #expect(try await client.markInboxUnread(InboxItemID(F.itemID)) == 2)
            #expect(try client.cachedUnread() == 2)
            #expect(try client.cachedInbox(before: nil, limit: 20).allSatisfy { !$0.isRead })

            try await client.deleteInboxItem(InboxItemID(otherItemID))
            #expect(try client.cachedInbox(before: nil, limit: 20).map(\.id) == [InboxItemID(F.itemID)])
            #expect(try client.cachedUnread() == 1)

            // 有缓存时不再问服务端未读数：只有同步时的那一次 GET。
            #expect(
                Self.routes(server) == [
                    "GET /v1/inbox", "POST /v1/inbox/\(F.itemID)/unread", "DELETE /v1/inbox/\(otherItemID)",
                ])
        }
    }

    // MARK: 实时活动（10.6）

    /// 32 字节的令牌（ActivityKit 给的是 `Data`）和它的小写十六进制。
    static let tokenBytes = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 7 + 0xA0) })
    static var tokenHex: String { tokenBytes.map { String(format: "%02x", $0) }.joined() }

    @Test("registerLiveActivity：PUT /v1/runs/{id}/live-activity 带十六进制令牌；同一个令牌再登记照样发（服务端不重发）")
    func registerLiveActivity() async throws {
        let server = try StubHTTPServer(routes: [
            "PUT /v1/runs/\(F.runID)/live-activity": R(204, json: ""),
            "DELETE /v1/runs/\(F.runID)/live-activity": R(204, json: ""),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        try await client.registerLiveActivity(runID: RunID(F.runID), token: Self.tokenBytes)
        try await client.registerLiveActivity(runID: RunID(F.runID), token: Self.tokenHex)
        try await client.endLiveActivity(runID: RunID(F.runID))

        #expect(
            Self.routes(server) == [
                "PUT /v1/runs/\(F.runID)/live-activity", "PUT /v1/runs/\(F.runID)/live-activity",
                "DELETE /v1/runs/\(F.runID)/live-activity",
            ])
        #expect(Self.tokenHex.count == 64)
        #expect(LiveActivityToken.isValid(Self.tokenHex))
        #expect(try Self.body(server.requests[0]) == ["token": .string(Self.tokenHex)])
        #expect(try Self.body(server.requests[1]) == ["token": .string(Self.tokenHex)])
        #expect(server.requests[2].body.isEmpty)
    }

    @Test("registerLiveActivity：运行结束 10 分钟以上的返回 422，抛 invalid（App 在本地结束实时活动）")
    func registerLiveActivityTooLate() async throws {
        let server = try StubHTTPServer(routes: [
            "PUT /v1/runs/\(F.runID)/live-activity": R(
                422, json: #"{"code":"invalid","message":"the run finished more than 10 minutes ago"}"#)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let error = await #expect(throws: ThinktinKit.ClientError.self) {
            try await client.registerLiveActivity(runID: RunID(F.runID), token: Self.tokenHex)
        }
        #expect(
            error
                == .api(
                    status: 422, code: .invalid, message: "the run finished more than 10 minutes ago",
                    retryAfterSecs: nil))
        #expect(error?.isInvalidInput == true)
        #expect(error?.isRetryable == false)
        #expect(client.signedIn())
    }

    @Test("setLiveActivityStartToken：给令牌 PUT，传 nil DELETE（/v1/devices/current/live-activity-start）")
    func liveActivityStartToken() async throws {
        let path = "/v1/devices/current/live-activity-start"
        let server = try StubHTTPServer(routes: ["PUT \(path)": R(204, json: ""), "DELETE \(path)": R(204, json: "")])
        defer { server.stop() }
        let client = try Self.client(server)

        try await client.setLiveActivityStartToken(Self.tokenBytes)
        try await client.setLiveActivityStartToken(nil)

        #expect(Self.routes(server) == ["PUT \(path)", "DELETE \(path)"])
        #expect(try Self.body(server.requests[0]) == ["token": .string(Self.tokenHex)])
    }

    // MARK: 内容举报（5.5）

    @Test("reportContent：POST /v1/reports 带运行、事件序号、原因、说明；返回待处理的举报")
    func reportContent() async throws {
        let server = try StubHTTPServer(routes: [
            "POST /v1/reports": R(
                200,
                json: """
                    {"id":"\(F.reportID)","run_id":"\(F.runID)","instance_id":"\(F.instanceID)","event_seq":42,
                     "artifact_id":null,"reason":"misinformation","note":"数据是编的","state":"open",
                     "resolution":null,"created_at":"\(Self.created)","handled_at":null}
                    """)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let report = try await client.reportContent(
            runID: RunID(F.runID), eventSeq: 42, artifactID: nil, reason: .misinformation, note: "数据是编的")
        #expect(report.id == ContentReportID(F.reportID))
        #expect(report.runID == RunID(F.runID))
        #expect(report.instanceID == InstanceID(F.instanceID))
        #expect(report.target == .event(seq: 42))
        #expect(report.reason == .misinformation)
        #expect(report.note == "数据是编的")
        #expect(report.isOpen)
        #expect(report.resolution == nil)
        #expect(report.createdAt.unixMilliseconds == F.createdMs)
        #expect(report.handledAt == nil)

        // 举报整个运行：事件序号、产出物、说明都是 null。
        _ = try await client.reportRun(RunID(F.runID), reason: .harmful)

        try #require(server.requests.count == 2)
        #expect(server.requests[0].method == "POST")
        #expect(server.requests[0].path == "/v1/reports")
        #expect(
            try Self.body(server.requests[0])
                == [
                    "run_id": .string(F.runID), "event_seq": 42, "artifact_id": nil, "reason": "misinformation",
                    "note": "数据是编的",
                ])
        #expect(
            try Self.body(server.requests[1])
                == ["run_id": .string(F.runID), "event_seq": nil, "artifact_id": nil, "reason": "harmful", "note": nil])
    }

    @Test("reports()：GET /v1/reports，处理完的带结果和时间；超过每小时 30 次抛 rate_limited")
    func reports() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/reports": R(
                200,
                json: """
                    {"reports":[{"id":"\(F.reportID)","run_id":"\(F.runID)","instance_id":"\(F.instanceID)",
                     "event_seq":null,"artifact_id":"\(F.artifactID)","reason":"infringement","note":null,
                     "state":"closed","resolution":"已下架","created_at":"\(Self.created)",
                     "handled_at":"\(Self.finished)"}]}
                    """),
            "POST /v1/reports": R(
                429, json: #"{"code":"rate_limited","message":"too many reports","retry_after_secs":1800}"#),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let reports = try await client.reports()
        try #require(reports.count == 1)
        #expect(reports[0].target == .artifact(ArtifactID(F.artifactID)))
        #expect(reports[0].reason == .infringement)
        #expect(reports[0].state == .closed)
        #expect(reports[0].resolution == "已下架")
        #expect(reports[0].handledAt?.unixMilliseconds == F.finishedMs)

        let limited = await #expect(throws: ThinktinKit.ClientError.self) {
            _ = try await client.reportRun(RunID(F.runID), reason: .other)
        }
        #expect(limited?.isRateLimited == true)
        #expect(limited?.recovery == .retryLater(after: 1800))
    }

    // MARK: client-core 先校验的参数（不发请求）

    @Test("不认识的举报原因、补跑方式、团队角色，不是 JSON 的设备消息：抛 invalidArgument，不发请求")
    func clientSideValidation() async throws {
        let server = try StubHTTPServer(routes: [:])
        defer { server.stop() }
        let client = try Self.client(server)

        func expectInvalidArgument(_ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation)
            async
        {
            do {
                try await body()
                Issue.record("应该抛 invalidArgument", sourceLocation: sourceLocation)
            } catch ThinktinKit.ClientError.invalidArgument {
                // 预期的：client-core 在发请求前就拒绝了。
            } catch {
                Issue.record("应该是 invalidArgument，实际是 \(error)", sourceLocation: sourceLocation)
            }
        }

        await expectInvalidArgument {
            _ = try await client.reportContent(
                runID: RunID(F.runID), eventSeq: nil, artifactID: nil, reason: .unknown("spam"), note: nil)
        }
        await expectInvalidArgument {
            _ = try await client.reportContent(
                runID: RunID(F.runID), eventSeq: nil, artifactID: "not-a-uuid", reason: .other, note: nil)
        }
        await expectInvalidArgument {
            _ = try await client.updatePlan(
                PlanID(F.planID), change: ThinktinKit.PlanChange(catchUp: .unknown("weekly")))
        }
        await expectInvalidArgument {
            let policy = ThinktinKit.PlanPolicy(onApprovalTimeout: .unknown("escalate"))
            _ = try await client.updatePlan(PlanID(F.planID), change: ThinktinKit.PlanChange(policy: policy))
        }
        await expectInvalidArgument {
            _ = try await client.createTeam(
                name: "x",
                members: [ThinktinKit.TeamMember(instanceID: InstanceID(F.instanceID), role: .unknown("boss"))])
        }
        await expectInvalidArgument {
            _ = try await client.sendDeviceMessage(to: DeviceID(F.otherDeviceID), kind: .capability, bodyJSON: "{oops")
        }
        await expectInvalidArgument {
            _ = try await client.ackDeviceMessages(ids: ["not-a-uuid"])
        }
        await expectInvalidArgument { try await client.revokeDevice("not-a-uuid") }
        await expectInvalidArgument { try await client.registerLiveActivity(runID: "not-a-uuid", token: Self.tokenHex) }
        #expect(server.requests.isEmpty)
        #expect(client.signedIn())
    }
}
