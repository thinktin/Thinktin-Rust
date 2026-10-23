import Foundation
import Testing

@testable import ThinktinKit

// 计划的状态、改动对比、见过的版本、流水线分层、文案和 AI 生成标识的规则表。

@Suite("计划的状态与文案")
struct PlanSupportTests {
    let now = Fixture.now

    @Test("状态：待确认 → 已暂停 → 有下一次 → 规则失效 → 不会再运行")
    func status() {
        let next = now.addingTimeInterval(3600)
        var plan = Plan(
            id: "p", instanceID: "i", title: "t", goal: "g", createdAt: now,
            triggers: [Trigger(id: "t1", schedule: .once(next), nextFireAt: next)])
        #expect(plan.status == .scheduled(next: next))
        plan.isPaused = true
        plan.refreshSchedule()
        #expect(plan.status == .paused)
        plan.awaitingConfirmation = true
        plan.refreshSchedule()
        #expect(plan.status == .awaitingConfirmation)
        #expect(plan.status.needsAttention)

        #expect(PlansFixture.invalidPlan.status == .invalidRule)
        var mixed = PlansFixture.invalidPlan
        mixed.triggers.append(Trigger(id: "t2", schedule: .once(next), nextFireAt: next))
        mixed.refreshSchedule()
        // 还有会触发的规则：按时运行，详情页另外提示有失效的。
        #expect(mixed.status == .scheduled(next: next))
        #expect(mixed.hasInvalidTriggers)

        let idle = Plan(id: "p2", instanceID: "i", title: "t", goal: "g", createdAt: now)
        #expect(idle.status == .idle)
        for s in [PlanStatus.awaitingConfirmation, .paused, .invalidRule, .scheduled(next: next), .idle] {
            #expect(s.localizedName(.chinese) != s.localizedName(.english))
        }
    }

    @Test("和实例有关：属于它，或者流水线的某一步在它上面跑")
    func involves() {
        let plan = PlansFixture.pipelinePlan
        #expect(plan.involves(DemoData.writerID))
        #expect(plan.involves(DemoData.reviewerID))
        #expect(!plan.involves("other"))
        #expect(plan.involvedInstanceIDs == [DemoData.writerID, DemoData.reviewerID])
    }

    @Test("改动对比：按规则内容比触发器，策略分项")
    func diff() {
        let old = PlansFixture.pipelinePlan
        var new = old
        new.title = "新标题"
        new.triggers = [
            Trigger(id: "x1", schedule: .cron(expression: "0 10 * * 1", timeZone: "Asia/Shanghai")),
            Trigger(id: "x2", schedule: .cron(expression: "0 18 * * 5", timeZone: "Asia/Shanghai")),
        ]
        new.policy.preauthorizedTools = ["read", "execute"]
        new.policy.budget.maxTokens = 10_000
        new.catchUp = .skip
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(
            changes == [
                .title(from: "发版流水线", to: "新标题"),
                .triggersAdded([.cron(expression: "0 18 * * 5", timeZone: "Asia/Shanghai")]),
                .preauthorizedTools(from: [], to: ["read", "execute"]),
                .budget(from: old.policy.budget, to: new.policy.budget),
                .catchUp(from: .once, to: .skip),
            ])
        #expect(PlanDiff.changes(from: old, to: old).isEmpty)
        // 只是换了 id（agent 改规则是删了重加）不算改动；顺序不同的工具列表也不算。
        var reordered = old
        reordered.triggers = old.triggers.map {
            Trigger(id: TriggerID("new-" + $0.id.rawValue), schedule: $0.schedule, nextFireAt: $0.nextFireAt)
        }
        #expect(PlanDiff.changes(from: old, to: reordered).isEmpty)
        var removed = old
        removed.triggers = []
        #expect(PlanDiff.changes(from: old, to: removed) == [.triggersRemoved(old.triggers.map(\.schedule))])
        let (added, gone) = PlanDiff.scheduleDifference(
            [.once(now), .once(now)], [.once(now), .once(now.addingTimeInterval(60))])
        #expect(added == [.once(now.addingTimeInterval(60))])
        #expect(gone == [.once(now)])
    }

