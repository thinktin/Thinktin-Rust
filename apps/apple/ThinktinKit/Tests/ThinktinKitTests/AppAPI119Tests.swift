import Foundation
import Testing

@testable import ThinktinKit

// 11.9（backend-core 补安卓会话提的缺口）带来的模型和 MockClient 的变化：厂商的订阅类 key 前缀和套餐专用地址、
// 改 key 的每日上限、数量上限类的错误码（`instance_limit`）、删除实例连带处理别名和计划、保存别名时留着停用的 key。
// 规则照 crates/client-core/src/ffi.rs 的注释、crates/gateway/src/routes/{credentials,instances,plans,teams}.rs、
// crates/store/src/{credentials,instances,plans}.rs 和 crates/proto/src/{api,vendors}.rs。

private let writer = DemoData.writerID
private let reviewer = DemoData.reviewerID

private func makeClient(signedIn: Bool = true) -> MockClient {
    MockClient(state: DemoData.state(signedIn: signedIn), stepDelay: 0, autoReply: false)
}

/// 抛出的错误（只关心状态和错误码）。
private func failure(_ body: () async throws -> Void) async -> (status: Int, code: APIErrorCode)? {
    do {
        try await body()
        return nil
    } catch ClientError.api(let status, let code, _, _) {
        return (status, code)
    } catch {
        Issue.record("应该是接口错误，实际是 \(error)")
        return nil
    }
}

// MARK: - 厂商表

@Suite("厂商：订阅类 key 的前缀、套餐专用地址（11.9）")
struct VendorInfo119Tests {
    @Test("两个字段默认是空的；演示数据和服务端的厂商表一致")
    func fields() {
        let bare = VendorInfo(id: "v", name: "V", protocols: ["chat"], models: [])
        #expect(bare.subscriptionKeyPrefixes.isEmpty && bare.planOnlyBases.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: DemoData.vendors.map { ($0.id, $0) })
        #expect(byID["anthropic"]?.subscriptionKeyPrefixes == ["sk-ant-oat", "sk-ant-ort"])
        #expect(byID["qwen-cn"]?.subscriptionKeyPrefixes == ["sk-sp-"])
        #expect(byID["openai"]?.subscriptionKeyPrefixes == [])
        #expect(byID["deepseek"]?.subscriptionKeyPrefixes == [])
        #expect(DemoData.vendors.allSatisfy { $0.planOnlyBases.isEmpty }, "这四家都没有套餐专用地址")
    }

    @Test("订阅类 key：去掉首尾空白后按前缀认，区分大小写")
    func subscriptionKey() throws {
        let anthropic = try #require(DemoData.vendors.first { $0.id == "anthropic" })
        #expect(anthropic.subscriptionKeyPrefix(of: "sk-ant-oat01-abcdef") == "sk-ant-oat")
        #expect(anthropic.subscriptionKeyPrefix(of: "  sk-ant-ort01-abcdef\n") == "sk-ant-ort")
        #expect(anthropic.subscriptionKeyPrefix(of: "sk-ant-api03-abcdef") == nil, "按量付费的 key")
        #expect(anthropic.subscriptionKeyPrefix(of: "SK-ANT-OAT01-abcdef") == nil, "区分大小写")
        let openai = try #require(DemoData.vendors.first { $0.id == "openai" })
        #expect(openai.subscriptionKeyPrefix(of: "sk-ant-oat01-abcdef") == nil, "只查选的这家")
        // 空前缀不算（不会把什么 key 都当成订阅类的）。
        let odd = VendorInfo(id: "x", name: "X", protocols: [], models: [], subscriptionKeyPrefixes: [""])
        #expect(odd.subscriptionKeyPrefix(of: "anything") == nil)
    }

