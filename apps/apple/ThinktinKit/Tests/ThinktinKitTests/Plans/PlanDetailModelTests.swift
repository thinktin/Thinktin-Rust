import Foundation
import Testing

@testable import ThinktinKit

// 计划详情：加载、运行历史翻页、暂停恢复（等确认的不能直接恢复）、删除、修改失效的规则。

@MainActor
@Suite("计划详情")
struct PlanDetailModelTests {
    @Test("加载：计划和运行历史（只要这个计划的根运行）")
    func load() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PlanDetailModel(client: mock, planID: DemoData.digestPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(model.hasLoaded && model.error == nil && !model.isMissing)
        #expect(model.plan?.title == "每日 GitHub 通知汇总")
        #expect(model.runs.map(\.id) == [DemoData.digestRunID])
        #expect(model.runsLoaded && !model.hasMoreRuns)
        #expect(model.canPause && !model.canResume)
        #expect(model.invalidTriggers.isEmpty)
        #expect(model.stages.isEmpty)
    }

    @Test("先显示传进来的计划；传错的不用")
    func seeded() {
        let mock = PlansFixture.mockWithPlans()
        let plan = PlansFixture.pausedPlan
        #expect(PlanDetailModel(client: mock, planID: plan.id, plan: plan).plan == plan)
        #expect(PlanDetailModel(client: mock, planID: DemoData.digestPlanID, plan: plan).plan == nil)
    }

    @Test("运行历史按 before 往下翻，满一页才有下一页")
    func paging() async {
        let runs = PlansFixture.planRuns(PlansFixture.pipelinePlanID, count: 25)
        let mock = PlansFixture.mock {
            $0.plans.append(PlansFixture.pipelinePlan)
            $0.runs += runs
        }
        let model = PlanDetailModel(client: mock, planID: PlansFixture.pipelinePlanID, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(model.runs.count == PlanDetailModel.runsPageSize)
        #expect(model.hasMoreRuns)
        await model.loadMoreRuns()
        #expect(model.runs.count == 25)
        #expect(Set(model.runs.map(\.id)).count == 25)
        #expect(!model.hasMoreRuns)
        await model.loadMoreRuns()
        #expect(model.runs.count == 25)
        #expect(model.stages.map { $0.map(\.key) } == [["collect"], ["review", "notify"], ["notes"]])
    }

    @Test("暂停、恢复；等确认的不能直接恢复，也不能暂停")
    func pauseResume() async {
        let mock = PlansFixture.mockWithPlans()
        let paused = PlanDetailModel(client: mock, planID: PlansFixture.pausedPlanID, snapshots: PlanSnapshotStore())
        await paused.load()
        #expect(paused.canResume)
        #expect(await paused.setPaused(false))
        #expect(paused.plan?.isPaused == false)
        #expect(await paused.setPaused(true))
        #expect(paused.plan?.isPaused == true)

        let awaiting = PlanDetailModel(client: mock, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await awaiting.load()
        #expect(!awaiting.canResume && !awaiting.canPause)
        #expect(!(await awaiting.setPaused(false)))
        #expect(!(await awaiting.setPaused(true)))
    }

    @Test("删除；已经不在了也算删掉了")
    func delete() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PlanDetailModel(client: mock, planID: PlansFixture.pausedPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(await model.delete())
        #expect(model.isDeleted)
        #expect(!mock.state.plans.contains { $0.id == PlansFixture.pausedPlanID })
        #expect(!(await model.delete()))

        let gone = PlanDetailModel(client: mock, planID: PlansFixture.invalidPlanID, snapshots: PlanSnapshotStore())
        await gone.load()
        mock.update { $0.plans.removeAll { $0.id == PlansFixture.invalidPlanID } }
        #expect(await gone.delete())
    }

    @Test("修改失效的规则：先加新的再删旧的，规则恢复正常")
    func replaceInvalid() async throws {
        let mock = PlansFixture.mockWithPlans()
        let model = PlanDetailModel(client: mock, planID: PlansFixture.invalidPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(model.plan?.status == .invalidRule)
        #expect(model.invalidTriggers.map(\.id) == [PlansFixture.invalidTriggerID])
        let schedule = Schedule.cron(expression: "0 9 * * 5", timeZone: "Asia/Shanghai")
        #expect(await model.replaceTrigger(PlansFixture.invalidTriggerID, with: schedule))
        let plan = try #require(model.plan)
        #expect(plan.triggers.map(\.schedule) == [schedule])
        #expect(!plan.hasInvalidTriggers)
        #expect(model.invalidTriggers.isEmpty)
    }

    @Test("修改规则：满 10 条时先删后加；加失败时旧的还在")
    func replaceOrder() async throws {
        let base = PlansFixture.invalidPlan
        var full = base
        for i in 1..<Plan.maxTriggers {
            full.triggers.append(
                Trigger(id: TriggerID("t-\(i)"), schedule: .cron(expression: "0 \(i) * * *", timeZone: "Asia/Shanghai"))
            )
        }
        let mock = PlansFixture.mock { $0.plans.append(full) }
        let model = PlanDetailModel(client: mock, planID: base.id, snapshots: PlanSnapshotStore())
        await model.load()
        let schedule = Schedule.cron(expression: "0 9 * * 5", timeZone: "Asia/Shanghai")
        #expect(await model.replaceTrigger(PlansFixture.invalidTriggerID, with: schedule))
        #expect(model.plan?.triggers.count == Plan.maxTriggers)
        #expect(model.plan?.triggers.contains { $0.id == PlansFixture.invalidTriggerID } == false)

        // 没满：加失败了旧的还在。
        let mock2 = PlansFixture.mockWithPlans()
        let model2 = PlanDetailModel(client: mock2, planID: base.id, snapshots: PlanSnapshotStore())
        await model2.load()
        mock2.failNext(with: .api(status: 422, code: .invalid, message: "bad", retryAfterSecs: nil))
        #expect(!(await model2.replaceTrigger(PlansFixture.invalidTriggerID, with: schedule)))
        #expect(model2.actionError?.apiCode == .invalid)
        #expect(model2.plan?.triggers.map(\.id) == [PlansFixture.invalidTriggerID])
    }

    @Test("加、删触发规则")
    func addDelete() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PlanDetailModel(client: mock, planID: DemoData.digestPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        let at = Date().addingTimeInterval(7200)
        #expect(await model.addTrigger(.once(at)))
        #expect(model.plan?.triggers.count == 2)
        let added = model.plan?.triggers.last?.id
        #expect(await model.deleteTrigger(added!))
        #expect(model.plan?.triggers.count == 1)
    }

    @Test("计划不在了；拉不到时保留已有的")
    func missingAndErrors() async {
        let mock = PlansFixture.mockWithPlans()
        let missing = PlanDetailModel(client: mock, planID: "gone", snapshots: PlanSnapshotStore())
        await missing.load()
        #expect(missing.isMissing)
        #expect(missing.error == nil)
        #expect(missing.runs.isEmpty)

        let model = PlanDetailModel(
            client: mock, planID: DemoData.digestPlanID, plan: mock.state.plans[0], snapshots: PlanSnapshotStore())
        mock.failNext(with: .network(message: "offline"))
        await model.reloadPlan()
        #expect(model.error?.isOffline == true)
        #expect(model.plan != nil)

        mock.failNext(with: .network(message: "offline"))
        await model.reloadRuns()
        #expect(model.runsError?.isOffline == true)

        // 操作时计划不在了。
        mock.update { $0.plans.removeAll { $0.id == DemoData.digestPlanID } }
        #expect(!(await model.setPaused(true)))
        #expect(model.isMissing)
    }
}
