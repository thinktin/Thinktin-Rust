import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 引擎目录与新建 Botin（WBS 12.3，代码里是 agent 目录与领养）的界面：每个页面在浅色中文、深色英文、大字号下都能布局，
/// 新建表单、删除确认页、新建后和删除后的跳转。视图模型的逻辑在 ThinktinKitTests 的 Agents 里测。
@MainActor
@Suite("引擎目录与新建 Botin 的界面")
struct AgentsScreensTests {
    static let routes: [AppRoute] = [
        .agentCatalog, .agent(DemoData.claudeAgentID), .agent(DemoData.codexAgentID), .agent("retired"),
        .instance(DemoData.writerID), .instance(DemoData.reviewerID), .instance("gone"), .adopt(agentID: nil),
        .adopt(agentID: DemoData.codexAgentID), .adopt(agentID: "retired"),
    ]

    @Test("每个页面都能布局（中文浅色、英文深色）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(AgentsDestination(route: route).previewShell())
            hostAndLayout(AgentsDestination(route: route).previewShell(.english, scheme: .dark))
        }
    }

    @Test("大字号（AX3）也能布局")
    func accessibilitySizes() {
        for route in Self.routes {
            hostAndLayout(AgentsDestination(route: route).previewShell().dynamicTypeSize(.accessibility3))
        }
        hostAndLayout(
            AgentCatalogCardView(card: AgentCatalogCard(agent: DemoData.agents[0], adoptedCount: 1))
                .dynamicTypeSize(.accessibility3))
    }

    @Test("目录是空的、没有 key 的账号")
    func emptyStates() {
        hostAndLayout(AgentCatalogScreen().previewShell(client: AgentsPreviewClients.emptyCatalog()))
        hostAndLayout(
            AgentsDestination(route: .instance(DemoData.writerID)).previewShell(client: AgentsPreviewClients.noKeys()))
    }

    @Test("新建表单：在演示账号、新账号上，Claude（两种接入方式、许可说明）和预选的 Codex；目录拉不到")
    func adoptionForm() {
        hostAndLayout(NavigationStack { AdoptAgentSheet() }.previewShell())
        hostAndLayout(
            NavigationStack { AdoptAgentSheet(preselectedAgentID: DemoData.codexAgentID) }
                .previewShell(.english, scheme: .dark))
        hostAndLayout(
            NavigationStack { AdoptAgentSheet() }.previewShell(client: ShellPreviewClients.empty())
                .dynamicTypeSize(.accessibility3))
        let offline = MockClient(autoReply: false)
        offline.failNext("agents()", with: .network(message: "offline"))
        hostAndLayout(NavigationStack { AdoptAgentSheet() }.previewShell(client: offline))
        hostAndLayout(NavigationStack { AdoptAgentSheet() }.previewShell(client: AgentsPreviewClients.emptyCatalog()))
    }

    @Test("改名表单")
    func renameSheet() {
        let mock = MockClient(autoReply: false)
        let writer = InstanceDetailModel(client: mock, instanceID: DemoData.writerID, instance: mock.state.instances[0])
        hostAndLayout(InstanceRenameSheet(model: writer) {}.previewShell())
        hostAndLayout(InstanceRenameSheet(model: writer) {}.previewShell(.english, scheme: .dark))
    }

    @Test("删除确认页：有级联（代码审查在流水线和团队里）、没有级联")
    func deleteSheet() {
        hostAndLayout(
            InstanceDeletePreview(instanceID: DemoData.reviewerID).previewShell(
                client: AgentsPreviewClients.withPipeline()))
        hostAndLayout(
            InstanceDeletePreview(instanceID: DemoData.writerID)
                .previewShell(.english, scheme: .dark, client: AgentsPreviewClients.withPipeline()))
    }

    @Test("卡片和影响清单能出图")
    func render() {
        renderInBothAppearances(
            AgentCatalogCardView(card: AgentCatalogCard(agent: DemoData.agents[0], adoptedCount: 1)))
        renderInBothAppearances(AgentCatalogCardView(card: AgentCatalogCard(agent: DemoData.agents[2])))
        var state = DemoData.state()
        state.plans.append(
            Plan(
                id: AgentsPreviewClients.pipelinePlanID, instanceID: DemoData.writerID, title: "发版流水线", goal: "发版",
                createdBy: .agent, createdAt: Date(),
                steps: [
                    PlanStep(key: "a", instanceID: DemoData.writerID, prompt: "a"),
                    PlanStep(key: "b", instanceID: DemoData.reviewerID, prompt: "b", dependsOn: ["a"]),
                    PlanStep(key: "c", instanceID: DemoData.writerID, prompt: "c", dependsOn: ["b"]),
                ]))
        let impact = InstanceDeletionImpact.compute(
            instanceID: DemoData.reviewerID, plans: state.plans, teams: state.teams, runs: state.runs, artifactCount: 3)
        #expect(impact.pipelinesToPause.count == 1)
        renderInBothAppearances(InstanceDeletionImpactView(impact: impact))
        // 已经暂停、在等确认的流水线（11.9：状态不改，同样要先改步骤）。
        var paused = state.plans[state.plans.count - 1]
        paused.isPaused = true
        var awaiting = paused
        awaiting.id = "awaiting"
        awaiting.isPaused = false
        awaiting.awaitingConfirmation = true
        let held = InstanceDeletionImpact.compute(
            instanceID: DemoData.reviewerID, plans: [paused, awaiting], teams: [], runs: [], artifactCount: nil)
        #expect(held.pipelines.map(\.effect) == [.stillPaused, .confirmationBlocked])
        renderInBothAppearances(InstanceDeletionImpactView(impact: held))
        renderInBothAppearances(InstanceDeletionImpactView(impact: InstanceDeletionImpact(instanceID: "lonely")))
    }

    @Test("新建之后：从首页“+”弹的表单里新建，关掉表单、从首页压栈进新 Botin 的对话，挑的头像记下；空状态下面提示去配模型路由")
    func afterCreation() async throws {
        let mock = MockClient(state: DemoData.newAccountState(), autoReply: false)
        let app = AppModel(client: mock, defaults: nil)
        await app.start()
        #expect(app.homePlaceholder == .noBotins)
        // 空状态的“新建 Botin”和右上的“+”一样。
        app.router.open(.adopt(agentID: nil))
        app.router.open(.agentCatalog)
        let form = AdoptionModel(client: app.client, instances: app.instances, appearances: app.appearances)
        await form.load()
        #expect(form.selectedAgentID == DemoData.claudeAgentID)
        // 名字默认空的，“新建”灰着；起了名字、挑了形状和颜色才能点。
        #expect(form.name.isEmpty && !form.canCreate(isOffline: app.isOffline))
        form.name = "主笔"
        form.shape = .flower
        form.color = .teal
        #expect(form.canCreate(isOffline: false) && !form.canCreate(isOffline: true))
        let instance = try #require(await form.adopt())
        await app.openCreatedInstance(instance)
        #expect(app.router.sheet == nil && app.router.sheetPath.isEmpty)
        #expect(app.router.path == [.conversation(instance.id)])
        #expect(app.instances.map(\.name) == ["主笔"])
        // 挑的头像记进这台设备，首页的行、对话标题按它画。
        #expect(app.appearances.resolved(for: instance.id) == InstanceAppearance(shape: .flower, color: .teal))
        let row = try #require(app.homeRows.first)
        hostAndLayout(
            List { HomeInstanceRow(row: row, appearance: app.appearances.resolved(for: row.id)) }
                .shellEnvironment(app))
        hostAndLayout(AppShell(model: app))
        let conversation = ConversationModel(client: app.client, instanceID: instance.id)
        await conversation.start()
        #expect(conversation.needsSetupNote)
        hostAndLayout(ConversationSetupNote {}.previewShell())
        hostAndLayout(ConversationSetupNote {}.previewShell(.english, scheme: .dark).dynamicTypeSize(.accessibility3))
    }

    @Test("删掉不是当前的实例：拿掉它的页面，当前实例不变")
    func leaveDeletedOther() async throws {
        let mock = MockClient(autoReply: false)
        let app = AppModel(client: mock, defaults: nil)
        await app.start()
        #expect(app.router.currentInstanceID == DemoData.writerID)
        app.router.open(.agentCatalog)
        app.router.open(.instance(DemoData.reviewerID))
        app.router.open(.modelRoutes(DemoData.reviewerID))
        try await app.client.deleteInstance(DemoData.reviewerID)
        await InstanceDetailScreen.leaveDeletedInstance(DemoData.reviewerID, app: app, router: app.router)
        #expect(app.router.path == [.agentCatalog])
        #expect(app.router.currentInstanceID == DemoData.writerID)
        #expect(!app.instances.contains { $0.id == DemoData.reviewerID })
    }

    @Test("删掉当前实例：应用框架换到别的实例，它的对话和资料页都拿掉，回到首页")
    func leaveDeletedCurrent() async throws {
        let mock = MockClient(autoReply: false)
        let app = AppModel(client: mock, defaults: nil)
        await app.start()
        app.router.open(.conversation(DemoData.writerID))
        app.router.open(.instance(DemoData.writerID))
        try await app.client.deleteInstance(DemoData.writerID)
        await InstanceDetailScreen.leaveDeletedInstance(DemoData.writerID, app: app, router: app.router)
        #expect(app.router.currentInstanceID == DemoData.reviewerID)
        #expect(app.router.path.isEmpty)
    }

    @Test("在领养 sheet 里删掉实例：sheet 栈里它的页面拿掉，sheet 不关")
    func leaveDeletedInSheet() async throws {
        let mock = MockClient(autoReply: false)
        let app = AppModel(client: mock, defaults: nil)
        await app.start()
        app.router.open(.adopt(agentID: DemoData.claudeAgentID))
        app.router.open(.instance(DemoData.reviewerID))
        try await app.client.deleteInstance(DemoData.reviewerID)
        await InstanceDetailScreen.leaveDeletedInstance(DemoData.reviewerID, app: app, router: app.router)
        #expect(app.router.sheet == .adopt(agentID: DemoData.claudeAgentID))
        #expect(app.router.sheetPath.isEmpty)
        #expect(app.router.currentInstanceID == DemoData.writerID)
    }
}