    @Test("套餐专用地址：去掉首尾空白、ASCII 转小写后等于前缀或接着是 /；查的是所有厂商")
    func planOnlyBase() {
        let vendors = [
            VendorInfo(
                id: "glm-cn", name: "智谱", protocols: ["chat"], models: [],
                planOnlyBases: ["https://open.bigmodel.cn/api/coding"]),
            VendorInfo(
                id: "doubao-cn", name: "豆包", protocols: ["chat"], models: [],
                planOnlyBases: [
                    "https://ark.cn-beijing.volces.com/api/coding", "https://ark.cn-beijing.volces.com/api/plan",
                ]),
        ]
        let coding = "https://open.bigmodel.cn/api/coding"
        #expect(VendorInfo.planOnlyBase(of: coding, vendors: vendors) == coding)
        #expect(
            VendorInfo.planOnlyBase(of: " HTTPS://Open.BigModel.cn/api/coding/paas/v4 ", vendors: vendors) == coding)
        #expect(
            VendorInfo.planOnlyBase(of: "https://ark.cn-beijing.volces.com/api/plan/v3", vendors: vendors)
                == "https://ark.cn-beijing.volces.com/api/plan")
        #expect(VendorInfo.planOnlyBase(of: "https://open.bigmodel.cn/api/codingx", vendors: vendors) == nil)
        #expect(VendorInfo.planOnlyBase(of: "https://open.bigmodel.cn/api/paas/v4", vendors: vendors) == nil)
        #expect(VendorInfo.planOnlyBase(of: "https://llm.example.com/v1", vendors: vendors) == nil)
        #expect(VendorInfo.planOnlyBase(of: coding, vendors: DemoData.vendors) == nil)
        // 只转 ASCII（和服务端的 to_ascii_lowercase 一样）：开尔文符号（U+212A）不当成 k。
        #expect(
            VendorInfo.planOnlyBase(of: "https://ar\u{212A}.cn-beijing.volces.com/api/plan", vendors: vendors) == nil)
        #expect(
            VendorInfo.planOnlyBase(of: "https://ARK.cn-beijing.volces.com/api/plan", vendors: vendors)
                == "https://ark.cn-beijing.volces.com/api/plan")
    }
}

// MARK: - 错误码

@Suite("数量上限类的错误码（11.9）")
struct QuantityLimitCodeTests {
    @Test("instance_limit 认得；以 _limit 结尾的（包括不认识的）都算数量上限")
    func codes() {
        #expect(APIErrorCode(rawValue: "instance_limit") == .instanceLimit)
        #expect(APIErrorCode.instanceLimit.rawValue == "instance_limit")
        #expect(APIErrorCode.instanceLimit.isKnown)
        #expect(APIErrorCode.instanceLimit.isQuantityLimit)
        #expect(APIErrorCode(rawValue: "vault_item_limit") == .unknown("vault_item_limit"))
        #expect(APIErrorCode.unknown("vault_item_limit").isQuantityLimit)
        for code in [APIErrorCode.conflict, .rateLimited, .invalid, .unknown("limit"), .unknown("_limit")] {
            #expect(!code.isQuantityLimit, "\(code)")
        }
        #expect(APIErrorCode.unknown("limited").isQuantityLimit == false)
    }
}

// MARK: - 每日上限

@Suite("MockClient：改 key 的每日上限（11.9）")
struct MockDailyLimitTests {
    @Test("改上限、取消上限；返回改完的 key，列表里也变了")
    func setAndClear() async throws {
        let client = makeClient()
        let id = DemoData.claudeCredentialID
        #expect(client.state.credentials.first { $0.id == id }?.dailyTokenLimit == 2_000_000)
        let raised = try await client.setCredentialDailyLimit(id, dailyTokenLimit: 5_000_000)
        #expect(raised.id == id && raised.dailyTokenLimit == 5_000_000)
        #expect(try await client.credentials().first { $0.id == id }?.dailyTokenLimit == 5_000_000)
        let cleared = try await client.setCredentialDailyLimit(id, dailyTokenLimit: nil)
        #expect(cleared.dailyTokenLimit == nil)
        // 原来没有上限的也能设。
        let set = try await client.setCredentialDailyLimit(DemoData.deepseekCredentialID, dailyTokenLimit: 1)
        #expect(set.dailyTokenLimit == 1)
        #expect(client.callCount("setCredentialDailyLimit(_:dailyTokenLimit:)") == 3)
    }

