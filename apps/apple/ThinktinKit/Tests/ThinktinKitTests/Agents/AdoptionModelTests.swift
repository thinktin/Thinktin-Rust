import Foundation
import Testing

@testable import ThinktinKit

// 领养表单：起名、选接入方式、领养后引导去配模型路由。

@MainActor
@Suite("领养")
struct AdoptionModelTests {
    private var claude: AgentInfo { DemoData.agents[0] }
    private var codex: AgentInfo { DemoData.agents[1] }

    @Test("建议的名字是 agent 的名字，重名时加序号")
    func suggestedName() {
        #expect(AdoptionModel.suggestedName(for: claude, existingNames: []) == "Claude Agent")
        #expect(AdoptionModel.suggestedName(for: claude, existingNames: ["Claude Agent"]) == "Claude Agent 2")
        #expect(
            AdoptionModel.suggestedName(for: claude, existingNames: [" claude agent ", "Claude Agent 2"])
                == "Claude Agent 3")
        let model = AdoptionModel(client: AgentsFixture.mock(), agent: codex, existingNames: ["写作助手"])
        #expect(model.name == "Codex")
    }

    @Test("接入方式多于一个时才让选，默认选 agent 默认的")
    func harnessChoice() {
        let mock = AgentsFixture.mock()
        let claudeForm = AdoptionModel(client: mock, agent: claude)
        #expect(claudeForm.showsHarnessChoice)
        #expect(claudeForm.harnessOptions == ["acp", "cli"])
        #expect(claudeForm.harness == "acp")
        let codexForm = AdoptionModel(client: mock, agent: codex)
        #expect(!codexForm.showsHarnessChoice)
        #expect(codexForm.harness == "acp")
        let bare = AdoptionModel(client: mock, agent: AgentsFixture.agent("bare", harnesses: []))
        #expect(!bare.showsHarnessChoice)
        #expect(bare.harness == "")
    }

    @Test("名字不对时不能提交，也不发请求")
    func invalidName() async {
        let mock = AgentsFixture.mock()
        let model = AdoptionModel(client: mock, agent: claude)
        model.name = "   "
        #expect(model.nameProblem == .empty)
        #expect(!model.canSubmit)
        #expect(await model.adopt() == nil)
        model.name = String(repeating: "长", count: 65)
        #expect(model.nameProblem == .tooLong(max: 64))
        #expect(await model.adopt() == nil)
        #expect(mock.state.instances.count == 2)
    }

    @Test("领养：名字去掉首尾空白，带上选的接入方式；有能用的 key 就去配路由")
    func adoptClaude() async throws {
        let mock = AgentsFixture.mock()
        let model = AdoptionModel(client: mock, agent: claude)
        model.name = "  研究助手 "
        model.harness = "cli"
        let instance = try #require(await model.adopt())
        #expect(instance.name == "研究助手")
        #expect(instance.harness == "cli")
        #expect(instance.agentID == DemoData.claudeAgentID)
        #expect(model.adopted == instance)
        #expect(!model.canSubmit)
        #expect(mock.state.instances.contains { $0.id == instance.id })
        // Anthropic 的 key 和 DeepSeek 都支持 Anthropic 协议；停用的百炼不算。
        #expect(model.usableCredentials?.map(\.id) == [DemoData.claudeCredentialID, DemoData.deepseekCredentialID])
        #expect(model.nextStep == .configureRoutes)
        #expect(model.nextStepMessage(.chinese).contains("main"))
        // 领养过了，再点不会再领养一个。
        #expect(await model.adopt() == nil)
        #expect(mock.state.instances.count == 3)
    }

    @Test("没有能给这个 agent 用的 key：先去加 key，说明要哪种接口")
    func noUsableKey() async throws {
        // 只留 Anthropic 的 key：Codex 要 Responses，用不了。
        let mock = AgentsFixture.mock { s in s.credentials = s.credentials.filter { $0.vendor == "anthropic" } }
        let model = AdoptionModel(client: mock, agent: codex)
        _ = try #require(await model.adopt())
        #expect(model.usableCredentials == [])
        #expect(model.nextStep == .addCredentialFirst)
        #expect(model.nextStepMessage(.chinese).contains("OpenAI Responses"))
        #expect(model.nextStepMessage(.english).contains("Codex"))
    }

    @Test("Codex 能用 DeepSeek 的 key（支持 Responses）")
    func codexUsesDeepSeek() async throws {
        let model = AdoptionModel(client: AgentsFixture.mock(), agent: codex)
        _ = try #require(await model.adopt())
        #expect(model.usableCredentials?.map(\.id) == [DemoData.deepseekCredentialID])
        #expect(model.nextStep == .configureRoutes)
    }

    @Test("领养失败：记下错误，可以再试")
    func adoptFails() async {
        let mock = AgentsFixture.mock()
        let model = AdoptionModel(client: mock, agent: claude)
        mock.failNext(with: .api(status: 422, code: .invalid, message: "withdrawn", retryAfterSecs: nil))
        #expect(await model.adopt() == nil)
        #expect(model.error?.isInvalidInput == true)
        #expect(model.adopted == nil)
        #expect(model.canSubmit)
        #expect(await model.adopt() != nil)
        #expect(model.error == nil)
    }

    @Test("实例数到了上限（11.9，409 instance_limit）：领养失败，横幅说先删掉不用的实例，不给重试")
    func adoptOverInstanceLimit() async {
        let mock = AgentsFixture.mock { $0.instancesPerUser = 2 }
        let model = AdoptionModel(client: mock, agent: claude)
        #expect(await model.adopt() == nil)
        let error = model.error
        #expect(error?.apiCode == .instanceLimit)
        #expect(error?.isQuantityLimit == true && error?.isRetryable == false)
        #expect(error?.recovery == .limitReached)
        // 领养页的 ErrorBanner 显示的就是这句（ErrorPresentation 用 localizedMessage）。
        #expect(error?.localizedMessage(.chinese) == "实例数已达上限，删掉不用的实例再领养。")
        #expect(model.adopted == nil && model.canSubmit)
        #expect(mock.state.instances.count == 2)
        // 删掉一个以后再领养就行。
        try? await mock.deleteInstance(DemoData.reviewerID)
        #expect(await model.adopt() != nil)
        #expect(model.error == nil)
    }

    @Test("老的服务端没给协议：不知道要哪种接口时也给说明")
    func unknownProtocols() async throws {
        let agent = AgentsFixture.agent("legacy", name: "Legacy")
        let mock = AgentsFixture.mock { s in
            s.agents.append(agent)
            s.credentials = []
        }
        let model = AdoptionModel(client: mock, agent: agent)
        _ = try #require(await model.adopt())
        #expect(model.nextStep == .addCredentialFirst)
        #expect(!model.nextStepMessage(.chinese).contains("要支持"))
    }
}
