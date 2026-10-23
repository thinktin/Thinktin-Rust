import Foundation
import Testing

@testable import ThinktinKit

// 新建、编辑计划：本地校验、只带改了的字段、触发器删旧加新、部分保存后重试、策略的数字框。

@MainActor
@Suite("计划编辑")
struct PlanEditorModelTests {
    let now = PlansFixture.date(2026, 10, 22, 10, 0)

    func editor(_ mock: MockClient, _ mode: PlanEditorModel.Mode, plan: Plan? = nil) -> PlanEditorModel {
        let now = self.now
        return PlanEditorModel(
            client: mock, mode: mode, plan: plan, timeZone: PlansFixture.shanghai, now: { now },
            snapshots: PlanSnapshotStore())
    }

    @Test("新建：要选实例、标题、目标、至少一条规则；保存带上策略和补跑方式")
    func create() async throws {
        let mock = PlansFixture.mock()
        let model = editor(mock, .create(instanceID: nil))
        #expect(!model.hasChanges)
        #expect(!model.canSave)
        #expect(
            model.problems == [.noInstance, .title(.empty), .goal(.empty), .noTriggers])
        model.instanceID = DemoData.writerID
        model.title = "  每周周报  "
        model.goal = "每周五整理这周的提交，写成周报。"
        let draft = model.newTriggerDraft()
        #expect(draft.timeZoneID == "Asia/Shanghai")
        model.addTrigger(draft.schedule)
        model.policy.setTool("read", allowed: true)
        model.policy.maxTokens = "50,000"
        model.catchUp = .skip
        #expect(model.hasChanges)
        #expect(model.problems.isEmpty)
        #expect(model.canSave)
        let plan = try #require(await model.save())
        #expect(plan.title == "每周周报")
        #expect(plan.instanceID == DemoData.writerID)
        #expect(plan.policy.preauthorizedTools == ["read"])
        #expect(plan.policy.budget.maxTokens == 50_000)
        #expect(plan.catchUp == .skip)
        #expect(plan.triggers.map(\.schedule) == [.cron(expression: "0 9 * * *", timeZone: "Asia/Shanghai")])
        #expect(model.savedPlan == plan)
        #expect(mock.state.plans.contains { $0.id == plan.id })
    }

    @Test("标题、目标的长度按 Unicode 标量数（去掉首尾空白）")
    func lengths() {
        let model = editor(PlansFixture.mock(), .create(instanceID: DemoData.writerID))
        model.title = String(repeating: "字", count: Plan.maxTitleLength)
        #expect(model.titleProblem == nil)
        #expect(model.titleLength == 100)
        model.title += "多"
        #expect(model.titleProblem == .tooLong(max: 100))
        model.title = "   "
        #expect(model.titleProblem == .empty)
        model.goal = String(repeating: "a", count: Plan.maxGoalLength + 1)
        #expect(model.goalProblem == .tooLong(max: 8000))
        #expect(model.problems.contains(.goal(.tooLong(max: 8000))))
        for problem in [
            PlanFormProblem.noInstance, .title(.empty), .goal(.tooLong(max: 8000)), .noTriggers,
            .tooManyTriggers(max: 10), .policy(.maxDurationOutOfRange),
        ] {
            #expect(problem.message(.chinese) != problem.message(.english))
        }
    }

    @Test("最多 10 条规则")
    func triggerLimit() {
        let model = editor(PlansFixture.mock(), .create(instanceID: DemoData.writerID))
        for i in 0..<12 {
            model.addTrigger(.cron(expression: "0 \(i) * * *", timeZone: "Asia/Shanghai"))
        }
        #expect(model.triggers.count == Plan.maxTriggers)
        #expect(!model.canAddTrigger)
        #expect(model.triggersProblem == nil)
    }

    @Test("编辑：只带改了的字段；没改不能保存")
    func editFields() async throws {
        let mock = PlansFixture.mockWithPlans()
        let model = editor(mock, .edit(DemoData.digestPlanID))
        #expect(model.needsLoad)
        await model.load()
        #expect(!model.needsLoad)
        #expect(model.title == "每日 GitHub 通知汇总")
        #expect(model.policy.maxTokens == "50000")
        #expect(model.triggers.count == 1)
        #expect(model.change.isEmpty)
        #expect(!model.hasChanges && !model.canSave)

        model.goal = "每个工作日早上汇总 GitHub 通知。"
        model.policy.approvalTimeoutSecs = 7200
        #expect(model.change.title == nil)
        #expect(model.change.goal == "每个工作日早上汇总 GitHub 通知。")
        #expect(model.change.policy?.approvalTimeoutSecs == 7200)
        #expect(model.change.catchUp == nil)
        let revision = mock.state.plans.first { $0.id == DemoData.digestPlanID }!.revision
        let saved = try #require(await model.save())
        #expect(saved.goal == "每个工作日早上汇总 GitHub 通知。")
        #expect(saved.policy.approvalTimeoutSecs == 7200)
        #expect(saved.revision == revision + 1)
        #expect(model.change.isEmpty)
    }

    @Test("编辑触发器：改一条 = 删旧加新，删掉的 deleteTrigger，新加的 addTrigger")
    func editTriggers() async throws {
        let mock = PlansFixture.mockWithPlans()
        let plan = mock.state.plans.first { $0.id == DemoData.digestPlanID }!
        let model = editor(mock, .edit(plan.id), plan: plan)
        #expect(!model.needsLoad)
        let original = try #require(model.triggers.first)
        #expect(!original.isNew)
        let drafted = try #require(model.draft(for: original.id))
        #expect(drafted.kind == .weekly)
        #expect(drafted.weekdays == [1, 2, 3, 4, 5])

        // 改成同样的内容：不算改动。
        model.updateTrigger(original.id, to: original.schedule)
        #expect(!model.hasChanges)
        // 改成 08:30：换成一条新加的。
        let changed = Schedule.cron(expression: "30 8 * * 1-5", timeZone: "Asia/Shanghai")
        model.updateTrigger(original.id, to: changed)
        #expect(model.triggers.count == 1)
        #expect(model.triggers[0].isNew)
        #expect(model.hasChanges)
        // 再加一条、又删掉一条新加的。
        model.addTrigger(.cron(expression: "0 18 * * 5", timeZone: "Asia/Shanghai"))
        model.addTrigger(.cron(expression: "0 12 * * *", timeZone: "Asia/Shanghai"))
        model.removeTrigger(model.triggers[2].id)
        let saved = try #require(await model.save())
        #expect(
            saved.triggers.map(\.schedule) == [changed, .cron(expression: "0 18 * * 5", timeZone: "Asia/Shanghai")])
        #expect(!saved.triggers.contains { $0.id == original.triggerID })
        #expect(model.triggers.allSatisfy { !$0.isNew })
    }

    @Test("第一个调用就失败：什么都没存，再保存全部重做")
    func failedSave() async throws {
        let mock = PlansFixture.mockWithPlans()
        let model = editor(mock, .edit(DemoData.digestPlanID))
        await model.load()
        model.goal = "新目标"
        model.addTrigger(.cron(expression: "0 7 * * *", timeZone: "Asia/Shanghai"))
        mock.failNext(with: .api(status: 422, code: .invalid, message: "bad", retryAfterSecs: nil))
        #expect(await model.save() == nil)
        #expect(!model.isPartiallySaved)
        #expect(model.saveError?.apiCode == .invalid)
        #expect(model.hasChanges)
        let saved = try #require(await model.save())
        #expect(saved.goal == "新目标")
        #expect(saved.triggers.count == 2)
        #expect(model.saveError == nil)
        model.clearSaveError()
    }

    @Test("部分保存：updatePlan 成功、addTrigger 失败；重试不再改一次内容")
    func partialRetry() async throws {
        let mock = PlansFixture.mockWithPlans()
        let model = editor(mock, .edit(PlansFixture.invalidPlanID))
        await model.load()
        model.title = "新的提醒"
        // 规则时区认不出：Mock 加触发器时拒绝（invalid），updatePlan 已经成功。
        model.addTrigger(.cron(expression: "0 9 * * 5", timeZone: "Mars/Olympus"))
        #expect(await model.save() == nil)
        #expect(model.isPartiallySaved)
        #expect(model.change.isEmpty)  // 标题已经存上了
        let revision = mock.state.plans.first { $0.id == PlansFixture.invalidPlanID }!.revision
        #expect(mock.state.plans.first { $0.id == PlansFixture.invalidPlanID }?.title == "新的提醒")
        // 换成能用的规则再保存：只加触发器，不再 updatePlan（版本号不变）。
        let bad = try #require(model.triggers.first { $0.isNew })
        model.updateTrigger(bad.id, to: .cron(expression: "0 9 * * 5", timeZone: "Asia/Shanghai"))
        let saved = try #require(await model.save())
        #expect(saved.revision == revision)
        #expect(saved.triggers.count == 2)
        #expect(!model.isPartiallySaved)
    }

    @Test("编辑：计划不在了；拉不到")
    func loadErrors() async {
        let mock = PlansFixture.mockWithPlans()
        let missing = editor(mock, .edit("gone"))
        await missing.load()
        #expect(missing.isMissing)
        #expect(!missing.needsLoad)
        let offline = editor(mock, .edit(DemoData.digestPlanID))
        mock.failNext(with: .network(message: "offline"))
        await offline.load()
        #expect(offline.loadError?.isOffline == true)
        #expect(offline.needsLoad)
        #expect(!offline.canSave)
    }

    @Test("策略的数字框：空的是不限，可以带逗号，要大于 0；超时的范围")
    func policyDraft() {
        var draft = PlanPolicyDraft(PlanPolicy(budget: RunBudget(maxTokens: 1000, maxSteps: 20)))
        #expect(draft.maxTokens == "1000")
        #expect(draft.maxSteps == "20")
        #expect(draft.dailyTokenLimit == "")
        #expect(draft.policy?.budget.maxTokens == 1000)
        draft.maxTokens = "1,200 000"
        #expect(draft.policy?.budget.maxTokens == 1_200_000)
        draft.maxTokens = ""
        #expect(draft.policy?.budget.maxTokens == nil)
        draft.maxSteps = "0"
        #expect(draft.problem(for: .maxSteps) == .notAPositiveNumber(.maxSteps))
        #expect(draft.policy == nil)
        draft.maxSteps = "abc"
        #expect(draft.problems == [.notAPositiveNumber(.maxSteps)])
        draft.maxSteps = "５"  // 全角数字不收
        #expect(draft.problem(for: .maxSteps) != nil)
        draft.maxSteps = ""
        draft.approvalTimeoutSecs = 30
        draft.waitTimeoutSecs = 8 * 86400
        draft.maxDurationSecs = 0
        #expect(draft.problems == [.approvalTimeoutOutOfRange, .maxDurationOutOfRange, .waitTimeoutOutOfRange])
        draft = PlanPolicyDraft()
        draft.setTool("execute", allowed: true)
        draft.setTool("execute", allowed: true)
        #expect(draft.preauthorizedTools == ["execute"])
        #expect(draft.allows("execute"))
        draft.setTool("execute", allowed: false)
        #expect(draft.preauthorizedTools.isEmpty)
        draft.preauthorizedTools = (0...32).map { "k\($0)" }
        #expect(draft.problems == [.tooManyTools(max: 32)])
        #expect(PlanPolicyDraft().policy == PlanPolicy())
        for problem in [
            PlanPolicyProblem.notAPositiveNumber(.maxTokens), .approvalTimeoutOutOfRange, .waitTimeoutOutOfRange,
            .maxDurationOutOfRange, .tooManyTools(max: 32),
        ] {
            #expect(problem.message(.chinese) != problem.message(.english))
        }
    }
}