    @Test("0 和超出范围的抛 invalid（422），先于 key 存不存在；不存在的 key 抛 not_found")
    func rejects() async throws {
        let client = makeClient()
        let id = DemoData.claudeCredentialID
        let zero = await failure { _ = try await client.setCredentialDailyLimit(id, dailyTokenLimit: 0) }
        #expect(zero?.status == 422 && zero?.code == .invalid)
        let huge = await failure { _ = try await client.setCredentialDailyLimit(id, dailyTokenLimit: UInt64.max) }
        #expect(huge?.code == .invalid)
        #expect(
            await failure { _ = try await client.setCredentialDailyLimit("missing", dailyTokenLimit: 0) }?.code
                == .invalid)
        #expect(
            await failure { _ = try await client.setCredentialDailyLimit("missing", dailyTokenLimit: 10) }?.code
                == .notFound)
        #expect(client.state.credentials.first { $0.id == id }?.dailyTokenLimit == 2_000_000, "失败了不改")
        let signedOut = makeClient(signedIn: false)
        await #expect(throws: ClientError.signedOut) {
            _ = try await signedOut.setCredentialDailyLimit(id, dailyTokenLimit: nil)
        }
    }

    @Test("经过 ObservedClient 原样转发")
    @MainActor
    func forwarded() async throws {
        let mock = makeClient()
        let app = AppModel(client: mock, defaults: nil)
        let key = try await app.client.setCredentialDailyLimit(DemoData.claudeCredentialID, dailyTokenLimit: 42)
        #expect(key.dailyTokenLimit == 42)
        #expect(mock.callCount("setCredentialDailyLimit(_:dailyTokenLimit:)") == 1)
    }
}

// MARK: - 模型别名与 key

@Suite("MockClient：别名里停用的 key、删 key、删实例（11.9）")
struct MockRoutesAndKeysTests {
    @Test("保存别名：实例原来就用着的停用 key 可以留着，新引用停用的 key 抛 invalid")
    func disabledKeys() async throws {
        let client = makeClient()
        // 写作助手的 main 用 Claude（备用 DeepSeek），fast 用 Claude；停用 DeepSeek。
        _ = try await client.updateCredential(DemoData.deepseekCredentialID, label: nil, disabled: true)
        var routes = try await client.modelRoutes(instanceID: writer)
        // 去掉 fast，main 的备用（停用的 DeepSeek）留着：能保存。
        routes.removeAll { $0.alias == "fast" }
        try await client.setModelRoutes(instanceID: writer, routes: routes)
        #expect(try await client.modelRoutes(instanceID: writer) == routes)
        // 停用的 key 从备用挪到主路由也算原来就用着的。
        let moved = [
            ModelRoute(alias: "main", credentialID: DemoData.deepseekCredentialID, upstreamModel: "deepseek-v4-pro")
        ]
        try await client.setModelRoutes(instanceID: writer, routes: moved)

        // 实例原来没用的停用 key（百炼）：不收。
        let qwen = [ModelRoute(alias: "main", credentialID: DemoData.qwenCredentialID, upstreamModel: "qwen3.8-max")]
        let rejected = await failure { try await client.setModelRoutes(instanceID: writer, routes: qwen) }
        #expect(rejected?.status == 422 && rejected?.code == .invalid)
        let asFallback = [
            ModelRoute(
                alias: "main", credentialID: DemoData.claudeCredentialID, upstreamModel: "claude-sonnet-5-5",
                fallbacks: [RouteFallback(credentialID: DemoData.qwenCredentialID, upstreamModel: "qwen3.8-max")])
        ]
        #expect(
            await failure { try await client.setModelRoutes(instanceID: writer, routes: asFallback) }?.code == .invalid)
        #expect(try await client.modelRoutes(instanceID: writer) == moved, "失败了不改")

