import SwiftUI
import ThinktinKit

// 预览和界面测试用的数据（12.6）。

/// 几种演示客户端。
enum PlansPreviewClients {
    /// 写作助手上一个暂停了的计划。
    static let pausedPlanID: PlanID = "0192f3a0-0000-7000-8000-00000000c401"
    /// 代码审查上一个规则失效了的计划。
    static let invalidPlanID: PlanID = "0192f3a0-0000-7000-8000-00000000c402"
    /// 写作助手上的流水线，第二步在代码审查上跑。
    static let pipelinePlanID: PlanID = "0192f3a0-0000-7000-8000-00000000c403"

    /// 演示数据加上暂停的、规则失效的、流水线三个计划，以及通知汇总的几次运行。
    static func withPlans(now: Date = Date()) -> MockClient {
        var state = DemoData.state(now: now)
        state.plans += [
            Plan(
                id: pausedPlanID, instanceID: DemoData.writerID, title: "周末读书笔记",
                goal: "每周日晚上把这周读的书整理成笔记，放进 notes/books.md。", isPaused: true,
                createdAt: now.addingTimeInterval(-6 * 86400),
                triggers: [
                    Trigger(
                        id: "0192f3a0-0000-7000-8000-00000000c411",
                        schedule: .cron(expression: "0 20 * * 0", timeZone: "Asia/Shanghai"),
                        nextFireAt: now.addingTimeInterval(3 * 86400), lastFireAt: now.addingTimeInterval(-4 * 86400))
                ]),
            Plan(
                id: invalidPlanID, instanceID: DemoData.reviewerID, title: "周五交周报提醒", goal: "周五下午提醒我交周报。",
                createdAt: now.addingTimeInterval(-30 * 86400),
                triggers: [
                    Trigger(
                        id: "0192f3a0-0000-7000-8000-00000000c412",
                        schedule: .cron(expression: "0 16 * * 5", timeZone: "America/Old_Zone"), isEnabled: false,
                        lastFireAt: now.addingTimeInterval(-7 * 86400), disabledReason: .invalidRule)
                ]),
            Plan(
                id: pipelinePlanID, instanceID: DemoData.writerID, title: "发版流水线", goal: "收集这周的改动、审查、写发版说明。",
                policy: PlanPolicy(preauthorizedTools: ["read", "search"], approvalTimeoutSecs: 4 * 3600),
                createdAt: now.addingTimeInterval(-2 * 86400),
                triggers: [
                    Trigger(
                        id: "0192f3a0-0000-7000-8000-00000000c413",
                        schedule: .rrule(
                            "DTSTART;TZID=Asia/Shanghai:20261023T100000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=FR"),
                        nextFireAt: now.addingTimeInterval(86400))
                ],
                steps: [
                    PlanStep(key: "collect", instanceID: DemoData.writerID, prompt: "收集这周合并的改动，按模块分组。"),
                    PlanStep(
                        key: "review", instanceID: DemoData.reviewerID, prompt: "审查这些改动有没有破坏性变更。",
                        dependsOn: ["collect"]),
                    PlanStep(
                        key: "notes", instanceID: DemoData.writerID, prompt: "写发版说明。", dependsOn: ["review"]),
                ]),
        ]
        state.runs += (1...3).map { digestRun($0, now: now) }
        return MockClient(state: state, autoReply: false)
    }

    /// 通知汇总按时触发的第 `i` 次（`i` 天前；第 2 次失败了）。
    static func digestRun(_ i: Int, now: Date) -> Run {
        let created = now.addingTimeInterval(-Double(i) * 86400 - 3 * 3600)
        let failed = i == 2
        return Run(
            id: RunID(String(format: "0192f3a0-0000-7000-8000-%012d", 910 + i)), instanceID: DemoData.writerID,
            planID: DemoData.digestPlanID, source: .plan, prompt: "汇总昨天以来的 GitHub 通知，只列需要我处理的。",
            state: failed ? .failed : .succeeded, tokensUsed: 5_000 + i * 700,
            summary: failed ? nil : "有 \(i + 1) 条需要你处理。", error: failed ? "model gateway: timeout" : nil,
            createdAt: created, startedAt: created.addingTimeInterval(4), finishedAt: created.addingTimeInterval(60))
    }

    /// 没有计划。
    static func empty() -> MockClient {
        var state = DemoData.state()
        state.plans = []
        return MockClient(state: state, autoReply: false)
    }

    /// agent 改了用户的计划（等确认，版本号 3，没有旧版本可比）。
    static func agentEditedUserPlan() -> MockClient {
        var state = DemoData.state()
        if let i = state.plans.firstIndex(where: { $0.id == DemoData.digestPlanID }) {
            state.plans[i].goal = "每个工作日早上 8 点汇总 GitHub 通知，顺便列出昨天合并的 PR。"
            state.plans[i].awaitingConfirmation = true
            state.plans[i].isPaused = true
            state.plans[i].revision = 3
            state.plans[i].policy.preauthorizedTools.append("execute")
        }
        return MockClient(state: state, autoReply: false)
    }
}
