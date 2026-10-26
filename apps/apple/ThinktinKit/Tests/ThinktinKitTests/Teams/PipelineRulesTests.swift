import Foundation
import Testing

@testable import ThinktinKit

@Suite("流水线步骤的本地规则")
struct PipelineRulesTests {
    private let writer = DemoData.writerID
    private let reviewer = DemoData.reviewerID

    private func step(
        _ id: Int, _ key: String, instance: InstanceID? = DemoData.writerID, prompt: String = "做事",
        after: [String] = []
    ) -> StepDraft {
        StepDraft(id: id, key: key, instanceID: instance, prompt: prompt, dependsOn: after)
    }

    @Test("键名：1–32 个小写字母、数字、_、-，以字母或数字开头")
    func keys() {
        for key in ["a", "step1", "a-b_c", "0x", String(repeating: "k", count: 32)] {
            #expect(PipelineRules.isValidKey(key), "\(key)")
        }
        for key in ["", "_a", "-a", "Ab", "a b", "中文", String(repeating: "k", count: 33)] {
            #expect(!PipelineRules.isValidKey(key), "\(key)")
        }
        #expect(PipelineRules.cleanKey("Step 1!") == "step1")
        #expect(PipelineRules.cleanKey("A_b-C") == "a_b-c")
        #expect(PipelineRules.cleanKey(String(repeating: "x", count: 40)).count == 32)
    }

    @Test("没有问题的流水线")
    func clean() {
        let steps = [step(1, "collect"), step(2, "review", instance: reviewer, after: ["collect"])]
        #expect(PipelineRules.problems(steps, instances: [writer, reviewer]).isEmpty)
    }

    @Test("每一种问题都报在对应的步骤上")
    func problems() {
        let steps = [
            step(1, "Bad"),
            step(2, "dup"),
            step(3, "dup", instance: nil),
            step(4, "gone", instance: "deleted"),
            step(5, "empty", prompt: "  \n"),
            step(6, "long", prompt: String(repeating: "字", count: PipelineRules.maxPrompt + 1)),
            step(7, "lost", after: ["nowhere"]),
            step(8, "selfish", after: ["selfish"]),
        ]
        let problems = Set(PipelineRules.problems(steps, instances: [writer, reviewer]))
        #expect(problems.contains(.badKey(stepID: 1)))
        #expect(problems.contains(.duplicateKey(stepID: 2)) && problems.contains(.duplicateKey(stepID: 3)))
        #expect(problems.contains(.noInstance(stepID: 3)))
        #expect(problems.contains(.deletedInstance(stepID: 4)))
        #expect(problems.contains(.emptyPrompt(stepID: 5)))
        #expect(problems.contains(.promptTooLong(stepID: 6)))
        #expect(problems.contains(.unknownDependency(stepID: 7, key: "nowhere")))
        #expect(problems.contains(.selfDependency(stepID: 8)))
        #expect(!problems.contains(.cycle))
        #expect(!problems.contains(.tooMany))
        // 提示词刚好 8000 字可以。
        let exact = [step(1, "a", prompt: String(repeating: "字", count: PipelineRules.maxPrompt))]
        #expect(PipelineRules.problems(exact, instances: [writer]).isEmpty)
    }

    @Test("环和太多步是整体的问题")
    func general() {
        let loop = [step(1, "a", after: ["c"]), step(2, "b", after: ["a"]), step(3, "c", after: ["b"])]
        #expect(PipelineRules.problems(loop, instances: [writer]) == [.cycle])
        #expect(PipelineRules.order(loop) == nil)
        #expect(StepProblem.cycle.stepID == nil)

        let many = (1...(PipelineRules.maxSteps + 1)).map { step($0, "s\($0)") }
        #expect(PipelineRules.problems(many, instances: [writer]) == [.tooMany])
    }

    @Test("拓扑序：没有依赖的先，同一层按声明顺序（和服务端的 order_steps 一样）")
    func order() {
        let steps = [
            step(1, "a"), step(2, "b", after: ["a"]), step(3, "c"), step(4, "d", after: ["b", "c"]),
            step(5, "e", after: ["missing"]),
        ]
        #expect(PipelineRules.order(steps) == ["a", "c", "e", "b", "d"])
    }

    @Test("加一步、改键名、删一步、上下挪：依赖跟着改")
    func edits() {
        var steps = [step(1, "step1"), step(2, "step3", after: ["step1"])]
        #expect(PipelineRules.nextKey(steps) == "step2")

        steps = PipelineRules.rename(steps, id: 1, to: "gather")
        #expect(steps.map(\.key) == ["gather", "step3"])
        #expect(steps[1].dependsOn == ["gather"])

        let moved = PipelineRules.move(steps, id: 2, by: -1)
        #expect(moved.map(\.id) == [2, 1])
        #expect(PipelineRules.move(steps, id: 1, by: -1) == steps)
        #expect(PipelineRules.move(steps, id: 2, by: 1) == steps)
        #expect(PipelineRules.move(steps, id: 99, by: 1) == steps)

        let removed = PipelineRules.remove(steps, id: 1)
        #expect(removed.map(\.id) == [2])
        #expect(removed[0].dependsOn.isEmpty)
        #expect(PipelineRules.remove(steps, id: 99) == steps)
    }

    @Test("用团队建：成员各一步，负责人最后汇总、等前面所有步骤")
    func fromTeam() {
        let team = Team(
            id: "t", name: "三人组",
            members: [
                TeamMember(instanceID: "m2", role: .member, position: 2),
                TeamMember(instanceID: "lead", role: .lead, position: 0),
                TeamMember(instanceID: "m1", role: .member, position: 1),
            ], createdAt: Fixture.now)
        let steps = PipelineRules.fromTeam(team, firstID: 10)
        #expect(steps.map(\.id) == [10, 11, 12])
        #expect(steps.map(\.key) == ["step1", "step2", "summary"])
        #expect(steps.map(\.instanceID) == ["m1", "m2", "lead"])
        #expect(steps[2].dependsOn == ["step1", "step2"])
        #expect(steps.allSatisfy { $0.prompt.isEmpty })

        // 没有负责人：只有成员的步骤。
        let flat = Team(
            id: "f", name: "没负责人", members: [TeamMember(instanceID: "m1", role: .member, position: 0)],
            createdAt: Fixture.now)
        #expect(PipelineRules.fromTeam(flat).map(\.key) == ["step1"])
    }

    @Test("要保存的样子：去掉首尾空白，没选实例是空字符串")
    func saved() {
        let draft = StepDraft(id: 1, key: " a ", instanceID: nil, prompt: "  做事\n", dependsOn: ["b"])
        #expect(draft.step == PlanStep(key: "a", instanceID: "", prompt: "做事", dependsOn: ["b"]))
        let round = StepDraft(PlanStep(key: "k", instanceID: DemoData.writerID, prompt: "p"), id: 7)
        #expect(round.id == 7 && round.key == "k" && round.instanceID == DemoData.writerID)
    }
}