        // 去掉以后再加回来就是新引用了：不收。
        let claudeOnly = [
            ModelRoute(alias: "main", credentialID: DemoData.claudeCredentialID, upstreamModel: "claude-sonnet-5-5")
        ]
        try await client.setModelRoutes(instanceID: writer, routes: claudeOnly)
        #expect(await failure { try await client.setModelRoutes(instanceID: writer, routes: moved) }?.code == .invalid)
        // 代码审查自己的 main 就是停用的 DeepSeek：换个模型照样能保存。
        let reviewerRoutes = [
            ModelRoute(alias: "main", credentialID: DemoData.deepseekCredentialID, upstreamModel: "deepseek-flash")
        ]
        try await client.setModelRoutes(instanceID: reviewer, routes: reviewerRoutes)
    }

    @Test("删 key：还有实例的别名用着时抛 409；删掉用它的实例后就能删")
    func deleteKeyAfterInstance() async throws {
        let client = makeClient()
        // DeepSeek：代码审查的 main、写作助手 main 的备用。
        let used = await failure { try await client.deleteCredential(DemoData.deepseekCredentialID) }
        #expect(used?.status == 409 && used?.code == .conflict)

        try await client.deleteInstance(reviewer)
        #expect(client.state.routes[reviewer] == nil, "它的别名一起删了")
        #expect(await failure { try await client.deleteCredential(DemoData.deepseekCredentialID) }?.code == .conflict)
        // 写作助手的备用也去掉以后没人用了。
        let routes = try await client.modelRoutes(instanceID: writer).map { route -> ModelRoute in
            var r = route
            r.fallbacks = []
            return r
        }
        try await client.setModelRoutes(instanceID: writer, routes: routes)
        try await client.deleteCredential(DemoData.deepseekCredentialID)
        #expect(!client.state.credentials.contains { $0.id == DemoData.deepseekCredentialID })

        // 只有一个实例用着的 key：删掉那个实例就能删。
        try await client.deleteInstance(writer)
        try await client.deleteCredential(DemoData.claudeCredentialID)
        // 状态里留着已删除实例的别名（老版本留下的）也不挡。
        let stale = makeClient()
        stale.update { $0.instances.removeAll { $0.id == reviewer } }
        let blocked = await failure { try await stale.deleteCredential(DemoData.deepseekCredentialID) }
        #expect(blocked?.code == .conflict, "写作助手的备用还在用")
        stale.update { $0.instances.removeAll { $0.id == writer } }
        try await stale.deleteCredential(DemoData.deepseekCredentialID)
    }

    @Test("删实例：它自己的计划没了；别的实例的流水线有一步在它上面的暂停，恢复、确认抛 409，改了步骤才行")
    func deleteInstancePlans() async throws {
        let client = makeClient()
        let schedule = Schedule.cron(expression: "0 9 * * 1-5", timeZone: "Asia/Shanghai")
        let pipeline = try await client.createPlan(
            NewPlan(
                instanceID: writer, title: "写完再审", goal: "写周报，再让代码审查看一遍。", triggers: [schedule],
                steps: [
                    PlanStep(key: "write", instanceID: writer, prompt: "写周报"),
                    PlanStep(key: "review", instanceID: reviewer, prompt: "审一遍", dependsOn: ["write"]),
                ]))
        let solo = try await client.createPlan(
            NewPlan(instanceID: writer, title: "只在写作助手上", goal: "整理笔记。", triggers: [schedule]))
        let reviewersOwn = try await client.plans(instanceID: reviewer).map(\.id)
        #expect(!reviewersOwn.isEmpty)

        try await client.deleteInstance(reviewer)
        let plans = try await client.plans(instanceID: nil)
        #expect(plans.allSatisfy { $0.instanceID == writer }, "代码审查自己的计划一起删了")
        for id in reviewersOwn {
            #expect(await failure { _ = try await client.getPlan(id) }?.code == .notFound)
        }
        #expect(try await client.getPlan(pipeline.id).isPaused, "流水线有一步在删掉的实例上：暂停")
        #expect(try await client.getPlan(solo.id).isPaused == false, "没有步骤在它上面的不动")

        let resume = await failure { _ = try await client.setPlanPaused(pipeline.id, paused: false) }
        #expect(resume?.status == 409 && resume?.code == .conflict)
        #expect(
            await failure { _ = try await client.confirmPlan(pipeline.id, revision: pipeline.revision) }?.code
                == .conflict)
        // 暂停照样可以。
        _ = try await client.setPlanPaused(pipeline.id, paused: true)
        // 步骤改到还在的实例上以后就能恢复。
        _ = try await client.updatePlan(
            pipeline.id,
            change: PlanChange(steps: [
                PlanStep(key: "write", instanceID: writer, prompt: "写周报"),
                PlanStep(key: "review", instanceID: writer, prompt: "自己审一遍", dependsOn: ["write"]),
            ]))
        #expect(try await client.setPlanPaused(pipeline.id, paused: false).isPaused == false)
    }

    @Test("删实例：等确认的流水线不改成暂停（服务端只暂停 active 的），确认要先改步骤；改完确认后照常生效")
    func deleteInstanceAwaitingPlan() async throws {
        let client = makeClient()
        let planID: PlanID = "awaiting-pipeline"
        client.update { state in
            state.plans.append(
                Plan(
                    id: planID, instanceID: writer, title: "agent 改过的流水线", goal: "写完再审", createdBy: .agent,
                    awaitingConfirmation: true, revision: 2, createdAt: Date(),
                    steps: [
                        PlanStep(key: "write", instanceID: writer, prompt: "写"),
                        PlanStep(key: "review", instanceID: reviewer, prompt: "审", dependsOn: ["write"]),
                    ]))
        }
        try await client.deleteInstance(reviewer)
        let plan = try await client.getPlan(planID)
        #expect(plan.awaitingConfirmation)
        #expect(!plan.isPaused, "等确认的不动")
        #expect(await failure { _ = try await client.confirmPlan(planID, revision: 2) }?.code == .conflict)

        let changed = try await client.updatePlan(
            planID, change: PlanChange(steps: [PlanStep(key: "write", instanceID: writer, prompt: "写")]))
        let confirmed = try await client.confirmPlan(planID, revision: changed.revision)
        #expect(!confirmed.awaitingConfirmation && !confirmed.isPaused, "确认后照常生效，不会留在暂停里")
    }
}

