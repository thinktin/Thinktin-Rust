import Foundation
import Testing

@testable import ThinktinKit

// Agent 目录、详情的视图模型。

@MainActor
@Suite("Agent 目录与详情")
struct AgentCatalogModelTests {
    @Test("拉目录：卡片上有名字、版本、许可证、接入方式和已领养的个数")
    func loadCatalog() async throws {
        let mock = AgentsFixture.mock()
        let model = AgentCatalogModel(client: mock)
        #expect(model.hasNothingToShow)
        #expect(!model.isEmpty)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.error == nil)
        #expect(model.agents.map(\.id) == [DemoData.claudeAgentID, DemoData.codexAgentID, DemoData.hermesAgentID])

        let cards = model.cards(instances: mock.state.instances, language: .chinese)
        #expect(cards.map(\.name) == ["Claude Agent", "Codex", "Hermes Agent"])
        #expect(cards.map(\.adoptedCount) == [1, 1, 0])
        let claude = try #require(cards.first)
        #expect(claude.monogram == "C")
        #expect(claude.versionLabel == "v0.90.0")
        #expect(claude.isProprietary)
        #expect(claude.licenseLabel.contains("专有"))
        #expect(claude.harnessLabels == ["ACP 适配器", "命令行"])
        #expect(claude.summary.contains("Claude Agent SDK"))
        #expect(claude.byline != nil)
        #expect(claude.adoptedLabel(.chinese) == "已领养 1 个")
        let label = claude.accessibilityLabel(.chinese)
        #expect(label.contains("Claude Agent") && label.contains("v0.90.0") && label.contains("命令行"))

        let codex = cards[1]
        #expect(codex.byline == "使用 OpenAI Codex")
        #expect(codex.licenseLabel == "Apache-2.0")
        #expect(!codex.isProprietary)
        let hermes = cards[2]
        #expect(hermes.adoptedLabel(.english) == nil)
        #expect(hermes.byline == nil)
        #expect(model.agent(DemoData.hermesAgentID)?.name == "Hermes Agent")
        #expect(model.agent("nope") == nil)
    }

    @Test("请求语言是英文时介绍是英文的")
    func englishCatalog() async throws {
        let mock = AgentsFixture.mock()
        try mock.setAcceptLanguage(for: .english)
        let model = AgentCatalogModel(client: mock)
        await model.load()
        let card = try #require(model.cards(instances: [], language: .english).first)
        #expect(card.summary.hasPrefix("General-purpose agent"))
        #expect(card.harnessLabels == ["ACP adapter", "Command line"])
        #expect(card.adoptedLabel(.english) == nil)
    }

    @Test("拉不到时留着上次的目录，记下错误；成功后清掉")
    func failureKeepsAgents() async {
        let mock = AgentsFixture.mock()
        let model = AgentCatalogModel(client: mock)
        await model.load()
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.error?.isOffline == true)
        #expect(model.agents.count == 3)
        await model.load()
        #expect(model.error == nil)
    }

    @Test("第一次就拉不到：没有东西可显示，也不算“目录是空的”")
    func firstLoadFails() async {
        let mock = AgentsFixture.mock()
        mock.failNext(with: .network(message: "offline"))
        let model = AgentCatalogModel(client: mock)
        await model.load()
        #expect(!model.hasLoaded)
        #expect(model.hasNothingToShow)
        #expect(!model.isEmpty)
        #expect(model.error?.isOffline == true)
    }

    @Test("目录是空的")
    func emptyCatalog() async {
        let model = AgentCatalogModel(client: AgentsFixture.mock { $0.agents = [] })
        await model.load()
        #expect(model.isEmpty)
    }

    @Test("已领养的个数不算已删除的实例")
    func adoptedCounts() {
        var instances = DemoData.state().instances
        instances.append(
            Instance(
                id: "gone", agentID: DemoData.claudeAgentID, agentVersion: "0.90.0", harness: "acp", name: "旧的",
                state: .deleted, createdAt: Fixture.now, lastActiveAt: Fixture.now))
        let counts = AgentCatalogModel.adoptedCounts(instances)
        #expect(counts[DemoData.claudeAgentID] == 1)
        #expect(counts[DemoData.codexAgentID] == 1)
        #expect(counts[DemoData.hermesAgentID] == nil)
    }

    @Test("接入方式默认的在前，版本列表没给时只有当前版本")
    func agentHelpers() {
        let agent = AgentInfo(id: "x", name: "X", version: "2.0", harnesses: ["cli", "acp"], defaultHarness: "acp")
        #expect(agent.catalogHarnesses == ["acp", "cli"])
        #expect(agent.catalogVersions == ["2.0"])
        #expect(agent.catalogLatestVersion == "2.0")
        let odd = AgentInfo(id: "y", name: "Y", version: "1", harnesses: ["cli"], defaultHarness: "acp")
        #expect(odd.catalogHarnesses == ["cli"])
    }

    @Test("详情：带着目录里的那条先显示，拉完更新；列出这个 agent 的实例")
    func detail() async {
        let mock = AgentsFixture.mock()
        let seeded = AgentDetailModel(client: mock, agentID: DemoData.codexAgentID, agent: DemoData.agents[1])
        #expect(seeded.agent?.id == DemoData.codexAgentID)
        #expect(seeded.displayName == "Codex")
        await seeded.load()
        #expect(seeded.hasLoaded)
        #expect(!seeded.isMissing)
        #expect(seeded.adoptedInstances(in: mock.state.instances).map(\.id) == [DemoData.reviewerID])

        // 带错了的 agent 不用。
        let mismatched = AgentDetailModel(client: mock, agentID: DemoData.claudeAgentID, agent: DemoData.agents[1])
        #expect(mismatched.agent == nil)
        #expect(mismatched.displayName == "Claude Agent")
    }

    @Test("详情：目录里没有了就是下架，拉不到时不算下架")
    func detailMissing() async {
        let mock = AgentsFixture.mock()
        let missing = AgentDetailModel(client: mock, agentID: "retired")
        await missing.load()
        #expect(missing.isMissing)
        #expect(missing.displayName == "retired")

        mock.failNext(with: .network(message: "offline"))
        let offline = AgentDetailModel(client: mock, agentID: DemoData.claudeAgentID)
        await offline.load()
        #expect(!offline.isMissing)
        #expect(offline.error?.isOffline == true)
    }
}
