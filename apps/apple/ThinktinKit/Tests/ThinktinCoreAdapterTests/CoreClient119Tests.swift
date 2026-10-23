import Foundation
import Testing
import ThinktinCore
import ThinktinKit

@testable import ThinktinCoreAdapter

/// 11.9（backend-core 补安卓会话提的缺口）接进适配层：改 key 的每日上限、厂商的订阅类 key 前缀和套餐专用地址、
/// 数量上限类的错误码（`instance_limit`，以后的 `*_limit` 原样交过来）。请求经真实的 client-core 发到本机的
/// `StubHTTPServer`；路由照 crates/gateway/src/routes/mod.rs，字段名照 client-core 的 api.rs、错误体照 proto 的 api.rs。
@Suite("11.9：每日上限、厂商表、数量上限的错误码（经真实核心）")
struct CoreClient119Tests {
    typealias F = AdapterFixture
    typealias R = StubHTTPServer.Response
    typealias H = CoreClientAppAPIHTTPTests

    static let credentialID = CoreClientAppAPIForwardingTests.credentialID

    static func client(_ server: StubHTTPServer) throws -> CoreClient {
        try H.client(server)
    }

    // MARK: 每日上限

    static func credentialJSON(limit: String) -> String {
        """
        {"id":"\(credentialID)","vendor":"deepseek","label":"备用","last4":"wxyz","daily_token_limit":\(limit),
         "disabled":false,"created_at":"\(H.created)"}
        """
    }

    @Test("setCredentialDailyLimit：PATCH /v1/credentials/{id} 只带 daily_token_limit；nil 发 null（取消上限）")
    func setCredentialDailyLimit() async throws {
        let path = "/v1/credentials/\(Self.credentialID)"
        let server = try StubHTTPServer(routes: ["PATCH \(path)": R(200, json: Self.credentialJSON(limit: "500000"))])
        defer { server.stop() }
        let client = try Self.client(server)
        let id = CredentialID(Self.credentialID)

        let credential = try await client.setCredentialDailyLimit(id, dailyTokenLimit: 500_000)
        #expect(credential.id == id)
        #expect(credential.dailyTokenLimit == 500_000)
        #expect(credential.last4 == "wxyz")
        _ = try await client.setCredentialDailyLimit(id, dailyTokenLimit: nil)
        // 很大的值原样发出去（服务端存成 i64，超了报 invalid）。
        _ = try await client.setCredentialDailyLimit(id, dailyTokenLimit: 9_000_000_000_000)

        #expect(H.routes(server) == ["PATCH \(path)", "PATCH \(path)", "PATCH \(path)"])
        #expect(try H.body(server.requests[0]) == ["daily_token_limit": 500_000])
        // 带了 null（不是不带）：服务端区分“不改”和“取消”。
        #expect(try H.body(server.requests[1]) == ["daily_token_limit": nil])
        #expect(try H.body(server.requests[2]) == ["daily_token_limit": 9_000_000_000_000])
    }

    @Test("setCredentialDailyLimit：服务端回 422 invalid（上限是 0）原样转成 ClientError")
    func setCredentialDailyLimitRejected() async throws {
        let path = "/v1/credentials/\(Self.credentialID)"
        let server = try StubHTTPServer(routes: [
            "PATCH \(path)": R(422, json: #"{"code":"invalid","message":"daily_token_limit must be positive"}"#)
        ])
        defer { server.stop() }
        let client = try Self.client(server)
        await #expect(
            throws: ThinktinKit.ClientError.api(
                status: 422, code: .invalid, message: "daily_token_limit must be positive", retryAfterSecs: nil)
        ) {
            _ = try await client.setCredentialDailyLimit(CredentialID(Self.credentialID), dailyTokenLimit: 0)
        }
        #expect(try H.body(server.requests[0]) == ["daily_token_limit": 0])
    }

    // MARK: 厂商表