    @Test("改动的文字")
    func describeChanges() {
        let line = PlansText.describe(.approvalTimeout(from: 3600, to: 86400), language: .chinese)
        #expect(line == PlansText.ChangeLine(label: "审批等多久", before: "1 小时", after: "1 天"))
        let added = PlansText.describe(
            .triggersAdded([.cron(expression: "0 9 * * 1-5", timeZone: "Asia/Shanghai")]), language: .english,
            timeZone: Fixture.shanghai)
        #expect(added.before == nil)
        #expect(added.after == "Weekdays at 09:00")
        let steps = PlansText.describe(
            .steps(from: [], to: [PlanStep(key: "a", instanceID: DemoData.writerID, prompt: "p")]), language: .chinese,
            instanceName: { $0 == DemoData.writerID ? "写作助手" : "?" })
        #expect(steps.before == "没有（单个 agent）")
        #expect(steps.after == "a → 写作助手")
        let tools = PlansText.describe(.preauthorizedTools(from: ["execute", "read"], to: []), language: .chinese)
        #expect(tools.before == "读取文件、运行命令")
        #expect(tools.after == "没有，每次用工具都要审批")
    }

    @Test("见过的版本：只记生效的、不回退，比现在旧的才拿来比")
    @MainActor
    func snapshots() {
        let store = PlanSnapshotStore()
        var plan = PlansFixture.pipelinePlan
        plan.revision = 3
        store.record(plan)
        #expect(store.baseline(for: plan.id, before: 4) == plan)
        #expect(store.baseline(for: plan.id, before: 3) == nil)
        var awaiting = plan
        awaiting.revision = 5
        awaiting.awaitingConfirmation = true
        store.record(awaiting)
        #expect(store.baseline(for: plan.id, before: 5)?.revision == 3)
        var older = plan
        older.revision = 2
        store.record(older)
        #expect(store.baseline(for: plan.id, before: 5)?.revision == 3)
        store.forget(plan.id)
        #expect(store.baseline(for: plan.id, before: 5) == nil)
    }

    @Test("流水线分层：没有依赖的在第一层；成环的放最后")
    func stages() {
        let stages = PipelineLayout.stages(PlansFixture.pipelinePlan.steps)
        #expect(stages.map { $0.map(\.key) } == [["collect"], ["review", "notify"], ["notes"]])
        let cycle = [
            PlanStep(key: "a", instanceID: "i", prompt: "p", dependsOn: ["b"]),
            PlanStep(key: "b", instanceID: "i", prompt: "p", dependsOn: ["a"]),
            PlanStep(key: "c", instanceID: "i", prompt: "p", dependsOn: ["gone"]),
        ]
        #expect(PipelineLayout.stages(cycle).map { $0.map(\.key) } == [["c"], ["a", "b"]])
        #expect(PipelineLayout.stages([]).isEmpty)
    }

    @Test("AI 生成标识的规则表")
    func aiRules() {
        var plan = PlansFixture.pipelinePlan
        #expect(!PlansText.isAIGenerated(.title, in: plan))
        #expect(!PlansText.isAIGenerated(.stepPrompt, in: plan))
        #expect(PlansText.isAIGenerated(.runSummary, in: plan))
        #expect(!PlansText.isAIGenerated(.runError, in: plan))
        #expect(!PlansText.isAIGenerated(.scheduleDescription, in: plan))
        // agent 改了用户的计划、在等确认：按 agent 写的标。
        plan.awaitingConfirmation = true
        #expect(PlansText.isAIGenerated(.title, in: plan))
        #expect(PlansText.isAIGenerated(.goal, in: plan))
        plan.awaitingConfirmation = false
        plan.createdBy = .agent
        #expect(PlansText.isAIGenerated(.goal, in: plan))
        #expect(!PlansText.isAIGenerated(.scheduleDescription, in: plan))
    }

