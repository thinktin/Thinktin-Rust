import Foundation
import Testing

@testable import ThinktinKit

// 删除实例：先列出受影响的别的流水线（11.9：步骤留着，计划停下来等改步骤）和团队成员身份，二次确认后再删。

@MainActor
@Suite("删除实例")
struct InstanceDeletionTests {
    @Test("算影响：在它上面的步骤、删除后流水线暂停、团队成员身份、没结束的运行")
    func compute() {
        let plans = [AgentsFixture.pipelinePlan, DemoData.state().plans[1]]
        let teams =
            DemoData.state().teams + [
                Team(
                    id: "solo", name: "独行", members: [TeamMember(instanceID: DemoData.reviewerID, role: .lead)],
                    createdAt: Fixture.now)
            ]
        let runs = [
            Fixture.run("r1", state: .running), Fixture.run("r2", state: .waitingApproval),
            Fixture.run("r3", state: .succeeded),
        ].map { run -> Run in
            var r = run
            r.instanceID = DemoData.reviewerID
            return r
        }
        let impact = InstanceDeletionImpact.compute(
            instanceID: DemoData.reviewerID, plans: plans, teams: teams, runs: runs, artifactCount: 2)
        #expect(impact.ownPlans.map(\.id) == [DemoData.agentPlanID])
        #expect(impact.pipelines.count == 1)
        let pipeline = impact.pipelines[0]
        #expect(pipeline.id == AgentsFixture.pipelinePlanID)
        #expect(pipeline.stepsOnInstance.map(\.key) == ["review"])
        #expect(pipeline.effect == .paused && pipeline.willPause)
        #expect(impact.pipelinesToPause.map(\.id) == [AgentsFixture.pipelinePlanID])
        #expect(impact.teams.map(\.teamName) == ["发版小组", "独行"])
        #expect(impact.teams.map(\.isLead) == [true, true])
        #expect(impact.teams.map(\.remainingMembers) == [1, 0])
        #expect(impact.activeRuns == 2)
        #expect(impact.artifactCount == 2)
        #expect(impact.hasCascade)
        #expect(!impact.isIncomplete)
    }

    @Test("没有级联：只有自己的计划")
    func noCascade() {
        let impact = InstanceDeletionImpact.compute(
            instanceID: "lonely", plans: DemoData.state().plans, teams: DemoData.state().teams, runs: [],
            artifactCount: nil)
        #expect(impact.ownPlans.isEmpty)
        #expect(!impact.hasCascade)
        #expect(impact.pipelinesToPause.isEmpty)
        #expect(impact.activeRuns == 0)
        #expect(impact.artifactCount == nil)
    }

    @Test("已经暂停、在等确认的流水线：服务端不改状态（只暂停正在生效的），但同样要先改步骤")
    func pausedAndAwaitingPipelines() {
        var paused = AgentsFixture.pipelinePlan
        paused.isPaused = true
        var awaiting = AgentsFixture.pipelinePlan
        awaiting.id = "awaiting"
        awaiting.awaitingConfirmation = true
        let impact = InstanceDeletionImpact.compute(
            instanceID: DemoData.reviewerID, plans: [paused, awaiting], teams: [], runs: [], artifactCount: 0)
        #expect(impact.pipelines.map(\.effect) == [.stillPaused, .confirmationBlocked])
        #expect(impact.pipelines.allSatisfy { $0.stepsOnInstance.map(\.key) == ["review"] })
        #expect(impact.pipelinesToPause.isEmpty)
        #expect(impact.hasCascade)
    }

