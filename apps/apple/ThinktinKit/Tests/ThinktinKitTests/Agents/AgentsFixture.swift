import Foundation
import Testing

@testable import ThinktinKit

// Agent 目录与领养（12.3）测试共用的数据。名字都放在 `AgentsFixture` 里，不和别的功能的测试工具重名。

enum AgentsFixture {
    /// 演示数据上的 Mock：不自动回答、不等待。`edit` 可以先改一下状态。
    static func mock(_ edit: (inout MockState) -> Void = { _ in }) -> MockClient {
        var state = DemoData.state()
        edit(&state)
        return MockClient(state: state, stepDelay: 0, autoReply: false)
    }

    /// 写作助手上的一条流水线，第二步指定了代码审查（删代码审查时会被删掉），第三步依赖第二步。
    static let pipelinePlanID: PlanID = "0192f3a0-0000-7000-8000-00000000a401"

    static var pipelinePlan: Plan {
        Plan(
            id: pipelinePlanID, instanceID: DemoData.writerID, title: "发版流水线", goal: "收集改动、审查、写发版说明。",
            createdBy: .agent, createdAt: Fixture.now,
            steps: [
                PlanStep(key: "collect", instanceID: DemoData.writerID, prompt: "收集这周的改动"),
                PlanStep(key: "review", instanceID: DemoData.reviewerID, prompt: "审查改动", dependsOn: ["collect"]),
                PlanStep(key: "notes", instanceID: DemoData.writerID, prompt: "写发版说明", dependsOn: ["review"]),
                PlanStep(key: "notify", instanceID: DemoData.writerID, prompt: "通知大家", dependsOn: ["collect"]),
            ])
    }

    /// 带上面那条流水线的 Mock。
    static func mockWithPipeline() -> MockClient {
        mock { $0.plans.append(pipelinePlan) }
    }

    static func agent(
        _ id: AgentID, name: String = "Agent", harnesses: [String] = ["acp"], versions: [String] = ["1.0.0"]
    ) -> AgentInfo {
        AgentInfo(
            id: id, name: name, version: versions.first ?? "1.0.0", harnesses: harnesses,
            defaultHarness: harnesses.first ?? "acp", versions: versions)
    }
}
