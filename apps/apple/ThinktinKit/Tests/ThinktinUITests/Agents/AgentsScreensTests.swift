import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// Agent 目录与领养（WBS 12.3）的界面：每个页面在浅色中文、深色英文、大字号下都能布局，领养表单、删除确认页、
/// 领养后和删除后的跳转。视图模型的逻辑在 ThinktinKitTests 的 Agents 里测。
@MainActor
@Suite("Agent 目录与领养的界面")
struct AgentsScreensTests {
    static let routes: [AppRoute] = [
        .agentCatalog, .agent(DemoData.claudeAgentID), .agent(DemoData.codexAgentID), .agent("retired"),
        .instance(DemoData.writerID), .instance(DemoData.reviewerID), .instance("gone"),
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

    @Test("领养表单：Claude（两种接入方式、许可说明）和 Codex")
    func adoptionForm() {
        hostAndLayout(
            AdoptAgentSheet(agent: DemoData.agents[0], existingNames: ["写作助手"], client: MockClient(autoReply: false)) {
                _ in
            }
            .previewShell())
        hostAndLayout(
            AdoptAgentSheet(agent: DemoData.agents[1], existingNames: [], client: MockClient(autoReply: false)) { _ in }
                .previewShell(.english, scheme: .dark))
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
        #expect(impact.breaksPipelines)
        renderInBothAppearances(InstanceDeletionImpactView(impact: impact))
        renderInBothAppearances(InstanceDeletionImpactView(impact: InstanceDeletionImpact(instanceID: "lonely")))
    }

    @Test("领养后去配路由：先刷新实例列表，返回栈是“新实例的对话 → 路由页”")
    func adoptionExitRoutes() async throws {
        let mock = MockClient(autoReply: false)
        let app = AppModel(client: mock, defaults: nil)
        await app.start()
        let instance = try await app.client.adopt(agentID: DemoData.hermesAgentID, name: "资料员", harness: nil)
        await AdoptionExit.configureRoutes(instance.id).perform(app: app, router: app.router)
        #expect(app.instances.contains { $0.id == instance.id })
        #expect(app.router.currentInstanceID == instance.id)
        #expect(app.router.path == [.modelRoutes(instance.id)])
        #expect(app.router.sheet == nil)
    }

    @Test("领养后先加 key：停在路由页，上面弹添加 key；稍后再配就去新实例的对话")
    func adoptionExitOthers() async throws {
        let mock = MockClient(autoReply: false)
        let app = AppModel(client: mock, defaults: nil)
        await app.start()
        let first = try await app.client.adopt(agentID: DemoData.codexAgentID, name: "校对", harness: nil)
        await AdoptionExit.addCredential(first.id).perform(app: app, router: app.router)
        #expect(app.router.path == [.modelRoutes(first.id)])
        #expect(app.router.sheet == .addCredential)

        let second = try await app.client.adopt(agentID: DemoData.claudeAgentID, name: "主笔", harness: "cli")
        await AdoptionExit.openConversation(second.id).perform(app: app, router: app.router)
        #expect(app.router.currentInstanceID == second.id)
        #expect(app.router.path.isEmpty)
        #expect(app.router.sheet == nil)

        // 不跳：什么都不动。
        app.router.open(.agentCatalog)
        await AdoptionExit.stay.perform(app: app, router: app.router)
        #expect(app.router.path == [.agentCatalog])
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

    @Test("删掉当前实例：应用框架换到别的实例、回到根")
    func leaveDeletedCurrent() async throws {
        let mock = MockClient(autoReply: false)
        let app = AppModel(client: mock, defaults: nil)
        await app.start()
        app.router.open(.instance(DemoData.writerID))
        try await app.client.deleteInstance(DemoData.writerID)
        await InstanceDetailScreen.leaveDeletedInstance(DemoData.writerID, app: app, router: app.router)
        #expect(app.router.currentInstanceID == DemoData.reviewerID)
        #expect(app.router.path.isEmpty)
    }
}
