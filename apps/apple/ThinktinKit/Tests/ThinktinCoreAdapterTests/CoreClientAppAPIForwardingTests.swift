import Foundation
import Testing
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 11.7 里“一行转发”的方法（CoreClientAppAPIHTTPTests 没覆盖到的）也经真实的 client-core 和本机 `StubHTTPServer`
/// 走一遍：参数有没有放对位置（id 进路径、`limit` / `before` 进查询串、可选值不给时不发或发 null）、
/// 返回的 JSON 能不能转成 ThinktinKit 的模型。路由照 crates/gateway/src/routes/mod.rs，字段名照 proto 的 domain.rs。
@Suite("CoreClient 的 App 接口：转发的方法（经真实核心和本机 HTTP 服务端）")
struct CoreClientAppAPIForwardingTests {
    typealias F = AdapterFixture
    typealias R = StubHTTPServer.Response
    typealias H = CoreClientAppAPIHTTPTests

    static let created = H.created
    static let finished = H.finished
    static let credentialID = "0199f1e2-3c4d-7e8f-9a0b-1c2d3e4f5a12"

    static func client(_ server: StubHTTPServer, sessions: InMemorySessionStore = InMemorySessionStore(F.session))
        throws -> CoreClient
    {
        try H.client(server, sessions: sessions)
    }

    // MARK: 账号

    static let userJSON = """
        {"id":"\(F.userID)","phone":"+8613800138000","display_name":"小明","status":"active","locale":"zh-CN",
         "created_at":"\(created)"}
        """

    @Test("updateProfile：PATCH /v1/me 带 display_name；传 nil 发 null（服务端清掉昵称）")
    func updateProfile() async throws {
        let server = try StubHTTPServer(routes: ["PATCH /v1/me": R(200, json: Self.userJSON)])
        defer { server.stop() }
        let client = try Self.client(server)

        let user = try await client.updateProfile(displayName: "小明")
        #expect(user.id == UserID(F.userID))
        #expect(user.displayName == "小明")
        #expect(user.locale == .zhCN)
        #expect(user.createdAt.unixMilliseconds == F.createdMs)
        _ = try await client.updateProfile(displayName: nil)

        #expect(H.routes(server) == ["PATCH /v1/me", "PATCH /v1/me"])
        #expect(try H.body(server.requests[0]) == ["display_name": "小明"])
        // 带了 null（不是不带）：服务端区分“不改”和“清掉”。
        #expect(try H.body(server.requests[1]) == ["display_name": nil])
    }

    // MARK: 模型 key

    static let credentialJSON = """
        {"id":"\(credentialID)","vendor":"deepseek","label":"备用","last4":"wxyz","daily_token_limit":200000,
         "disabled":true,"created_at":"\(created)"}
        """

    @Test("updateCredential：PATCH /v1/credentials/{id} 只带给了的字段（label、disabled 不会对调）")
    func updateCredential() async throws {
        let server = try StubHTTPServer(routes: [
            "PATCH /v1/credentials/\(Self.credentialID)": R(200, json: Self.credentialJSON)
        ])
        defer { server.stop() }
        let client = try Self.client(server)
        let id = CredentialID(Self.credentialID)

        let credential = try await client.updateCredential(id, label: "备用", disabled: nil)
        #expect(credential.id == id)
        #expect(credential.label == "备用")
        #expect(credential.isDisabled)
        #expect(credential.dailyTokenLimit == 200_000)
        #expect(credential.maskedKey == "••••wxyz")
        _ = try await client.updateCredential(id, label: nil, disabled: true)
        // 备注可以改成空的（和 nil 不一样：nil 不改）。
        _ = try await client.updateCredential(id, label: "", disabled: false)

        try #require(server.requests.count == 3)
        #expect(try H.body(server.requests[0]) == ["label": "备用"])
        #expect(try H.body(server.requests[1]) == ["disabled": true])
        #expect(try H.body(server.requests[2]) == ["label": "", "disabled": false])
    }

