import Foundation
import Testing

@testable import ThinktinKit

// 11.9：删除实例时，别的实例的流水线有一步在它上面的被暂停，恢复、确认报 409，要先改步骤。计划详情、确认页认出这个
// 原因（PlanBlockedSteps），说要先改步骤，不说“内容被改过了”。

@MainActor
@Suite("计划：步骤在已删除的实例上（11.9）")
struct PlanBlockedStepsTests {
    /// 写作助手上的流水线（第二步在代码审查上），删掉代码审查之后。
    private func mockAfterDeletingReviewer(awaiting: Bool = false) async throws -> MockClient {
        let mock = PlansFixture.mock { state in
            var plan = PlansFixture.pipelinePlan
            if awaiting {
                plan.createdBy = .agent
                plan.awaitingConfirmation = true
                plan.revision = 2
            }
            state.plans.append(plan)
        }
        try await mock.deleteInstance(DemoData.reviewerID)
        return mock
    }

    @Test("找步骤：不在现有实例里的；说明中英文都说要先改步骤")
    func stepsAndMessage() {
        let plan = PlansFixture.pipelinePlan
        let steps = PlanBlockedSteps.steps(in: plan, liveInstances: [DemoData.writerID])
        #expect(steps.map(\.key) == ["review"])
        #expect(PlanBlockedSteps.steps(in: plan, liveInstances: [DemoData.writerID, DemoData.reviewerID]).isEmpty)
        #expect(PlanBlockedSteps.steps(in: PlansFixture.pausedPlan, liveInstances: []).isEmpty, "不是流水线")
        #expect(
            PlanBlockedSteps.message(steps, confirming: false, language: .chinese)
                == "步骤 review 所在的实例已经删除了，这条流水线暂停着，把这些步骤改到别的实例上才能恢复。")
        #expect(PlanBlockedSteps.message(steps, confirming: true, language: .chinese).contains("确认之前"))
        #expect(PlanBlockedSteps.message(steps, confirming: true, language: .english).hasSuffix("before confirming."))
        #expect(PlanBlockedSteps.message(steps, confirming: false, language: .english).contains("to resume it"))
    }

    @Test("计划详情：恢复报 409，认出是步骤在已删除的实例上，不显示“内容被改过了”；改了步骤以后能恢复")
    func detailResume() async throws {
        let mock = try await mockAfterDeletingReviewer()
        let model = PlanDetailModel(client: mock, planID: PlansFixture.pipelinePlanID, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(model.plan?.isPaused == true && model.canResume)
        #expect(!(await model.setPaused(false)))
        #expect(model.blockedSteps.map(\.key) == ["review"])
        #expect(model.actionError == nil)
        #expect(model.plan?.isPaused == true)

        _ = try await mock.updatePlan(
            PlansFixture.pipelinePlanID,
            change: PlanChange(steps: [PlanStep(key: "collect", instanceID: DemoData.writerID, prompt: "收集")]))
        await model.reloadPlan()
        #expect(model.blockedSteps.isEmpty, "换了步骤：不再挡着")
        #expect(await model.setPaused(false))
        #expect(model.plan?.isPaused == false)
    }

    @Test("计划详情：别的冲突照常显示错误")
    func detailOtherConflict() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PlanDetailModel(client: mock, planID: PlansFixture.pausedPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        mock.failNext(with: .api(status: 409, code: .conflict, message: "busy", retryAfterSecs: nil))
        #expect(!(await model.setPaused(false)))
        #expect(model.actionError?.isConflict == true)
        #expect(model.blockedSteps.isEmpty)
    }

    @Test("确认页：确认报 409、重新拉到的还是同一个版本，认出是步骤在已删除的实例上，不标“刚才又改了”")
    func confirmBlocked() async throws {
        let mock = try await mockAfterDeletingReviewer(awaiting: true)
        let model = PlanConfirmModel(client: mock, planID: PlansFixture.pipelinePlanID, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(model.canConfirm)
        #expect(!(await model.confirm()))
        #expect(model.blockedSteps.map(\.key) == ["review"])
        #expect(model.conflictChanges == nil)
        #expect(model.outcome == nil && model.actionError == nil)

        // 改了步骤（版本号加一），按新版本确认就行。
        let changed = try await mock.updatePlan(
            PlansFixture.pipelinePlanID,
            change: PlanChange(steps: [PlanStep(key: "collect", instanceID: DemoData.writerID, prompt: "收集")]))
        model.applyEdit(changed)
        #expect(model.blockedSteps.isEmpty)
        #expect(await model.confirm())
    }
}