    @Test("vendors()：订阅类 key 的前缀、套餐专用地址转过来；老的服务端没给时是空的")
    func vendors() async throws {
        let json = """
            {"vendors":[
             {"id":"anthropic","name":"Anthropic (Claude)","protocols":["anthropic","chat"],"models":["claude-opus-5-5"],
              "notes":"","subscription_key_prefixes":["sk-ant-oat","sk-ant-ort"],"plan_only_bases":[]},
             {"id":"glm-cn","name":"智谱 BigModel","protocols":["anthropic","chat","responses"],"models":["glm-5.3"],
              "notes":"只接按量付费 key","subscription_key_prefixes":[],
              "plan_only_bases":["https://open.bigmodel.cn/api/coding"]},
             {"id":"deepseek","name":"DeepSeek","protocols":["chat"]}
            ]}
            """
        let server = try StubHTTPServer(routes: ["GET /v1/vendors": R(200, json: json)])
        defer { server.stop() }
        let client = try Self.client(server)

        let vendors = try await client.vendors()
        try #require(vendors.count == 3)
        #expect(vendors[0].subscriptionKeyPrefixes == ["sk-ant-oat", "sk-ant-ort"])
        #expect(vendors[0].planOnlyBases.isEmpty)
        #expect(vendors[0].subscriptionKeyPrefix(of: " sk-ant-oat01-x ") == "sk-ant-oat")
        #expect(vendors[1].planOnlyBases == ["https://open.bigmodel.cn/api/coding"])
        #expect(vendors[1].notes == "只接按量付费 key")
        // 老的服务端：两个字段都没有，models、notes 也没有。
        #expect(vendors[2].subscriptionKeyPrefixes.isEmpty && vendors[2].planOnlyBases.isEmpty)
        #expect(vendors[2].models.isEmpty && vendors[2].notes.isEmpty)
        // 自定义端点查的是所有厂商的套餐地址。
        #expect(
            VendorInfo.planOnlyBase(of: "https://open.bigmodel.cn/api/coding/paas/v4", vendors: vendors)
                == "https://open.bigmodel.cn/api/coding")
    }

    @Test("VendorInfo：两个新字段直接转换")
    func vendorConversion() {
        let core = ThinktinCore.VendorInfo(
            id: "qwen-cn", name: "阿里云百炼（北京）", protocols: ["chat"], models: [], notes: "",
            subscriptionKeyPrefixes: ["sk-sp-"], planOnlyBases: ["https://example.com/plan"])
        let vendor = ThinktinKit.VendorInfo(core: core)
        #expect(vendor.subscriptionKeyPrefixes == ["sk-sp-"])
        #expect(vendor.planOnlyBases == ["https://example.com/plan"])
        // 默认值（UniFFI 的 `#[uniffi(default = [])]`）。
        let bare = ThinktinKit.VendorInfo(
            core: ThinktinCore.VendorInfo(id: "x", name: "X", protocols: [], models: [], notes: ""))
        #expect(bare.subscriptionKeyPrefixes.isEmpty && bare.planOnlyBases.isEmpty)
    }

    // MARK: 数量上限的错误码

    @Test("领养到了实例数上限：409 instance_limit 转成 .instanceLimit，界面按“删掉一个再领养”处理")
    func instanceLimit() async throws {
        let body = #"{"code":"instance_limit","message":"at most 5 instances per account"}"#
        let server = try StubHTTPServer(routes: [
            "POST /v1/instances": R(409, json: body),
            "POST /v1/team-templates/\(F.templateID)/adopt": R(409, json: body),
        ])
        defer { server.stop() }
        let client = try Self.client(server)
        let expected = ThinktinKit.ClientError.api(
            status: 409, code: .instanceLimit, message: "at most 5 instances per account", retryAfterSecs: nil)

        await #expect(throws: expected) {
            _ = try await client.adopt(agentID: "claude", name: "第六个", harness: nil)
        }
        await #expect(throws: expected) {
            _ = try await client.adoptTeamTemplate(TeamTemplateID(F.templateID), name: nil)
        }
        #expect(expected.recovery == .limitReached && !expected.isRetryable)
    }

    @Test("这个版本不认识的错误码（以后的 *_limit）：client-core 原样交过来，不当成解析失败")
    func futureLimitCode() async throws {
        let server = try StubHTTPServer(routes: [
            "POST /v1/instances": R(409, json: #"{"code":"workspace_limit","message":"too many workspaces"}"#),
            "GET /v1/instances": R(418, json: #"{"code":"teapot"}"#),
        ])
        defer { server.stop() }
        let client = try Self.client(server)

        let error = await #expect(throws: ThinktinKit.ClientError.self) {
            _ = try await client.adopt(agentID: "claude", name: "x", harness: nil)
        }
        #expect(
            error
                == .api(
                    status: 409, code: .unknown("workspace_limit"), message: "too many workspaces", retryAfterSecs: nil)
        )
        #expect(error?.isQuantityLimit == true)
        #expect(error?.recovery == .limitReached)
        #expect(error?.localizedMessage(.chinese) == "数量已达上限，删掉一些不用的再试。")

        // 不是 *_limit 的不认识的码：通用错误，message 没给时是空的。
        let other = await #expect(throws: ThinktinKit.ClientError.self) { _ = try await client.instances() }
        #expect(other == .api(status: 418, code: .unknown("teapot"), message: "", retryAfterSecs: nil))
        #expect(other?.recovery == .generic)
    }

    @Test("错误转换：instance_limit 和不认识的 *_limit")
    func errorMapping() {
        #expect(
            ThinktinKit.ClientError(
                core: .Api(status: 409, code: "instance_limit", detail: "at most 3", retryAfterSecs: nil))
                == .api(status: 409, code: .instanceLimit, message: "at most 3", retryAfterSecs: nil))
        let future = ThinktinKit.ClientError(
            core: .Api(status: 409, code: "im_channel_limit", detail: "", retryAfterSecs: nil))
        #expect(future.apiCode == .unknown("im_channel_limit"))
        #expect(future.isQuantityLimit)
    }
}
