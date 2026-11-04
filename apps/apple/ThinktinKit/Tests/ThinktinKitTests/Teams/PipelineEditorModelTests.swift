import Foundation
import Testing

@testable import ThinktinKit

@MainActor
@Suite("流水线编辑器")
struct PipelineEditorModelTests {
    @Test("用团队建：成员各一步、负责人汇总，挂在负责人上，标题是团队名")
    func fromTeam() async throws {
        let mock = TeamsFixture.mock()
        let model = PipelineEditorModel(client: mock, planID: nil, teamID: DemoData.releaseTeamID)
        await model.load()
        #expect(model.hasLoaded)
        #expect(!model.isEditing)
        #expect(model.title == "发版小组")
        #expect(model.hostInstanceID == DemoData.reviewerID)
        #expect(model.steps.map(\.key) == ["step1", "summary"])
        #expect(model.steps.map(\.instanceID) == [DemoData.writerID, DemoData.reviewerID])
        #expect(model.steps[1].dependsOn == ["step1"])
        #expect(!model.hasChanges)
        model.setKey(model.steps[0].id, "collect")
        #expect(model.hasChanges)
        model.setKey(model.steps[0].id, "step1")
        #expect(!model.hasChanges)

        // 提示词、目标都空着：点保存只标出问题，不发请求。
        #expect(await model.save() == nil)
        #expect(model.showsProblems)
        #expect(model.goalProblem == .empty)
        let first = model.steps[0].id
        #expect(model.problems(of: first) == [.emptyPrompt(stepID: first)])

        model.goal = "发一个版本"
        model.setPrompt(first, "收集这周合进来的改动")
        model.setPrompt(model.steps[1].id, "汇总成发版说明")
        let plan = try #require(await model.save())
        #expect(plan.instanceID == DemoData.reviewerID)
        #expect(plan.title == "发版小组")
        #expect(plan.triggers.isEmpty)
        #expect(plan.steps.map(\.key) == ["step1", "summary"])
        #expect(plan.steps[0].prompt == "收集这周合进来的改动")
        #expect(mock.state.plans.contains { $0.id == plan.id })
    }

    @Test("改已有计划的步骤：改键名依赖跟着改，删一步、挪一步，保存只发步骤")
    func edit() async throws {
        let mock = PlansFixture.mockWithPlans()
        let model = PipelineEditorModel(client: mock, planID: PlansFixture.pipelinePlanID, teamID: nil)
        await model.load()
        #expect(model.isEditing)
        #expect(model.plan?.title == "发版流水线")
        #expect(model.steps.map(\.key) == ["collect", "review", "notes", "notify"])
        #expect(!model.hasChanges)

        let collect = model.steps[0].id
        model.setKey(collect, "Gather It")
        #expect(model.steps[0].key == "gatherit")
        #expect(model.steps[1].dependsOn == ["gatherit"])
        #expect(model.steps[3].dependsOn == ["gatherit"])
        #expect(model.hasChanges)

        model.removeStep(model.steps[3].id)
        model.moveStep(model.steps[2].id, by: -1)
        #expect(model.steps.map(\.key) == ["gatherit", "notes", "review"])

        let saved = try #require(await model.save())
        #expect(saved.steps.map(\.key) == ["gatherit", "notes", "review"])
        #expect(saved.title == "发版流水线")
        #expect(saved.triggers.count == 1)
        #expect(!model.hasChanges)
        let stored = try #require(mock.state.plans.first { $0.id == PlansFixture.pipelinePlanID })
        #expect(stored.steps.map(\.key) == ["gatherit", "notes", "review"])
    }

    @Test("依赖成环：整体的问题，保存不发请求")
    func cycle() async throws {
        let mock = PlansFixture.mockWithPlans()
        let model = PipelineEditorModel(client: mock, planID: PlansFixture.pipelinePlanID, teamID: nil)
        await model.load()
        model.toggleDependency(model.steps[0].id, on: "notes")
        #expect(await model.save() == nil)
        #expect(model.generalProblems == [.cycle])
        // 再点一下取消依赖就好了。
        model.toggleDependency(model.steps[0].id, on: "notes")
        #expect(model.stepProblems.isEmpty)
    }

    @Test("加一步：键名接着编，实例跟上一步；最多 20 步")
    func add() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PipelineEditorModel(client: mock, planID: PlansFixture.pipelinePlanID, teamID: nil)
        await model.load()
        model.addStep()
        let added = model.steps[4]
        #expect(added.key == "step1")
        #expect(added.instanceID == DemoData.writerID)
        #expect(added.prompt.isEmpty)
        #expect(Set(model.steps.map(\.id)).count == 5)
        while model.canAddStep { model.addStep() }
        #expect(model.steps.count == PipelineRules.maxSteps)
        model.addStep()
        #expect(model.steps.count == PipelineRules.maxSteps)
    }

    @Test("选的实例删掉了：标在那一步上；换一个就好")
    func deletedInstance() async throws {
        let mock = PlansFixture.mockWithPlans()
        mock.update { state in
            if let i = state.instances.firstIndex(where: { $0.id == DemoData.reviewerID }) {
                state.instances[i].state = .deleted
            }
        }
        let model = PipelineEditorModel(client: mock, planID: PlansFixture.pipelinePlanID, teamID: nil)
        await model.load()
        #expect(model.instances.map(\.id) == [DemoData.writerID])
        let review = model.steps[1].id
        #expect(model.stepProblems.contains(.deletedInstance(stepID: review)))
        model.setInstance(review, DemoData.writerID)
        #expect(model.stepProblems.isEmpty)
    }

    @Test("找不到计划；拉不到时可以重试")
    func loading() async {
        let missing = PipelineEditorModel(client: PlansFixture.mockWithPlans(), planID: "nope", teamID: nil)
        await missing.load()
        #expect(missing.isMissing)

        let mock = PlansFixture.mockWithPlans()
        let model = PipelineEditorModel(client: mock, planID: PlansFixture.pipelinePlanID, teamID: nil)
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(!model.hasLoaded)
        #expect(model.error?.isOffline == true)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.steps.count == 4)
    }

    @Test("保存失败：记下错误，可以清掉")
    func saveFailure() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PipelineEditorModel(client: mock, planID: PlansFixture.pipelinePlanID, teamID: nil)
        await model.load()
        model.setPrompt(model.steps[0].id, "换个说法")
        mock.failNext(with: .api(status: 422, code: .invalid, message: "bad", retryAfterSecs: nil))
        #expect(await model.save() == nil)
        #expect(model.saveError != nil)
        model.clearSaveError()
        #expect(model.saveError == nil)
    }
}