// MARK: - 实例数上限

@Suite("MockClient：实例数上限（11.9）")
struct MockInstanceLimitTests {
    @Test("默认不限；到了上限领养抛 409 instance_limit，删掉一个再领养就行")
    func adopt() async throws {
        let client = makeClient()
        #expect(client.state.instancesPerUser == 0)
        _ = try await client.adopt(agentID: DemoData.claudeAgentID, name: "不限", harness: nil)
        #expect(client.state.instances.count == 3)

        client.update { $0.instancesPerUser = 3 }
        let limited = await failure {
            _ = try await client.adopt(agentID: DemoData.claudeAgentID, name: "第四个", harness: nil)
        }
        #expect(limited?.status == 409 && limited?.code == .instanceLimit)
        #expect(client.state.instances.count == 3)
        // 名字不对的先报 invalid（和服务端一样，先查领养请求再数实例）。
        #expect(
            await failure { _ = try await client.adopt(agentID: DemoData.claudeAgentID, name: " ", harness: nil) }?
                .code == .invalid)

        try await client.deleteInstance(reviewer)
        _ = try await client.adopt(agentID: DemoData.claudeAgentID, name: "第四个", harness: nil)
        #expect(client.state.instances.count == 3)
    }

    @Test("归档的实例也算")
    func archivedCounts() async {
        let client = makeClient()
        client.update { state in
            state.instancesPerUser = 2
            state.instances[1].state = .archived
        }
        #expect(
            await failure { _ = try await client.adopt(agentID: DemoData.claudeAgentID, name: "x", harness: nil) }?
                .code == .instanceLimit)
    }

    @Test("团队模板：放不下整个团队时一个也不领养；团队名不对先报 invalid")
    func template() async throws {
        let client = makeClient()
        // 内容团队有 3 个成员，现在有 2 个实例。
        client.update { $0.instancesPerUser = 4 }
        let full = await failure { _ = try await client.adoptTeamTemplate(DemoData.contentTemplateID, name: nil) }
        #expect(full?.status == 409 && full?.code == .instanceLimit)
        #expect(client.state.instances.count == 2, "一个也没领养")
        #expect(client.state.teams.count == 1, "没建团队")
        #expect(
            await failure { _ = try await client.adoptTeamTemplate(DemoData.contentTemplateID, name: "  ") }?.code
                == .invalid)

        client.update { $0.instancesPerUser = 5 }
        let team = try await client.adoptTeamTemplate(DemoData.contentTemplateID, name: nil)
        #expect(team.members.count == 3)
        #expect(client.state.instances.count == 5)
        #expect(
            await failure { _ = try await client.adopt(agentID: DemoData.claudeAgentID, name: "x", harness: nil) }?
                .code == .instanceLimit)
    }

    @Test("注销账号后上限还在（是服务端的配置）")
    func survivesErase() async throws {
        let client = makeClient()
        client.update { $0.instancesPerUser = 1 }
        try await client.sendSelfCode(purpose: .deleteAccount)
        try await client.deleteAccount(code: client.state.verificationCode)
        #expect(client.state.instancesPerUser == 1)
    }
}

// MARK: - 调用计数

