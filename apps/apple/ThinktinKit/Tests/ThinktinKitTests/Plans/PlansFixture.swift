import Foundation
import Testing

@testable import ThinktinKit

// 计划管理（12.6）测试共用的数据。名字都放在 `PlansFixture` 里，不和别的功能的测试工具重名。

enum PlansFixture {
    /// 演示数据上的 Mock：不自动回答、不等待。`edit` 可以先改一下状态。
    static func mock(_ edit: (inout MockState) -> Void = { _ in }) -> MockClient {
        var state = DemoData.state()
        edit(&state)
        return MockClient(state: state, stepDelay: 0, autoReply: false)
    }

    static let shanghai = Fixture.shanghai
    static let newYork = TimeZone(identifier: "America/New_York")!

    /// 北京时间的某个时刻。
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Fixture.date(year, month, day, hour, minute)
    }

    /// 某个时区的某个时刻。
    static func date(
        in zone: TimeZone, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 写作助手上一个暂停了的计划。
    static let pausedPlanID: PlanID = "0192f3a0-0000-7000-8000-00000000c401"
    /// 代码审查上一个规则失效了的计划（唯一的触发器被后台停用）。
    static let invalidPlanID: PlanID = "0192f3a0-0000-7000-8000-00000000c402"
    static let invalidTriggerID: TriggerID = "0192f3a0-0000-7000-8000-00000000c412"
    /// 写作助手上的流水线：第二步在代码审查上跑。
    static let pipelinePlanID: PlanID = "0192f3a0-0000-7000-8000-00000000c403"

    static var pausedPlan: Plan {
        Plan(
            id: pausedPlanID, instanceID: DemoData.writerID, title: "周末读书笔记", goal: "整理这周读的书。", isPaused: true,
            createdAt: Fixture.now.addingTimeInterval(-86400),
            triggers: [
                Trigger(
                    id: "0192f3a0-0000-7000-8000-00000000c411",
                    schedule: .cron(expression: "0 20 * * 0", timeZone: "Asia/Shanghai"),
                    nextFireAt: Fixture.now.addingTimeInterval(3 * 86400))
            ])
    }

    static var invalidPlan: Plan {
        Plan(
            id: invalidPlanID, instanceID: DemoData.reviewerID, title: "旧时区的提醒", goal: "提醒我交周报。",
            createdAt: Fixture.now.addingTimeInterval(-10 * 86400),
            triggers: [
                Trigger(
                    id: invalidTriggerID, schedule: .cron(expression: "0 9 * * 5", timeZone: "Mars/Olympus"),
                    isEnabled: false, lastFireAt: Fixture.now.addingTimeInterval(-7 * 86400),
                    disabledReason: .invalidRule)
            ])
    }

    static var pipelinePlan: Plan {
        Plan(
            id: pipelinePlanID, instanceID: DemoData.writerID, title: "发版流水线", goal: "收集改动、审查、写发版说明。",
            createdAt: Fixture.now.addingTimeInterval(-2 * 86400),
            triggers: [
                Trigger(
                    id: "0192f3a0-0000-7000-8000-00000000c413",
                    schedule: .cron(expression: "0 10 * * 1", timeZone: "Asia/Shanghai"),
                    nextFireAt: Fixture.now.addingTimeInterval(86400))
            ],
            steps: [
                PlanStep(key: "collect", instanceID: DemoData.writerID, prompt: "收集这周的改动"),
                PlanStep(key: "review", instanceID: DemoData.reviewerID, prompt: "审查改动", dependsOn: ["collect"]),
                PlanStep(key: "notes", instanceID: DemoData.writerID, prompt: "写发版说明", dependsOn: ["review"]),
                PlanStep(key: "notify", instanceID: DemoData.writerID, prompt: "通知大家", dependsOn: ["collect"]),
            ])
    }

    /// 演示数据加上上面三个计划。
    static func mockWithPlans() -> MockClient {
        mock { $0.plans += [pausedPlan, invalidPlan, pipelinePlan] }
    }

    /// 计划触发的根运行（`count` 个，新的在前，每隔一小时一个）。
    static func planRuns(_ planID: PlanID, count: Int, instanceID: InstanceID = DemoData.writerID) -> [Run] {
        (0..<count).map { i in
            Run(
                id: RunID(rawValue: String(format: "0192f3a0-0000-7000-8000-%012d", 900 + i)), instanceID: instanceID,
                planID: planID, source: .plan, prompt: "按时触发 \(i)", state: .succeeded, summary: "第 \(i) 次的摘要",
                createdAt: Fixture.now.addingTimeInterval(-Double(i) * 3600))
        }
    }
}