    @Test("规则摘要、下一次、触发器状态")
    func scheduleTexts() {
        let plan = PlansFixture.pipelinePlan
        #expect(PlansText.scheduleSummary(plan, language: .chinese, timeZone: Fixture.shanghai) == "每周一 10:00")
        var two = plan
        two.triggers.append(Trigger(id: "t9", schedule: .cron(expression: "0 9 * * *", timeZone: "Asia/Shanghai")))
        #expect(PlansText.scheduleSummary(two, language: .chinese, timeZone: Fixture.shanghai) == "每周一 10:00 等 2 条规则")
        #expect(
            PlansText.scheduleSummary(two, language: .english, timeZone: Fixture.shanghai)
                == "Every Monday at 10:00 + 1 more")
        var none = plan
        none.triggers = []
        #expect(PlansText.scheduleSummary(none, language: .english) == "No schedule")

        let calendar = Fixture.calendar
        let next = Fixture.date(2026, 10, 23, 9)
        #expect(PlansText.nextFire(next, now: now, language: .chinese, calendar: calendar) == "下次：明天 09:00")
        #expect(PlansText.nextFire(next, now: now, language: .english, calendar: calendar) == "Next: tomorrow 09:00")

        let invalid = PlansFixture.invalidPlan
        #expect(
            PlansText.triggerState(invalid.triggers[0], plan: invalid, now: now, language: .chinese, calendar: calendar)
                == "规则已失效，已停用")
        var paused = plan
        paused.isPaused = true
        #expect(PlansText.triggerState(paused.triggers[0], plan: paused, language: .chinese) == "计划暂停中")
        var awaiting = plan
        awaiting.awaitingConfirmation = true
        #expect(
            PlansText.triggerState(awaiting.triggers[0], plan: awaiting, language: .english)
                == "Starts once you confirm")
        var done = plan
        done.triggers[0].nextFireAt = nil
        #expect(PlansText.triggerState(done.triggers[0], plan: done, language: .chinese) == "不会再触发")
    }

    @Test("策略的文字")
    func policyTexts() {
        let policy = PlanPolicy(
            preauthorizedTools: ["fetch", "read", "custom"], approvalTimeoutSecs: 3600, onApprovalTimeout: .skip,
            budget: RunBudget(maxTokens: 50_000, maxDurationSecs: 1800), dailyTokenLimit: 200_000)
        #expect(PlansText.toolsSummary(policy.preauthorizedTools, language: .chinese) == "读取文件、联网获取、custom")
        #expect(PlansText.approvalSummary(policy, language: .chinese) == "等 1 小时，超时后跳过这一步")
        #expect(PlansText.approvalSummary(policy, language: .english) == "Wait 1h, then skip that step")
        #expect(PlansText.budgetSummary(policy.budget, language: .chinese) == "最多 5 万 token · 最长 30 分 · 步数不限")
        #expect(
            PlansText.budgetSummary(policy.budget, language: .english) == "Up to 50K tokens · up to 30m · no step limit"
        )
        #expect(PlansText.dailyLimitSummary(nil, language: .chinese) == "不限")
        #expect(PlansText.dailyLimitSummary(200_000, language: .chinese) == "每天最多 20 万 token")
        #expect(PlansText.waitSummary(policy, language: .chinese) == "等电脑上线、等补 key 最多 1 天")
        #expect(PlansText.isRiskyTool("execute") && !PlansText.isRiskyTool("read"))
        #expect(PlansText.presets([300, 3600], including: 600) == [300, 600, 3600])
        #expect(PlansText.presets([300, 3600], including: 3600) == [300, 3600])
        for action in ApprovalTimeoutAction.knownCases {
            #expect(PlansText.timeoutActionDetail(action, language: .chinese) != nil)
        }
        for catchUp in CatchUp.knownCases {
            #expect(
                PlansText.catchUpName(catchUp, language: .chinese) != PlansText.catchUpName(catchUp, language: .english)
            )
            #expect(PlansText.catchUpDetail(catchUp, language: .english) != nil)
        }
        #expect(PlansText.toolKinds.allSatisfy { PlansText.toolName($0, language: .chinese) != $0 })
    }
}