@Suite("MockClient：调用计数")
struct MockCallCountTests {
    @Test("数经过 Mock 的调用，失败的也算；不数 signedIn、upgradeRequired")
    func counts() async throws {
        let client = makeClient()
        #expect(client.callCount("me()") == 0)
        _ = try await client.me()
        client.failNext(with: .network(message: "offline"))
        _ = try? await client.me()
        #expect(client.callCount("me()") == 2)
        _ = try client.cachedInstances()
        #expect(client.callCount("cachedInstances()") == 1)
        try client.setAcceptLanguage("en")
        #expect(client.callCount("setAcceptLanguage(_:)") == 1)
        _ = client.signedIn()
        _ = client.upgradeRequired()
        #expect(client.callCount("signedIn()") == 0 && client.callCount("upgradeRequired()") == 0)
        #expect(client.callCount("setLocale(_:)") == 0)
    }
}

@Suite("MockClient：只拦某个方法的错误")
struct MockMethodFailureTests {
    @Test("failNext(_:with:) 只让那个方法的下一次抛错，别的方法照常；failNext(with:) 排着的先抛")
    func methodFailures() async throws {
        let client = makeClient()
        client.failNext("me()", with: .network(message: "offline"))
        _ = try client.cachedInstances()
        _ = try await client.instances()
        await #expect(throws: ClientError.network(message: "offline")) { _ = try await client.me() }
        _ = try await client.me()

        client.failNext("me()", with: .network(message: "second"))
        client.failNext(with: .network(message: "first"))
        await #expect(throws: ClientError.network(message: "first")) { _ = try await client.me() }
        await #expect(throws: ClientError.network(message: "second")) { _ = try await client.me() }
        _ = try await client.me()
    }
}

@Suite("MockClient：订阅类 key、套餐专用地址（11.9，按厂商表）")
struct MockVendorRuleTests {
    @Test("添加、换 key：这家的订阅类 key 抛 invalid，说法和服务端一样（CredentialRejection 认得出）")
    func subscriptionKeys() async throws {
        let client = makeClient()
        let added = await failure {
            _ = try await client.addCredential(
                NewCredential(vendor: "anthropic", label: "", apiKey: "sk-ant-oat01-0123456789"))
        }
        #expect(added?.status == 422 && added?.code == .invalid)
        do {
            _ = try await client.addCredential(NewCredential(vendor: "qwen-cn", label: "", apiKey: "sk-sp-0123456789"))
            Issue.record("应该被拒")
        } catch let error as ClientError {
            #expect(CredentialRejection(error) == .subscriptionKey)
        }
        // 别家的前缀不管；按量的 key 照收。
        _ = try await client.addCredential(NewCredential(vendor: "openai", label: "", apiKey: "sk-sp-0123456789"))
        _ = try await client.addCredential(
            NewCredential(vendor: "anthropic", label: "", apiKey: "sk-ant-api03-0123456789"))

        let replaced = await failure {
            _ = try await client.replaceCredentialSecret(DemoData.claudeCredentialID, apiKey: "sk-ant-ort01-0123456789")
        }
        #expect(replaced?.code == .invalid)
        #expect(client.state.credentials.first { $0.id == DemoData.claudeCredentialID }?.last4 == "Q7mA")
    }

    @Test("自定义地址填了任何一家的套餐专用地址：抛 invalid，认得出是哪个地址")
    func planOnlyBases() async throws {
        let client = makeClient()
        client.update {
            $0.vendors.append(
                VendorInfo(
                    id: "glm-cn", name: "智谱", protocols: ["anthropic"], models: [],
                    planOnlyBases: ["https://open.bigmodel.cn/api/coding"]))
        }
        do {
            _ = try await client.addCredential(
                NewCredential(
                    vendor: NewCredential.customVendor, label: "", apiKey: "gw-0123456789",
                    anthropicBase: "https://open.bigmodel.cn/api/coding/anthropic"))
            Issue.record("应该被拒")
        } catch let error as ClientError {
            #expect(CredentialRejection(error) == .planOnlyEndpoint(field: .anthropic))
        }
        _ = try await client.addCredential(
            NewCredential(
                vendor: NewCredential.customVendor, label: "", apiKey: "gw-0123456789",
                anthropicBase: "https://open.bigmodel.cn/api/anthropic"))
    }
}
