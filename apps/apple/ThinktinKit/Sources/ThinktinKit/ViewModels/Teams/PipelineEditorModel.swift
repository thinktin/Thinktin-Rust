import Foundation
import Observation

/// 流水线编辑器（WBS 12.7，`.pipelineEditor(planID:teamID:)`）：每步选实例、写提示词、勾依赖步骤，上下挪、删除，最多 20 步；
/// 本地按服务端的规则查键名、依赖和环（`PipelineRules`），问题在点保存后标出来。
///
/// - 改已有计划的步骤（`planID`）：保存只发 `steps`（`updatePlan`），标题、触发器在计划编辑里改。
/// - 用团队建新流水线（`teamID`，团队详情进来）：每个成员一步，负责人最后汇总；计划挂在负责人上，填标题、目标后建（没有触发规则，
///   建好后去计划详情加）。
@Observable @MainActor
public final class PipelineEditorModel {
    public let planID: PlanID?
    public let teamID: TeamID?
    public private(set) var plan: Plan?
    /// 新建时的标题、目标。
    public var title = ""
    public var goal = ""
    public private(set) var steps: [StepDraft] = []
    /// 能选的实例（不含已删除的）。
    public private(set) var instances: [Instance] = []
    /// 计划挂在哪个实例上（编辑时是计划的；新建时是团队的负责人，没有就是第一步的）。
    public private(set) var hostInstanceID: InstanceID?
    /// 拉到了（失败时还是 false，页面显示错误和重试）。
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isMissing = false
    public private(set) var isSaving = false
    public private(set) var saveError: ClientError?
    /// 点过保存：显示问题。
    public private(set) var showsProblems = false

    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var originalSteps: [PlanStep] = []

    public init(client: any ClientProtocol, planID: PlanID?, teamID: TeamID?) {
        self.client = client
        self.planID = planID
        self.teamID = teamID
    }

    public var isEditing: Bool { planID != nil }

    public var stepProblems: [StepProblem] {
        PipelineRules.problems(steps, instances: Set(instances.map(\.id)))
    }

    /// 新建时标题、目标的问题。
    public var titleProblem: PlanTextProblem? {
        isEditing ? nil : PlanTextProblem.check(title, max: Plan.maxTitleLength)
    }

    public var goalProblem: PlanTextProblem? {
        isEditing ? nil : PlanTextProblem.check(goal, max: Plan.maxGoalLength)
    }

    public var canAddStep: Bool { steps.count < PipelineRules.maxSteps }

    /// 有改动（编辑时步骤变了；新建时填了东西）。
    public var hasChanges: Bool {
        if isEditing { return steps.map(\.step) != originalSteps }
        return !title.isEmpty || !goal.isEmpty || steps.contains { !$0.prompt.isEmpty }
    }

    public func instanceName(_ id: InstanceID?) -> String? {
        guard let id else { return nil }
        return instances.first { $0.id == id }?.name
    }

    public func load() async {
        guard !isLoading, !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            instances = try await client.instances().filter { $0.state != .deleted }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
            if let planID {
                let plan = try await client.getPlan(planID)
                self.plan = plan
                hostInstanceID = plan.instanceID
                originalSteps = plan.steps
                steps = plan.steps.map { step in
                    defer { nextID += 1 }
                    return StepDraft(step, id: nextID)
                }
            } else if let teamID {
                let team = try await client.team(teamID)
                steps = PipelineRules.fromTeam(team, firstID: nextID)
                nextID += steps.count
                hostInstanceID = team.lead?.instanceID ?? steps.first?.instanceID
                if title.isEmpty { title = team.name }
            } else {
                hostInstanceID = instances.first?.id
            }
            error = nil
            isMissing = false
            hasLoaded = true
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isMissing = true } else { self.error = failure }
        }
    }

    // MARK: 步骤

    public func addStep() {
        guard canAddStep else { return }
        let instance = steps.last?.instanceID ?? hostInstanceID
        steps.append(StepDraft(id: nextID, key: PipelineRules.nextKey(steps), instanceID: instance, prompt: ""))
        nextID += 1
    }

    public func removeStep(_ id: Int) {
        steps = PipelineRules.remove(steps, id: id)
    }

    public func moveStep(_ id: Int, by delta: Int) {
        steps = PipelineRules.move(steps, id: id, by: delta)
    }

    /// 改键名：只收小写字母、数字、`_`、`-`，依赖它的步骤跟着改。
    public func setKey(_ id: Int, _ key: String) {
        steps = PipelineRules.rename(steps, id: id, to: PipelineRules.cleanKey(key))
    }

    public func setInstance(_ id: Int, _ instanceID: InstanceID) {
        update(id) { $0.instanceID = instanceID }
    }

    public func setPrompt(_ id: Int, _ prompt: String) {
        update(id) { $0.prompt = prompt }
    }

    public func toggleDependency(_ id: Int, on key: String) {
        update(id) { step in
            if let index = step.dependsOn.firstIndex(of: key) {
                step.dependsOn.remove(at: index)
            } else {
                step.dependsOn.append(key)
            }
        }
    }

    /// 某一步的问题。
    public func problems(of id: Int) -> [StepProblem] {
        guard showsProblems else { return [] }
        return stepProblems.filter { $0.stepID == id }
    }

    /// 整体的问题（环、太多）。
    public var generalProblems: [StepProblem] {
        guard showsProblems else { return [] }
        return stepProblems.filter { $0.stepID == nil }
    }

    // MARK: 保存

    /// 保存；成功返回计划（页面去计划详情）。
    public func save() async -> Plan? {
        guard !isSaving, hasLoaded else { return nil }
        guard stepProblems.isEmpty, titleProblem == nil, goalProblem == nil else {
            showsProblems = true
            return nil
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            if let planID {
                let saved = try await client.updatePlan(planID, change: PlanChange(steps: steps.map(\.step)))
                originalSteps = saved.steps
                plan = saved
                return saved
            }
            guard let host = hostInstanceID ?? steps.first?.instanceID else { return nil }
            return try await client.createPlan(
                NewPlan(
                    instanceID: host, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), triggers: [],
                    steps: steps.map(\.step)))
        } catch {
            if let failure = ConversationErrors.from(error) { saveError = failure }
            return nil
        }
    }

    public func clearSaveError() {
        saveError = nil
    }

    private func update(_ id: Int, _ body: (inout StepDraft) -> Void) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        body(&steps[index])
    }
}
