import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 团队与流水线（WBS 12.7）的界面：团队列表、模板、团队详情、新建 / 编辑团队、流水线编辑器（团队建、改已有计划）、
/// 运行树的停止和等待提示，在浅色中文、深色英文、大字号下都能布局。视图模型的逻辑在 ThinktinKitTests 的 Teams 里测。
@MainActor
@Suite("团队与流水线的界面")
struct TeamsScreensTests {
    static let pipelinePlanID: PlanID = "0192f3a0-0000-7000-8000-00000000c403"

    static let routes: [AppRoute] = [
        .teams, .teamTemplates, .team(DemoData.releaseTeamID), .team("team-gone"),
        .pipelineEditor(planID: nil, teamID: DemoData.releaseTeamID),
        .pipelineEditor(planID: pipelinePlanID, teamID: nil),
        .pipelineEditor(planID: "plan-gone", teamID: nil),
    ]

    private static func client(empty: Bool = false) -> MockClient {
        var state = DemoData.state()
        if empty {
            state.teams = []
            state.teamTemplates = []
        }
        state.plans.append(
            Plan(
                id: pipelinePlanID, instanceID: DemoData.writerID, title: "发版流水线", goal: "收集、审查、写说明。",
                createdAt: Date(),
                steps: [
                    PlanStep(key: "collect", instanceID: DemoData.writerID, prompt: "收集这周的改动"),
                    PlanStep(key: "review", instanceID: DemoData.reviewerID, prompt: "审查", dependsOn: ["collect"]),
                ]))
        return MockClient(state: state, stepDelay: 0)
    }

    @Test("每个页面都能布局（中文浅色、英文深色、大字号）")
    func everyRoute() {
        for route in Self.routes {
            hostAndLayout(TeamsDestination(route: route).previewShell(client: Self.client()))
            hostAndLayout(TeamsDestination(route: route).previewShell(.english, scheme: .dark, client: Self.client()))
            hostAndLayout(
                TeamsDestination(route: route).previewShell(client: Self.client()).dynamicTypeSize(.accessibility3))
        }
        hostAndLayout(TeamsScreen().previewShell(client: Self.client(empty: true)))
    }

    @Test("新建、编辑团队的表单")
    func editor() {
        for teamID in [nil, DemoData.releaseTeamID] as [TeamID?] {
            hostAndLayout(TeamEditorView(teamID: teamID) { _ in }.previewShell(client: Self.client()))
            hostAndLayout(
                TeamEditorView(teamID: teamID) { _ in }.previewShell(.english, scheme: .dark, client: Self.client()))
        }
    }

    @Test("模板的一行：领养中、能写、离线")
    func templateRow() {
        let template = TeamTemplate(
            id: DemoData.contentTemplateID, name: "内容团队",
            members: [
                TemplateMember(agentID: DemoData.claudeAgentID, name: "主笔", role: .lead),
                TemplateMember(agentID: DemoData.hermesAgentID, name: "资料员"),
            ], createdAt: Date())
        for (isBusy, canWrite) in [(false, true), (true, false), (false, false)] {
            let row = TemplateRow(template: template, isBusy: isBusy, canWrite: canWrite, onAdopt: {}, onDelete: {})
            hostAndLayout(row.previewShell())
            hostAndLayout(row.previewShell(.english, scheme: .dark).dynamicTypeSize(.accessibility3))
        }
    }

    @Test("流水线的一步：有问题时标出来")
    func stepCard() async {
        let model = PipelineEditorModel(client: Self.client(), planID: nil, teamID: DemoData.releaseTeamID)
        await model.load()
        _ = await model.save()
        #expect(model.showsProblems)
        for (index, step) in model.steps.enumerated() {
            let card = PipelineStepCard(
                model: model, step: step, index: index, isFirst: index == 0, isLast: index == model.steps.count - 1)
            hostAndLayout(card.previewShell())
            hostAndLayout(card.previewShell(.english, scheme: .dark).dynamicTypeSize(.accessibility3))
        }
    }

    @Test("运行树：等你处理的提示、停止键")
    func runTree() {
        var state = DemoData.state()
        state.runs += [
            Run(
                id: "root", kind: .pipeline, instanceID: DemoData.writerID, source: .plan, prompt: "发版流水线",
                state: .running, createdAt: Date()),
            Run(
                id: "review", instanceID: DemoData.reviewerID, parentRunID: "root", rootRunID: "root",
                stepKey: "review", source: .pipeline, prompt: "审查", state: .waitingApproval, createdAt: Date()),
            Run(
                id: "done", instanceID: DemoData.writerID, parentRunID: "root", rootRunID: "root", stepKey: "collect",
                source: .pipeline, prompt: "收集", state: .succeeded, createdAt: Date()),
        ]
        let client = MockClient(state: state, stepDelay: 0)
        hostAndLayout(RunTreeScreen(runID: "review").previewShell(client: client))
        hostAndLayout(RunTreeScreen(runID: "root").previewShell(.english, scheme: .dark, client: client))
    }
}
