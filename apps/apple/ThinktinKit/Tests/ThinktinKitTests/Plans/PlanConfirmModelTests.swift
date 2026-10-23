import Foundation
import Testing

@testable import ThinktinKit

// agent 建的、改的计划的确认页：新建 / 改了（有旧版本可比、没有）、按版本确认、冲突时重新拉取再给用户看、删除。

@MainActor
@Suite("计划确认")
struct PlanConfirmModelTests {
    @Test("agent 新建的（版本号 2）：说“新建了”，确认后开始运行、记下这个版本")
    func confirmCreated() async throws {
        let mock = PlansFixture.mock()
        let store = PlanSnapshotStore()
        let model = PlanConfirmModel(client: mock, planID: DemoData.agentPlanID, snapshots: store)
        await model.load()
        #expect(model.plan?.revision == 2)
        #expect(model.reviewKind == .created)
        #expect(model.canConfirm)
        #expect(model.outcome == nil)
        #expect(await model.confirm())
        guard case .confirmed(let plan) = model.outcome else {
            Issue.record("should be confirmed")
            return
        }
        #expect(!plan.awaitingConfirmation)
        #expect(mock.state.plans.first { $0.id == DemoData.agentPlanID }?.awaitingConfirmation == false)
        #expect(store.baseline(for: plan.id, before: 3) != nil)
        #expect(!model.canConfirm)
        #expect(!(await model.confirm()))
    }

