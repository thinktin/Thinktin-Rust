import Foundation
import Testing

@testable import ThinktinKit

// 新建 Botin 的表单（代码里还叫领养）：起名、选引擎（默认哪个、能不能选）、选接入方式、新建成功和失败。

@MainActor
@Suite("新建 Botin")
struct AdoptionModelTests {
    private var claude: AgentInfo { DemoData.agents[0] }
    private var codex: AgentInfo { DemoData.agents[1] }
    private var hermes: AgentInfo { DemoData.agents[2] }
    /// 写作助手（Claude Agent，2 分钟前活跃）、代码审查（Codex，10 分钟前）。
    private var demoInstances: [Instance] { DemoData.state().instances }

    /// 演示目录、演示的 Botin 上的表单。
    private func form(
        _ mock: MockClient = AgentsFixture.mock(), agents: [AgentInfo]? = nil, instances: [Instance]? = nil,
        preselected: AgentID? = nil
    ) -> AdoptionModel {
        AdoptionModel(
            client: mock, agents: agents ?? DemoData.agents, instances: instances ?? demoInstances,
            preselectedAgentID: preselected)
    }

    // MARK: 名字

    @Test("建议的名字是引擎的名字，和已有的 Botin 重名时加序号")
    func suggestedName() {
        #expect(AdoptionModel.suggestedName(for: claude, existingNames: []) == "Claude Agent")
        #expect(AdoptionModel.suggestedName(for: claude, existingNames: ["Claude Agent"]) == "Claude Agent 2")
        #expect(
            AdoptionModel.suggestedName(for: claude, existingNames: [" claude agent ", "Claude Agent 2"])
                == "Claude Agent 3")
        let model = form(preselected: codex.id)
        #expect(model.name == "Codex")
        // 已删除的 Botin 不占名字。
        var deleted = demoInstances[0]
        deleted.name = "Codex"
        deleted.state = .deleted
        #expect(form(instances: [deleted], preselected: codex.id).name == "Codex")
    }

    @Test("名字不对、没有引擎时不能提交，也不发请求")
    func invalidInput() async {
        let mock = AgentsFixture.mock()
        let model = form(mock)
        model.name = "   "
        #expect(model.nameProblem == .empty)
        #expect(!model.canSubmit)
        #expect(await model.adopt() == nil)
        model.name = String(repeating: "长", count: 65)
        #expect(model.nameProblem == .tooLong(max: 64))
        #expect(await model.adopt() == nil)
        model.name = String(repeating: "长", count: 64)
        #expect(model.nameProblem == nil && model.canSubmit)
        // 目录还没拉到：没有引擎可选。
        let empty = form(mock, agents: [])
        empty.name = "研究助手"
        #expect(empty.selectedAgentID == nil && !empty.canSubmit)
        #expect(await empty.adopt() == nil)
        #expect(mock.callCount("adopt(agentID:name:harness:)") == 0)
        #expect(mock.state.instances.count == 2)
    }

    @Test("用户自己填了名字才算有内容（取消前要确认）")
    func userInput() {
        let model = form()
        #expect(model.name == "Claude Agent")
        #expect(!model.hasUserInput)
        model.name = "  "
        #expect(!model.hasUserInput)
        model.name = " Claude Agent "
        #expect(!model.hasUserInput)
        model.name = "研究助手"
        #expect(model.hasUserInput)
    }

    // MARK: 引擎

    @Test("默认引擎：预选的，其次最近活跃的 Botin 用的，再次目录里第一个能用的")
    func defaultEngine() {
        let agents = DemoData.agents
        var instances = demoInstances
        // 写作助手（Claude）最近活跃。
        #expect(AdoptionModel.defaultEngine(agents: agents, instances: instances) == claude.id)
        // 预选的优先；不在目录里的（下架了）不算。
        #expect(AdoptionModel.defaultEngine(agents: agents, instances: instances, preferred: hermes.id) == hermes.id)
        #expect(AdoptionModel.defaultEngine(agents: agents, instances: instances, preferred: "retired") == claude.id)
        // 代码审查（Codex）更近：换成 Codex。
        instances[1].lastActiveAt = instances[0].lastActiveAt.addingTimeInterval(60)
        #expect(AdoptionModel.defaultEngine(agents: agents, instances: instances) == codex.id)
        // 最近活跃的那个已删除，或者它的引擎不在目录里：看下一个。
        instances[1].state = .deleted
        #expect(AdoptionModel.defaultEngine(agents: agents, instances: instances) == claude.id)
        #expect(AdoptionModel.defaultEngine(agents: [codex, hermes], instances: instances) == codex.id)
        // 还没有 Botin（第一次登录）：目录里第一个。
        #expect(AdoptionModel.defaultEngine(agents: agents, instances: []) == claude.id)
        // 不能用的跳过，也不能预选；都不能用时没有。
        let broken = AgentsFixture.agent("broken", name: "Broken", harnesses: [])
        #expect(!broken.canPowerNewBotin && claude.canPowerNewBotin)
        #expect(AdoptionModel.defaultEngine(agents: [broken, hermes], instances: []) == hermes.id)
        #expect(
            AdoptionModel.defaultEngine(agents: [broken, hermes], instances: [], preferred: broken.id) == hermes.id)
        #expect(AdoptionModel.defaultEngine(agents: [broken], instances: []) == nil)
        #expect(AdoptionModel.defaultEngine(agents: [], instances: instances) == nil)

        #expect(form().selectedAgentID == claude.id)
        #expect(form(preselected: hermes.id).selectedAgent == hermes)
        #expect(form(instances: []).selectedAgentID == claude.id)
    }

    @Test("选择器的行：名字、一句话介绍、几个 Botin 在用、不能用的选不了")
    func engineOptions() {
        let broken = AgentsFixture.agent("broken", name: "Broken", harnesses: [])
        let model = form(agents: DemoData.agents + [broken])
        let options = model.engineOptions(.chinese)
        #expect(options.map(\.id) == [claude.id, codex.id, hermes.id, broken.id])
        #expect(options.map(\.name) == ["Claude Agent", "Codex", "Hermes Agent", "Broken"])
        #expect(options.map(\.usedBy) == [1, 1, 0, 0])
        #expect(options.map(\.isAvailable) == [true, true, true, false])
        #expect(options[0].detail(.chinese) == claude.description)
        #expect(options[0].usageLabel == "1 个 Botin 在用")
        #expect(options[0].accessibilityLabel(.chinese).hasSuffix("，1 个 Botin 在用"))
        #expect(options[3].detail(.chinese) == "暂时不能用来新建 Botin")
        #expect(options[3].detail(.english) == "Can't be used for new Botins right now")
        // 老的服务端没给介绍：写几个 Botin 在用；也没有 Botin 用它时为空。
        let legacy = AgentsFixture.agent("legacy", name: "Legacy")
        var used = demoInstances[0]
        used.agentID = legacy.id
        let legacyOptions = form(agents: [legacy], instances: [used, demoInstances[0]]).engineOptions(.english)
        #expect(legacyOptions[0].detail(.english) == "Used by 1 Botin")
        #expect(legacyOptions[0].accessibilityLabel(.english) == "Legacy, Used by 1 Botin")
        #expect(form(agents: [legacy], instances: []).engineOptions(.english)[0].detail(.english) == "")
        // 不能用的选不上。
        #expect(!model.selectEngine(broken.id))
        #expect(!model.selectEngine("retired"))
        #expect(model.selectedAgentID == claude.id)
    }

    @Test("换引擎：接入方式换成它默认的；名字还是自动填的就跟着换，用户改过就不动")
    func switchEngine() {
        let model = form(instances: [])
        #expect(model.selectedAgentID == claude.id)
        #expect(model.showsHarnessChoice)
        #expect(model.harnessOptions == ["acp", "cli"])
        model.harness = "cli"
        #expect(model.selectEngine(codex.id))
        #expect(model.selectedAgent == codex)
        #expect(!model.showsHarnessChoice)
        #expect(model.harness == "acp")
        #expect(model.name == "Codex")
        model.name = "校对"
        #expect(model.selectEngine(hermes.id))
        #expect(model.name == "校对")
        // 再选回同一个引擎，接入方式不重置。
        #expect(model.selectEngine(claude.id))
        model.harness = "cli"
        #expect(model.selectEngine(claude.id))
        #expect(model.harness == "cli")
        // 名字清空也算用户改过（不会被填回去）。
        model.name = ""
        #expect(model.selectEngine(codex.id))
        #expect(model.name == "")
    }

    @Test("拉目录：没有目录时拉到再选默认的；用户选过的还在就留着；拉不到记下错误")
    func loadCatalog() async {
        let mock = AgentsFixture.mock()
        let model = AdoptionModel(client: mock, instances: demoInstances, preselectedAgentID: hermes.id)
        #expect(model.selectedAgentID == nil && !model.hasLoadedAgents)
        await model.load()
        #expect(model.hasLoadedAgents && model.agents.count == 3)
        #expect(model.selectedAgentID == hermes.id)
        #expect(model.name == "Hermes Agent")
        #expect(model.selectEngine(codex.id))
        await model.load()
        #expect(model.selectedAgentID == codex.id)
        // 用户选的那个下架了：换回默认的。
        mock.update { $0.agents.removeAll { $0.id == DemoData.codexAgentID } }
        await model.load()
        #expect(model.selectedAgentID == hermes.id)
        // 没选过的（默认的）按新目录重新挑：预选的现在才拉到。
        let late = AdoptionModel(
            client: mock, agents: [claude], instances: demoInstances, preselectedAgentID: hermes.id)
        #expect(late.selectedAgentID == claude.id)
        await late.load()
        #expect(late.selectedAgentID == hermes.id)
        mock.failNext(with: .network(message: "offline"))
        await late.load()
        #expect(late.loadError?.isOffline == true)
        #expect(late.selectedAgentID == hermes.id)
        await late.load()
        #expect(late.loadError == nil)
    }

    // MARK: 新建

    @Test("新建：名字去掉首尾空白，带上选的引擎和接入方式；建过了再点不会再建")
    func createClaude() async throws {
        let mock = AgentsFixture.mock()
        let model = form(mock)
        model.name = "  研究助手 "
        model.harness = "cli"
        let instance = try #require(await model.adopt())
        #expect(instance.name == "研究助手")
        #expect(instance.harness == "cli")
        #expect(instance.agentID == DemoData.claudeAgentID)
        #expect(model.adopted == instance)
        #expect(!model.canSubmit && !model.isAdopting)
        #expect(!model.hasUserInput)
        #expect(mock.state.instances.contains { $0.id == instance.id })
        #expect(await model.adopt() == nil)
        #expect(mock.state.instances.count == 3)
        // 建好之后不能再换引擎。
        #expect(model.selectedAgentID == claude.id)
    }

    @Test("同一个引擎可以给好几个 Botin 用：每次新建都是一个新的")
    func sameEngineTwice() async throws {
        let mock = AgentsFixture.mock()
        let first = try #require(await form(mock, preselected: codex.id).adopt())
        let second = try #require(
            await form(mock, instances: mock.state.instances, preselected: codex.id).adopt())
        #expect(first.id != second.id)
        #expect(first.agentID == codex.id && second.agentID == codex.id)
        #expect(first.name == "Codex" && second.name == "Codex 2")
        #expect(mock.state.instances.filter { $0.agentID == codex.id }.count == 3)
    }

    @Test("新建失败：记下错误，可以再试")
    func createFails() async {
        let mock = AgentsFixture.mock()
        let model = form(mock)
        mock.failNext(with: .api(status: 422, code: .invalid, message: "withdrawn", retryAfterSecs: nil))
        #expect(await model.adopt() == nil)
        #expect(model.error?.isInvalidInput == true)
        #expect(model.adopted == nil)
        #expect(model.canSubmit)
        #expect(await model.adopt() != nil)
        #expect(model.error == nil)
    }

    @Test("Botin 数到了上限（11.9，409 instance_limit）：新建失败，横幅说先删掉不用的，不给重试")
    func createOverInstanceLimit() async {
        let mock = AgentsFixture.mock { $0.instancesPerUser = 2 }
        let model = form(mock)
        #expect(await model.adopt() == nil)
        let error = model.error
        #expect(error?.apiCode == .instanceLimit)
        #expect(error?.isQuantityLimit == true && error?.isRetryable == false)
        #expect(error?.recovery == .limitReached)
        // 表单里的 ErrorBanner 显示的就是这句（ErrorPresentation 用 localizedMessage）。
        #expect(error?.localizedMessage(.chinese) == "Botin 数已达上限，删掉不用的再新建。")
        #expect(model.adopted == nil && model.canSubmit)
        #expect(mock.state.instances.count == 2)
        // 删掉一个以后再新建就行。
        try? await mock.deleteInstance(DemoData.reviewerID)
        #expect(await model.adopt() != nil)
        #expect(model.error == nil)
    }

    @Test("没给接入方式的引擎、接入方式不在列表里时不带接入方式")
    func harnessFallback() async throws {
        let agent = AgentsFixture.agent("legacy", name: "Legacy")
        let mock = AgentsFixture.mock { $0.agents.append(agent) }
        let model = form(mock, agents: [agent])
        model.harness = "cli"
        let instance = try #require(await model.adopt())
        #expect(instance.harness == "acp")
    }

    // MARK: 文案

    @Test("引擎的脚注：专有许可写许可说明和“新建即表示同意”，别的说在沙箱里运行")
    func engineFooter() {
        let claudeNote = NewBotinText.engineFooter(claude, language: .chinese)
        #expect(claudeNote.hasPrefix("许可证："))
        #expect(claudeNote.contains("Anthropic"))
        #expect(claudeNote.hasSuffix("新建即表示你同意按上面的条款使用这个引擎。"))
        let codexNote = NewBotinText.engineFooter(codex, language: .english)
        #expect(codexNote.hasPrefix("License: Apache-2.0."))
        #expect(codexNote.contains("sandbox"))
        #expect(!codexNote.contains("agree"))
        #expect(NewBotinText.nameHint(.chinese).contains("64"))
        #expect(NewBotinText.create(.chinese) == "创建" && NewBotinText.create(.english) == "Create")
    }
}