    @Test("replaceCredentialSecret：PUT /v1/credentials/{id}/secret 带 api_key，返回同一条记录")
    func replaceCredentialSecret() async throws {
        let server = try StubHTTPServer(routes: [
            "PUT /v1/credentials/\(Self.credentialID)/secret": R(200, json: Self.credentialJSON)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let credential = try await client.replaceCredentialSecret(
            CredentialID(Self.credentialID), apiKey: "sk-new-key-wxyz")
        #expect(credential.id == CredentialID(Self.credentialID))
        #expect(credential.last4 == "wxyz")
        let request = try #require(server.requests.first)
        #expect(request.method == "PUT")
        #expect(try H.body(request) == ["api_key": "sk-new-key-wxyz"])
    }

    // MARK: 实例、运行、产出物

    static let runJSON = """
        {"id":"\(F.runID)","kind":"agent","instance_id":"\(F.instanceID)","plan_id":null,"parent_run_id":null,
         "root_run_id":"\(F.runID)","step_key":null,"source":"user","prompt":"整理周报","state":"succeeded",
         "state_reason":null,"attempt":1,"tokens_used":1234,"summary":"写好了","error":null,
         "created_at":"\(created)","started_at":"\(created)","finished_at":"\(finished)"}
        """

    @Test("instance：GET /v1/instances/{id}")
    func instance() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/instances/\(F.instanceID)": R(200, json: CoreClientHTTPTests.instanceJSON)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let instance = try await client.instance(InstanceID(F.instanceID))
        #expect(instance.id == InstanceID(F.instanceID))
        #expect(instance.state == .paused)
        #expect(instance.lastActiveAt.unixMilliseconds == F.finishedMs)
    }

    @Test("olderRuns：GET /v1/instances/{id}/runs 带 limit 和 before（往前翻页的游标）")
    func olderRuns() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/instances/\(F.instanceID)/runs": R(200, json: #"{"runs":[\#(Self.runJSON)]}"#)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let runs = try await client.olderRuns(
            instanceID: InstanceID(F.instanceID), before: RunID(F.rootRunID), limit: 20)
        try #require(runs.count == 1)
        #expect(runs[0].id == RunID(F.runID))
        #expect(runs[0].state == .succeeded)
        #expect(runs[0].tokensUsed == 1234)
        #expect(runs[0].finishedAt?.unixMilliseconds == F.finishedMs)

        let request = try #require(server.requests.first)
        #expect(request.query["limit"] == "20")
        #expect(request.query["before"] == F.rootRunID)
    }

    @Test("instanceArtifacts、deleteArtifact：limit 进查询串（负数当 0，服务端再夹到 1…500）；DELETE /v1/artifacts/{id}")
    func instanceArtifacts() async throws {
        let artifact = """
            {"id":"\(F.artifactID)","instance_id":"\(F.instanceID)","run_id":"\(F.runID)","root_run_id":"\(F.runID)",
             "name":"weekly.md","version":2,"content_type":"text/markdown","size":2048,"sha256":"abc123",
             "created_at":"\(Self.created)"}
            """
        let server = try StubHTTPServer(routes: [
            "GET /v1/instances/\(F.instanceID)/artifacts": R(200, json: #"{"artifacts":[\#(artifact)]}"#),
            "DELETE /v1/artifacts/\(F.artifactID)": R(204, json: ""),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let list = try await client.instanceArtifacts(
            InstanceID(F.instanceID), limit: ThinktinKit.Artifact.maxListLimit)
        try #require(list.count == 1)
        #expect(list[0].id == ArtifactID(F.artifactID))
        #expect(list[0].runID == RunID(F.runID))
        #expect(list[0].version == 2)
        #expect(list[0].size == 2048)
        #expect(list[0].isText)
        _ = try await client.instanceArtifacts(InstanceID(F.instanceID), limit: -5)
        try await client.deleteArtifact(ArtifactID(F.artifactID))

        #expect(
            H.routes(server) == [
                "GET /v1/instances/\(F.instanceID)/artifacts", "GET /v1/instances/\(F.instanceID)/artifacts",
                "DELETE /v1/artifacts/\(F.artifactID)",
            ])
        #expect(server.requests[0].query["limit"] == "500")
        #expect(server.requests[1].query["limit"] == "0")
    }

    // MARK: 收件箱

    @Test("inboxItem：GET /v1/inbox/{id}，带上关联的实例和运行")
    func inboxItem() async throws {
        let item = """
            {"id":"\(F.itemID)","instance_id":"\(F.instanceID)","run_id":"\(F.runID)","plan_id":null,
             "approval_id":null,"kind":"run_finished","title":"周报写好了","body":"摘要","ai_generated":true,
             "read":false,"created_at":"\(Self.created)"}
            """
        let server = try StubHTTPServer(routes: ["GET /v1/inbox/\(F.itemID)": R(200, json: item)])
        defer { server.stop() }
        let client = try Self.client(server)

        let got = try await client.inboxItem(InboxItemID(F.itemID))
        #expect(got.id == InboxItemID(F.itemID))
        #expect(got.instanceID == InstanceID(F.instanceID))
        #expect(got.runID == RunID(F.runID))
        #expect(got.kind == .runFinished)
        #expect(got.isAIGenerated)
        #expect(!got.isRead)
        #expect(H.routes(server) == ["GET /v1/inbox/\(F.itemID)"])
    }

    // MARK: 团队

    @Test("team、updateTeam、deleteTeam：GET / PATCH / DELETE /v1/teams/{id}；改的时候只带给了的字段")
    func team() async throws {
        let path = "/v1/teams/\(F.teamID)"
        let server = try StubHTTPServer(routes: [
            "GET \(path)": R(200, json: H.teamJSON), "PATCH \(path)": R(200, json: H.teamJSON),
            "DELETE \(path)": R(204, json: ""),
        ])
        defer { server.stop() }
        let client = try Self.client(server)
        let id = TeamID(F.teamID)

        let team = try await client.team(id)
        #expect(team.id == id)
        #expect(team.lead?.instanceID == InstanceID(F.instanceID))
        _ = try await client.updateTeam(id, name: "新名字", members: nil)
        let members = [ThinktinKit.TeamMember(instanceID: InstanceID(F.otherInstanceID), role: .lead, position: 0)]
        _ = try await client.updateTeam(id, name: nil, members: members)
        try await client.deleteTeam(id)

        #expect(H.routes(server) == ["GET \(path)", "PATCH \(path)", "PATCH \(path)", "DELETE \(path)"])
        #expect(try H.body(server.requests[1]) == ["name": "新名字"])
        #expect(
            try H.body(server.requests[2])
                == ["members": [["instance_id": .string(F.otherInstanceID), "role": "lead", "position": 0]]])
    }

    // MARK: 团队模板

    /// 服务端的模板把成员放在 `spec.members` 里。
    static let templateJSON = """
        {"id":"\(F.templateID)","name":"内容团队",
         "spec":{"members":[{"agent_id":"claude","harness":"acp","name":"主笔","role":"lead"},
                            {"agent_id":"hermes","harness":null,"name":"资料员","role":"member"}]},
         "created_at":"\(created)"}
        """

    @Test("teamTemplates：GET /v1/team-templates，成员从 spec.members 里取")
    func teamTemplates() async throws {
        let server = try StubHTTPServer(routes: [
            "GET /v1/team-templates": R(200, json: #"{"templates":[\#(Self.templateJSON)]}"#)
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let templates = try await client.teamTemplates()
        try #require(templates.count == 1)
        let template = templates[0]
        #expect(template.id == TeamTemplateID(F.templateID))
        #expect(template.name == "内容团队")
        #expect(template.createdAt.unixMilliseconds == F.createdMs)
        #expect(
            template.members == [
                ThinktinKit.TemplateMember(agentID: "claude", harness: "acp", name: "主笔", role: .lead),
                ThinktinKit.TemplateMember(agentID: "hermes", harness: nil, name: "资料员", role: .member),
            ])
        #expect(template.lead?.name == "主笔")
    }

    @Test("createTeamTemplate、createTeamTemplateFromTeam：POST /v1/team-templates，给成员时带 spec，从团队生成时带 team_id")
    func createTeamTemplate() async throws {
        let server = try StubHTTPServer(routes: ["POST /v1/team-templates": R(201, json: Self.templateJSON)])
        defer { server.stop() }
        let client = try Self.client(server)

        let members = [
            ThinktinKit.TemplateMember(agentID: "claude", harness: "acp", name: "主笔", role: .lead),
            ThinktinKit.TemplateMember(agentID: "hermes", name: "资料员"),
        ]
        let created = try await client.createTeamTemplate(name: "内容团队", members: members)
        #expect(created.members == members)
        _ = try await client.createTeamTemplateFromTeam(name: "发版小组模板", teamID: TeamID(F.teamID))

        try #require(server.requests.count == 2)
        #expect(
            try H.body(server.requests[0])
                == [
                    "name": "内容团队",
                    "spec": [
                        "members": [
                            ["agent_id": "claude", "harness": "acp", "name": "主笔", "role": "lead"],
                            ["agent_id": "hermes", "harness": nil, "name": "资料员", "role": "member"],
                        ]
                    ],
                    "team_id": nil,
                ])
        #expect(
            try H.body(server.requests[1]) == ["name": "发版小组模板", "spec": nil, "team_id": .string(F.teamID)])
    }

    @Test("adoptTeamTemplate、deleteTeamTemplate：POST …/adopt 带 name（不给发 null，用模板的名字）；DELETE /v1/team-templates/{id}")
    func adoptAndDeleteTemplate() async throws {
        let path = "/v1/team-templates/\(F.templateID)"
        let server = try StubHTTPServer(routes: [
            "POST \(path)/adopt": R(201, json: H.teamJSON), "DELETE \(path)": R(204, json: ""),
        ])
        defer { server.stop() }
        let client = try Self.client(server)
        let id = TeamTemplateID(F.templateID)

        let team = try await client.adoptTeamTemplate(id, name: "我的内容团队")
        #expect(team.id == TeamID(F.teamID))
        #expect(team.members.count == 2)
        _ = try await client.adoptTeamTemplate(id, name: nil)
        try await client.deleteTeamTemplate(id)

        #expect(H.routes(server) == ["POST \(path)/adopt", "POST \(path)/adopt", "DELETE \(path)"])
        #expect(try H.body(server.requests[0]) == ["name": "我的内容团队"])
        #expect(try H.body(server.requests[1]) == ["name": nil])
    }

    // MARK: 吊销当前这台

    @Test("revokeDevice：当前这台的 id 大小写不同也认得出来（client-core 按 UUID 比），照样马上退出登录")
    func revokeCurrentDeviceCaseInsensitive() async throws {
        let server = try StubHTTPServer(routes: [
            // client-core 把解析出的 UUID 按小写拼进路径。
            "DELETE /v1/devices/\(F.deviceID)": R(204, json: "")
        ])
        defer { server.stop() }
        let store = InMemorySessionStore(F.session)
        let client = try Self.client(server, sessions: store)

        try await client.revokeDevice(DeviceID(F.deviceID.uppercased()))
        #expect(H.routes(server) == ["DELETE /v1/devices/\(F.deviceID)"])
        #expect(!client.signedIn())
        #expect(store.load() == nil)
    }
}
