import Foundation
import Testing

@testable import ThinktinKit

// 计划列表：分组排序、按实例筛选、暂停恢复删除、等确认的不能直接恢复、错误。

@MainActor
@Suite("计划列表")
struct PlanListModelTests {
    @Test("加载：等确认的置顶，按时运行按下一次排，暂停的单独一组；记下生效的版本")
    func sections() async {
        let store = PlanSnapshotStore()
        let model = PlanListModel(client: PlansFixture.mockWithPlans(), snapshots: store)
        await model.load()
        #expect(model.hasLoaded && model.error == nil)
        let s = model.sections
        #expect(s.awaiting.map(\.id) == [DemoData.agentPlanID])
        #expect(s.paused.map(\.id) == [PlansFixture.pausedPlanID])
        // 流水线明天 10:00、通知汇总 21 小时后（演示数据按真实时间算），规则失效的没有下一次排最后。
        #expect(s.active.last?.id == PlansFixture.invalidPlanID)
        #expect(Set(s.active.prefix(2).map(\.id)) == [PlansFixture.pipelinePlanID, DemoData.digestPlanID])
        #expect(model.awaitingCount == 1)
        #expect(!s.isEmpty)
        #expect(store.baseline(for: DemoData.digestPlanID, before: 2) != nil)
        // 等确认的不记。
        #expect(store.baseline(for: DemoData.agentPlanID, before: 99) == nil)
    }

    @Test("按实例筛选：流水线有一步在这个实例上的也算")
    func filter() async {
        let model = PlanListModel(client: PlansFixture.mockWithPlans(), snapshots: PlanSnapshotStore())
        await model.load()
        model.instanceFilter = DemoData.reviewerID
        #expect(
            Set(model.visiblePlans.map(\.id)) == [
                DemoData.agentPlanID, PlansFixture.invalidPlanID, PlansFixture.pipelinePlanID,
            ])
        #expect(model.count(for: DemoData.reviewerID) == 3)
        #expect(model.count(for: DemoData.writerID) == 3)
        #expect(model.count(for: nil) == 5)
        model.instanceFilter = nil
        #expect(model.visiblePlans.count == 5)
        // 筛选按钮：实例列表里的在前，计划里出现、列表里没有的补在后面。
        let instances = PlansFixture.mock().state.instances
        #expect(model.filterInstances(Array(instances.reversed())) == [DemoData.reviewerID, DemoData.writerID])
        #expect(model.filterInstances([]) == [DemoData.writerID, DemoData.reviewerID])
    }

    @Test("暂停、恢复；等确认的不能直接恢复")
    func pauseResume() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PlanListModel(client: mock, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(await model.setPaused(DemoData.digestPlanID, paused: true))
        #expect(model.sections.paused.contains { $0.id == DemoData.digestPlanID })
        #expect(mock.state.plans.first { $0.id == DemoData.digestPlanID }?.isPaused == true)
        #expect(await model.setPaused(PlansFixture.pausedPlanID, paused: false))
        #expect(model.sections.active.contains { $0.id == PlansFixture.pausedPlanID })
        // 等确认的：不发请求。
        #expect(!(await model.setPaused(DemoData.agentPlanID, paused: false)))
        #expect(model.actionError == nil)
        // 不认识的计划。
        #expect(!(await model.setPaused("nope", paused: true)))
    }

    @Test("删除：删掉了从列表里拿掉；已经不在了也算")
    func delete() async {
        let mock = PlansFixture.mockWithPlans()
        let store = PlanSnapshotStore()
        let model = PlanListModel(client: mock, snapshots: store)
        await model.load()
        #expect(await model.delete(PlansFixture.pausedPlanID))
        #expect(!model.plans.contains { $0.id == PlansFixture.pausedPlanID })
        #expect(!mock.state.plans.contains { $0.id == PlansFixture.pausedPlanID })
        #expect(store.baseline(for: PlansFixture.pausedPlanID, before: 99) == nil)
        mock.update { $0.plans.removeAll { $0.id == DemoData.digestPlanID } }
        #expect(await model.delete(DemoData.digestPlanID))
        #expect(!model.plans.contains { $0.id == DemoData.digestPlanID })
    }

    @Test("出错：加载失败留着已有的；操作失败记下错误；暂停时计划不在了从列表拿掉")
    func errors() async {
        let mock = PlansFixture.mockWithPlans()
        let model = PlanListModel(client: mock, snapshots: PlanSnapshotStore())
        await model.load()
        let count = model.plans.count
        mock.failNext(with: .network(message: "offline"))
        await model.load()
        #expect(model.error?.isOffline == true)
        #expect(model.plans.count == count)

        mock.failNext(with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        #expect(!(await model.setPaused(DemoData.digestPlanID, paused: true)))
        #expect(model.actionError?.apiCode == .internal)
        model.clearActionError()
        #expect(model.actionError == nil)

        mock.failNext(with: .api(status: 404, code: .notFound, message: "gone", retryAfterSecs: nil))
        #expect(!(await model.setPaused(DemoData.digestPlanID, paused: true)))
        #expect(!model.plans.contains { $0.id == DemoData.digestPlanID })
        #expect(model.actionError == nil)

        mock.failNext(with: .api(status: 500, code: .internal, message: "boom", retryAfterSecs: nil))
        #expect(!(await model.delete(PlansFixture.pausedPlanID)))
        #expect(model.plans.contains { $0.id == PlansFixture.pausedPlanID })
        #expect(model.actionError != nil)
    }

    @Test("没有计划")
    func empty() async {
        let model = PlanListModel(client: PlansFixture.mock { $0.plans = [] }, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(model.sections.isEmpty)
        #expect(model.awaitingCount == 0)
    }
}
