import Foundation
import Testing

@testable import ThinktinKit

// 新建 Botin 的表单（代码里还叫领养）：起名（默认空的）、头像外观、选引擎（默认哪个、能不能选）、选接入方式、
// 底部按钮能不能点、新建成功（记下头像外观）和失败。

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
        preselected: AgentID? = nil, name: String = "", appearances: InstanceAppearanceStore? = nil
    ) -> AdoptionModel {
        let model = AdoptionModel(
            client: mock, agents: agents ?? DemoData.agents, instances: instances ?? demoInstances,
            preselectedAgentID: preselected, appearances: appearances)
        model.name = name
        return model
    }

    // MARK: 名字

    @Test("名字默认是空的（不再填引擎名），“新建”不能点；换引擎名字不动")
    func emptyDefaultName() {
        let model = form(preselected: codex.id)
        #expect(model.name == "")
        #expect(model.nameProblem == .empty)
        #expect(model.selectedAgentID == codex.id)
        #expect(!model.canSubmit && !model.canCreate(isOffline: false))
        #expect(!model.hasUserInput)
        #expect(model.selectEngine(hermes.id))
        #expect(model.name == "")
        model.name = "研究助手"
        #expect(model.canSubmit)
        #expect(model.selectEngine(claude.id))
        #expect(model.name == "研究助手")
        // 没有 Botin（第一次登录）、目录还没拉到也是空的。
        #expect(AdoptionModel(client: AgentsFixture.mock()).name == "")
    }

    @Test("输入框下面的小字只在有用时出现：空的不说，只有空格、太长说问题，快到上限提示上限")
    func nameNote() {
        let model = form()
        #expect(model.nameNote(.chinese) == nil)
        model.name = "  "
        #expect(model.nameNote(.chinese) == NameNote(text: "起个名字吧。", isProblem: true))
        model.name = "研究助手"
        #expect(model.nameNote(.chinese) == nil)
        model.name = String(repeating: "长", count: InstanceNameRule.maxLength - AdoptionModel.nameHintThreshold)
        #expect(model.nameNote(.chinese) == nil)
        model.name += "长"
        #expect(model.nameNote(.chinese) == NameNote(text: NewBotinText.nameHint(.chinese), isProblem: false))
        #expect(model.nameNote(.english)?.text.contains("64") == true)
        model.name = String(repeating: "长", count: InstanceNameRule.maxLength + 1)
        #expect(model.nameNote(.english) == NameNote(text: "Names can be up to 64 characters.", isProblem: true))
    }

    @Test("编辑 Botin 的名字也用这条规则，平时不写脚注；名字删空了要说（本来有名字）")
    func editNameNote() {
        #expect(AdoptionModel.nameNote(for: "写作助手", hidesUntouchedEmpty: false, language: .chinese) == nil)
        #expect(
            AdoptionModel.nameNote(for: "", hidesUntouchedEmpty: false, language: .chinese)
                == NameNote(text: "起个名字吧。", isProblem: true))
        #expect(AdoptionModel.nameNote(for: "", language: .chinese) == nil)
        let nearLimit = String(repeating: "长", count: InstanceNameRule.maxLength - AdoptionModel.nameHintThreshold + 1)
        #expect(
            AdoptionModel.nameNote(for: nearLimit, hidesUntouchedEmpty: false, language: .chinese)
                == NameNote(text: NewBotinText.nameHint(.chinese), isProblem: false))
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

    @Test("填了名字、挑过形状或颜色才算有内容（取消前要确认）")
    func userInput() {
        let model = form()
        #expect(!model.hasUserInput)
        model.name = "  "
        #expect(!model.hasUserInput)
        model.name = "研究助手"
        #expect(model.hasUserInput)
        model.name = ""
        model.shape = .hexagon
        #expect(model.hasUserInput)
        model.shape = .circle
        #expect(!model.hasUserInput)
        model.color = .navy
        #expect(model.hasUserInput)
    }

    @Test("底部的“新建”：名字对、选了能用的引擎、在线才能点；新建中、建好之后不能")
    func createButtonEnabled() async throws {
        let model = form()
        #expect(!model.canCreate(isOffline: false))
        model.name = "研究助手"
        #expect(model.canCreate(isOffline: false))
        #expect(!model.canCreate(isOffline: true))
        // 没有能用的引擎（目录是空的、都不能用）。
        let broken = AgentsFixture.agent("broken", name: "Broken", harnesses: [])
        #expect(!form(agents: [broken], name: "研究助手").canCreate(isOffline: false))
        #expect(!form(agents: [], name: "研究助手").canCreate(isOffline: false))
        // 建好之后。
        _ = try #require(await model.adopt())
        #expect(!model.canCreate(isOffline: false))
    }

    // MARK: 头像

    @Test("头像默认圆形、按名字取色；颜色没选时跟着名字变，选了就固定")
    func avatarDefaults() {
        let model = form()
        #expect(model.appearance == .default)
        #expect(model.shape == .circle && model.color == nil)
        model.name = "周报助手"
        #expect(model.resolvedColor == AvatarColor.forName("周报助手"))
        model.name = "日程"
        #expect(model.resolvedColor == AvatarColor.forName("日程"))
        model.color = .graphite
        #expect(model.resolvedColor == .graphite)
        model.name = "周报助手"
        #expect(model.resolvedColor == .graphite)
        model.shape = .cloud
        #expect(model.appearance == InstanceAppearance(shape: .cloud, color: .graphite))
    }

    @Test("新建成功后把头像外观记进这台设备；默认的不记；失败的不记")
    func createStoresAppearance() async throws {
        let store = InstanceAppearanceStore(defaults: nil)
        let mock = AgentsFixture.mock()
        let model = form(mock, name: "研究助手", appearances: store)
        model.shape = .flower
        model.color = .orchid
        mock.failNext(with: .network(message: "offline"))
        #expect(await model.adopt() == nil)
        #expect(store.appearances.isEmpty)
        let instance = try #require(await model.adopt())
        #expect(store.appearance(for: instance.id) == InstanceAppearance(shape: .flower, color: .orchid))
        // 只挑了形状：颜色还是按名字取（以后改名跟着变）。
        let shapeOnly = form(mock, name: "校对", appearances: store)
        shapeOnly.shape = .star
        let second = try #require(await shapeOnly.adopt())
        #expect(store.appearance(for: second.id) == InstanceAppearance(shape: .star, color: nil))
        // 什么都没挑：不记，画出来和以前一样。
        let plain = try #require(await form(mock, name: "翻译", appearances: store).adopt())
        #expect(store.appearance(for: plain.id) == nil)
        #expect(store.resolved(for: plain.id) == .default)
        #expect(store.appearances.count == 2)
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
        // 都不能用：没有选上的，菜单按钮上说没有能用的，“新建”不能点。
        let none = form(agents: [broken])
        #expect(none.selectedAgent == nil && none.engineOptions(.chinese).map(\.isAvailable) == [false])
        none.name = "周报助手"
        #expect(!none.canCreate(isOffline: false))
        #expect(NewBotinText.noUsableEngine(.chinese) == "暂时没有能用的")
        #expect(NewBotinText.noUsableEngine(.english) == "None available")
    }

    @Test("换引擎：接入方式换成它默认的；名字不动")
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
        #expect(model.name == "")
        model.name = "校对"
        #expect(model.selectEngine(hermes.id))
        #expect(model.name == "校对")
        // 再选回同一个引擎，接入方式不重置。
        #expect(model.selectEngine(claude.id))
        model.harness = "cli"
        #expect(model.selectEngine(claude.id))
        #expect(model.harness == "cli")
    }

    @Test("拉目录：没有目录时拉到再选默认的；用户选过的还在就留着；拉不到记下错误")
    func loadCatalog() async {
        let mock = AgentsFixture.mock()
        let model = AdoptionModel(client: mock, instances: demoInstances, preselectedAgentID: hermes.id)
        #expect(model.selectedAgentID == nil && !model.hasLoadedAgents)
        await model.load()
        #expect(model.hasLoadedAgents && model.agents.count == 3)
        #expect(model.selectedAgentID == hermes.id)
        #expect(model.name == "")
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

    @Test("引擎详情要的引擎：目录还没拉到时先记下，拉到后选它，不被默认的盖掉；之后自己选的为准")
    func engineRequestBeforeCatalog() async {
        let mock = AgentsFixture.mock()
        // 默认的是最近活跃的写作助手用的 Claude Agent。
        let model = AdoptionModel(client: mock, instances: demoInstances)
        // 打开表单时那次拉没拉到（出错，或者压上引擎目录时被取消了）：目录是空的。
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.agents.isEmpty && model.selectedAgentID == nil)
        model.requestEngine(hermes.id)
        #expect(model.selectedAgentID == nil)
        await model.load()
        #expect(model.selectedAgentID == hermes.id)
        // 再拉一次也留着（算用户选的）。
        await model.load()
        #expect(model.selectedAgentID == hermes.id)
        // 目录里有的马上换。
        model.requestEngine(codex.id)
        #expect(model.selectedAgentID == codex.id)
        // 不能用的不换、也不记下。
        let broken = AgentsFixture.agent("broken", name: "Broken", harnesses: [])
        let withBroken = form(agents: DemoData.agents + [broken])
        withBroken.requestEngine(broken.id)
        #expect(withBroken.selectedAgentID == claude.id)
        // 旧目录里没有：先记下；之后自己在选择器里选了别的，拉到新目录时不再换成要的那个。
        let stale = AdoptionModel(client: mock, agents: [claude], instances: demoInstances)
        stale.requestEngine(hermes.id)
        #expect(stale.selectedAgentID == claude.id)
        #expect(stale.selectEngine(claude.id))
        await stale.load()
        #expect(stale.selectedAgentID == claude.id)
        // 没自己选：拉到新目录就换成要的那个。
        let staleUntouched = AdoptionModel(client: mock, agents: [claude], instances: demoInstances)
        staleUntouched.requestEngine(codex.id)
        await staleUntouched.load()
        #expect(staleUntouched.selectedAgentID == codex.id)
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
        let first = try #require(await form(mock, preselected: codex.id, name: "校对").adopt())
        let second = try #require(
            await form(mock, instances: mock.state.instances, preselected: codex.id, name: "翻译").adopt())
        #expect(first.id != second.id)
        #expect(first.agentID == codex.id && second.agentID == codex.id)
        #expect(first.name == "校对" && second.name == "翻译")
        #expect(mock.state.instances.filter { $0.agentID == codex.id }.count == 3)
    }

    @Test("新建失败：记下错误，可以再试")
    func createFails() async {
        let mock = AgentsFixture.mock()
        let model = form(mock, name: "研究助手")
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
        let model = form(mock, name: "研究助手")
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
        let model = form(mock, agents: [agent], name: "研究助手")
        model.harness = "cli"
        let instance = try #require(await model.adopt())
        #expect(instance.harness == "acp")
    }

    // MARK: 文案

    @Test("许可：一行小字只给专有许可说“新建即表示同意”，别的写许可证；全文写许可说明或在沙箱里运行")
    func licenseTexts() {
        // 专有许可（目录给了许可说明）：要同意。
        #expect(NewBotinText.requiresConsent(claude) && !NewBotinText.requiresConsent(codex))
        #expect(NewBotinText.licenseCaption(claude, language: .chinese) == "新建即表示同意 Claude Agent 的许可条款")
        #expect(
            NewBotinText.licenseCaption(claude, language: .english)
                == "By creating, you agree to the Claude Agent terms")
        #expect(NewBotinText.licenseCaption(codex, language: .chinese) == "Codex 采用 Apache-2.0 许可")
        #expect(NewBotinText.licenseCaption(codex, language: .english) == "Codex is licensed under Apache-2.0")
        #expect(!NewBotinText.licenseCaption(codex, language: .english).contains("agree"))
        let unlicensed = AgentsFixture.agent("legacy", name: "Legacy")
        #expect(NewBotinText.licenseCaption(unlicensed, language: .chinese) == "Legacy 没有注明许可证")
        #expect(NewBotinText.viewLicense(.chinese) == "查看" && NewBotinText.viewLicense(.english) == "View")
        // 点“查看”看到的全文。
        let claudeNote = NewBotinText.licenseDetails(claude, language: .chinese)
        #expect(claudeNote.hasPrefix("许可证："))
        #expect(claudeNote.contains("Anthropic"))
        #expect(claudeNote.hasSuffix("新建即表示你同意按上面的条款使用这个引擎。"))
        let codexNote = NewBotinText.licenseDetails(codex, language: .english)
        #expect(codexNote.hasPrefix("License: Apache-2.0."))
        #expect(codexNote.contains("sandbox"))
        #expect(!codexNote.contains("agree"))
        #expect(NewBotinText.nameHint(.chinese).contains("64"))
        #expect(NewBotinText.namePrompt(.chinese) == "起个名字")
        #expect(NewBotinText.namePrompt(.english) == "Name your Botin")
        // 按钮、转圈的读屏、脚注都说“新建”，和标题“新建 Botin”一致。
        #expect(NewBotinText.create(.chinese) == "新建" && NewBotinText.create(.english) == "Create")
        #expect(NewBotinText.creating(.chinese) == "正在新建" && NewBotinText.creating(.english) == "Creating")
    }
}