    @Test("影响的说明：中英文都有，说清楚要先改步骤")
    func effectMessages() {
        typealias Effect = InstanceDeletionImpact.PipelineImpact.Effect
        #expect(Effect.paused.message(.chinese) == "删除后这条流水线会暂停，把这些步骤改到别的实例上才能恢复。")
        #expect(
            Effect.paused.message(.english)
                == "This pipeline will be paused. Move these steps to another instance to resume it.")
        for effect in [Effect.paused, .stillPaused, .confirmationBlocked] {
            #expect(effect.message(.chinese).contains("改到别的实例上"))
            #expect(effect.message(.english).contains("Move these steps to another instance"))
        }
        #expect(Effect.confirmationBlocked.message(.chinese).contains("确认"))
    }

    @Test("删除之后和 Mock 一致：步骤留着，正在生效的流水线暂停，恢复报 409")
    func deletionMatchesMock() async throws {
        let mock = AgentsFixture.mockWithPipeline()
        let result = try #require(await InstanceDeletionImpact.check(instanceID: DemoData.reviewerID, client: mock))
        #expect(result.impact.pipelinesToPause.map(\.id) == [AgentsFixture.pipelinePlanID])
        try await mock.deleteInstance(DemoData.reviewerID)
        let plan = try await mock.getPlan(AgentsFixture.pipelinePlanID)
        #expect(plan.isPaused)
        #expect(plan.steps.map(\.key) == ["collect", "review", "notes", "notify"], "步骤留着")
        await #expect(throws: ClientError.self) {
            _ = try await mock.setPlanPaused(AgentsFixture.pipelinePlanID, paused: false)
        }
    }

    @Test("查影响：别的计划要拉详情才看得到步骤")
    func checkReviewer() async throws {
        let mock = AgentsFixture.mockWithPipeline()
        let result = try #require(await InstanceDeletionImpact.check(instanceID: DemoData.reviewerID, client: mock))
        #expect(result.error == nil)
        let impact = result.impact
        #expect(!impact.isIncomplete)
        #expect(impact.ownPlans.map(\.id) == [DemoData.agentPlanID])
        #expect(impact.pipelines.map(\.id) == [AgentsFixture.pipelinePlanID])
        #expect(impact.pipelines.first?.stepsOnInstance.map(\.key) == ["review"])
        #expect(impact.teams.map(\.teamID) == [DemoData.releaseTeamID])
        #expect(impact.teams.first?.isLead == true)
        // npm 发布还在跑；PR 检查已经失败了。
        #expect(impact.activeRuns == 1)
        #expect(impact.artifactCount == 0)
    }

    @Test("查影响：流水线是这个实例自己的计划时，算进一起删掉的计划")
    func checkWriter() async throws {
        let mock = AgentsFixture.mockWithPipeline()
        let result = try #require(await InstanceDeletionImpact.check(instanceID: DemoData.writerID, client: mock))
        let impact = result.impact
        #expect(Set(impact.ownPlans.map(\.id)) == [DemoData.digestPlanID, AgentsFixture.pipelinePlanID])
        #expect(impact.pipelines.isEmpty)
        #expect(impact.teams.first?.isLead == false)
        #expect(impact.activeRuns == 1)
        #expect(impact.artifactCount == 1)
    }

    @Test("计划拉不到：标成没查全，带上错误")
    func checkIncomplete() async throws {
        let mock = AgentsFixture.mockWithPipeline()
        mock.failNext(with: .network(message: "offline"))
        let result = try #require(await InstanceDeletionImpact.check(instanceID: DemoData.reviewerID, client: mock))
        #expect(result.impact.isIncomplete)
        #expect(result.error?.isOffline == true)
        #expect(result.impact.pipelines.isEmpty)
        // 团队照样查到了。
        #expect(result.impact.teams.count == 1)
    }

    @Test("实例详情：查影响、删除、实例从 Mock 里没了")
    func deleteFromDetail() async {
        let mock = AgentsFixture.mockWithPipeline()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.reviewerID)
        await model.load()
        await model.prepareDeletion()
        #expect(!model.isCheckingImpact)
        #expect(model.impactError == nil)
        #expect(model.deletionImpact?.hasCascade == true)
        #expect(await model.delete())
        #expect(model.isDeleted)
        #expect(!mock.state.instances.contains { $0.id == DemoData.reviewerID })
        // 删过了，不再删。
        #expect(!(await model.delete()))
    }

    @Test("删除失败：记下错误；别处已经删了也算删掉了")
    func deleteFails() async {
        let mock = AgentsFixture.mock()
        let model = InstanceDetailModel(client: mock, instanceID: DemoData.writerID)
        mock.failNext(with: .api(status: 503, code: .unavailable, message: "busy", retryAfterSecs: 5))
        #expect(!(await model.delete()))
        #expect(model.deleteError?.retryAfter == 5)
        #expect(!model.isDeleted)

        let gone = InstanceDetailModel(client: mock, instanceID: "gone")
        #expect(await gone.delete())
        #expect(gone.isDeleted)
        #expect(gone.deleteError == nil)
    }
}