    @Test("冲突：又被改过，换成新内容并标出改动，再确认新版本")
    func conflict() async throws {
        let mock = PlansFixture.mock()
        let model = PlanConfirmModel(client: mock, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        // 用户看的时候 agent 又改了标题（版本号加了）。
        mock.update { state in
            let i = state.plans.firstIndex { $0.id == DemoData.agentPlanID }!
            state.plans[i].title = "每周依赖和许可证检查"
            state.plans[i].revision = 4
        }
        #expect(!(await model.confirm()))
        #expect(model.plan?.revision == 4)
        #expect(model.plan?.title == "每周依赖和许可证检查")
        #expect(model.conflictChanges == [.title(from: "每周依赖升级检查", to: "每周依赖和许可证检查")])
        #expect(model.isChanged(.title))
        #expect(!model.isChanged(.goal))
        #expect(model.actionError == nil)
        #expect(model.outcome == nil)
        #expect(model.canConfirm)
        #expect(await model.confirm())
        #expect(model.conflictChanges == nil)
    }

    @Test("冲突：已经不用确认了（别的设备上确认过）")
    func alreadyConfirmed() async {
        let mock = PlansFixture.mock()
        let model = PlanConfirmModel(client: mock, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        mock.update { state in
            let i = state.plans.firstIndex { $0.id == DemoData.agentPlanID }!
            state.plans[i].awaitingConfirmation = false
        }
        #expect(!(await model.confirm()))
        guard case .notAwaiting = model.outcome else {
            Issue.record("should be not awaiting")
            return
        }
        #expect(!model.canConfirm)
    }

    @Test("改了、有见过的版本：列出改了什么")
    func updatedWithBaseline() async throws {
        let mock = PlansFixture.mock()
        let store = PlanSnapshotStore()
        let list = PlanListModel(client: mock, snapshots: store)
        await list.load()
        // agent 改了用户的计划：目标、规则。
        let newSchedule = Schedule.cron(expression: "0 8 * * 1-5", timeZone: "Asia/Shanghai")
        mock.update { state in
            let i = state.plans.firstIndex { $0.id == DemoData.digestPlanID }!
            state.plans[i].goal = "每个工作日早上 8 点汇总 GitHub 通知。"
            state.plans[i].triggers = [Trigger(id: "0192f3a0-0000-7000-8000-00000000c499", schedule: newSchedule)]
            state.plans[i].awaitingConfirmation = true
            state.plans[i].isPaused = true
            state.plans[i].revision = 3
        }
        let model = PlanConfirmModel(client: mock, planID: DemoData.digestPlanID, snapshots: store)
        await model.load()
        #expect(model.baseline?.revision == 1)
        guard case .updated(let changes) = model.reviewKind else {
            Issue.record("should list the changes")
            return
        }
        #expect(
            changes == [
                .goal(from: "每个工作日早上汇总 GitHub 通知，只列需要我处理的。", to: "每个工作日早上 8 点汇总 GitHub 通知。"),
                .triggersRemoved([.cron(expression: "0 9 * * 1-5", timeZone: "Asia/Shanghai")]),
                .triggersAdded([newSchedule]),
            ])
        #expect(model.isChanged(.goal) && model.isChanged(.triggers))
        #expect(!model.isChanged(.title) && !model.isChanged(.policy))
        // 标题、目标按 agent 写的标（在等确认）。
        #expect(PlansText.isAIGenerated(.goal, in: model.plan!))
    }

    @Test("改了、没见过旧版本：请用户完整核对")
    func updatedWithoutBaseline() async {
        let mock = PlansFixture.mock { state in
            let i = state.plans.firstIndex { $0.id == DemoData.agentPlanID }!
            state.plans[i].revision = 4
        }
        let model = PlanConfirmModel(client: mock, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        #expect(model.reviewKind == .updatedWithoutBaseline)
        #expect(!model.isChanged(.title))
        for kind in [PlanReviewKind.created, .updated([]), .updatedWithoutBaseline] {
            #expect(
                PlansText.reviewHeadline(kind, language: .chinese) != PlansText.reviewHeadline(kind, language: .english)
            )
            #expect(PlansText.reviewMessage(kind, language: .chinese).contains("确认"))
        }
    }

    @Test("打开的计划本来就不用确认")
    func notAwaiting() async {
        let model = PlanConfirmModel(
            client: PlansFixture.mock(), planID: DemoData.digestPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        guard case .notAwaiting(let plan) = model.outcome else {
            Issue.record("should be not awaiting")
            return
        }
        #expect(plan.id == DemoData.digestPlanID)
        #expect(!model.canConfirm)
    }

    @Test("修改后确认：编辑页保存后按新版本确认")
    func editThenConfirm() async throws {
        let mock = PlansFixture.mock()
        let model = PlanConfirmModel(client: mock, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        let editor = PlanEditorModel(
            client: mock, mode: .edit(DemoData.agentPlanID), plan: model.plan, snapshots: PlanSnapshotStore())
        editor.policy.setTool("read", allowed: true)
        let saved = try #require(await editor.save())
        #expect(saved.awaitingConfirmation)
        #expect(saved.revision == 3)
        model.applyEdit(saved)
        #expect(model.plan?.revision == 3)
        #expect(await model.confirm())
    }

    @Test("删除；计划不在了；确认失败")
    func deleteAndErrors() async {
        let mock = PlansFixture.mock()
        let model = PlanConfirmModel(client: mock, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await model.load()
        mock.failNext(with: .network(message: "offline"))
        #expect(!(await model.confirm()))
        #expect(model.actionError?.isOffline == true)
        model.clearActionError()
        #expect(await model.delete())
        #expect(model.outcome == .deleted)
        #expect(!mock.state.plans.contains { $0.id == DemoData.agentPlanID })
        #expect(!(await model.delete()))

        let missing = PlanConfirmModel(client: mock, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await missing.load()
        #expect(missing.isMissing)
        #expect(!missing.canConfirm)

        // 确认时计划被 agent 取消了。
        let mock2 = PlansFixture.mock()
        let gone = PlanConfirmModel(client: mock2, planID: DemoData.agentPlanID, snapshots: PlanSnapshotStore())
        await gone.load()
        mock2.update { $0.plans.removeAll { $0.id == DemoData.agentPlanID } }
        #expect(!(await gone.confirm()))
        #expect(gone.isMissing)
    }
}
