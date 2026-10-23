import Foundation
import Observation

/// 新建、编辑计划（WBS 12.6，`.newPlan`、`.editPlan` 两个 sheet）：实例（新建时选）、标题（最多 100 个字）、
/// 目标（最多 8000 个字）、触发规则（一到十条，用 `TriggerDraft` 编）、策略（`PlanPolicyDraft`）、补跑方式。
/// 流水线的步骤这里只读（编辑器在 12.7），保存时不动。
///
/// 保存：
/// - 新建：`createPlan`（带上策略和补跑方式）。
/// - 编辑：`updatePlan(PlanChange)` 只带改了的字段；触发器服务端没有“改”，删掉的 `deleteTrigger`、新加的（包括改过的，
///   改一条 = 删旧的、加新的）`addTrigger`，先删后加（免得满 10 条加不进去）。中途失败时已经做完的不再重做，
///   再点保存只做剩下的。
/// - 改的是等确认的计划（确认页的“修改后确认”）：保存后计划还在等确认，版本号变了，回到确认页按新版本确认。
@Observable @MainActor
public final class PlanEditorModel {
    /// 新建还是编辑。
    public enum Mode: Hashable, Sendable {
        /// 新建；`instanceID` 是预选的实例。
        case create(instanceID: InstanceID?)
        case edit(PlanID)
    }

    public let mode: Mode
    /// 计划所属的实例（新建时选；编辑时不能换）。
    public var instanceID: InstanceID?
    public var title = ""
    public var goal = ""
    public private(set) var triggers: [PlanTriggerItem] = []
    public var policy = PlanPolicyDraft()
    public var catchUp: CatchUp = .default
    /// 流水线的步骤（只读）。
    public private(set) var steps: [PlanStep] = []
    /// 编辑时：接口上现在的计划（保存了一部分之后会更新）。
    public private(set) var original: Plan?

    public private(set) var isLoading = false
    public private(set) var loadError: ClientError?
    /// 要编辑的计划不在了。
    public private(set) var isMissing = false
    public private(set) var isSaving = false
    public private(set) var saveError: ClientError?
    /// 保存失败时，是不是已经存上了一部分（界面提示“部分改动已保存”）。
    public private(set) var isPartiallySaved = false
    /// 保存好的计划（界面关掉 sheet、详情页换上它）。
    public private(set) var savedPlan: Plan?

    /// 编辑时用户删掉的已有触发器（保存时 `deleteTrigger`）。
    @ObservationIgnored private var removedTriggerIDs: [TriggerID] = []
    @ObservationIgnored private let client: any ClientProtocol
    @ObservationIgnored private let snapshots: PlanSnapshotStore
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - plan: 编辑时已经有的计划（详情页的），先填进表单；没有时 `load()` 去拉。
    ///   - timeZone: 设备的时区（新规则的默认时区）。
    public init(
        client: any ClientProtocol, mode: Mode, plan: Plan? = nil, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }, snapshots: PlanSnapshotStore = .shared
    ) {
        self.client = client
        self.mode = mode
        self.timeZone = timeZone
        self.now = now
        self.snapshots = snapshots
        switch mode {
        case .create(let instanceID):
            self.instanceID = instanceID
        case .edit(let id):
            if let plan, plan.id == id { fill(from: plan) }
        }
    }

    public var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// 编辑、但计划还没拉到。
    public var needsLoad: Bool { isEditing && original == nil && !isMissing }

    /// 编辑时拉计划填进表单（已经有了就不拉）。
    public func load() async {
        guard case .edit(let id) = mode, original == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            fill(from: try await client.getPlan(id))
            loadError = nil
        } catch {
            guard let failure = PlansErrors.from(error) else { return }
            if failure.isNotFound {
                isMissing = true
            } else {
                loadError = failure
            }
        }
    }

    private func fill(from plan: Plan) {
        original = plan
        instanceID = plan.instanceID
        title = plan.title
        goal = plan.goal
        triggers = plan.triggers.map(PlanTriggerItem.init(trigger:))
        policy = PlanPolicyDraft(plan.policy)
        catchUp = plan.catchUp
        steps = plan.steps
        removedTriggerIDs = []
    }

    // MARK: 触发规则

    /// 新规则的初始内容：设备的时区、每天 09:00。
    public func newTriggerDraft() -> TriggerDraft {
        TriggerDraft(timeZone: timeZone, now: now())
    }

    /// 编辑一条已有的规则时的初始内容。
    public func draft(for itemID: PlanTriggerItem.ID) -> TriggerDraft? {
        guard let item = triggers.first(where: { $0.id == itemID }) else { return nil }
        return TriggerDraft(schedule: item.schedule, timeZone: timeZone, now: now())
    }

    /// 还能不能再加（一个计划最多 10 条）。
    public var canAddTrigger: Bool { triggers.count < Plan.maxTriggers }

    public func addTrigger(_ schedule: Schedule) {
        guard canAddTrigger else { return }
        triggers.append(PlanTriggerItem(schedule: schedule))
    }

    /// 改一条规则：已有的改了内容就换成新加的一条（保存时删旧加新），新加的直接改。
    public func updateTrigger(_ itemID: PlanTriggerItem.ID, to schedule: Schedule) {
        guard let i = triggers.firstIndex(where: { $0.id == itemID }), triggers[i].schedule != schedule else { return }
        if let existing = triggers[i].triggerID {
            removedTriggerIDs.append(existing)
            triggers[i] = PlanTriggerItem(schedule: schedule)
        } else {
            triggers[i].schedule = schedule
        }
    }

    public func removeTrigger(_ itemID: PlanTriggerItem.ID) {
        guard let i = triggers.firstIndex(where: { $0.id == itemID }) else { return }
        if let existing = triggers[i].triggerID { removedTriggerIDs.append(existing) }
        triggers.remove(at: i)
    }

    // MARK: 检查

    public var titleProblem: PlanTextProblem? {
        PlanTextProblem.check(title, max: Plan.maxTitleLength)
    }

    public var goalProblem: PlanTextProblem? {
        PlanTextProblem.check(goal, max: Plan.maxGoalLength)
    }

    /// 触发规则的问题：一条都没有、超过 10 条。
    public var triggersProblem: PlanFormProblem? {
        if triggers.isEmpty { return .noTriggers }
        if triggers.count > Plan.maxTriggers { return .tooManyTriggers(max: Plan.maxTriggers) }
        return nil
    }

    /// 标题、目标现在有几个字（和服务端一样按 Unicode 标量数，去掉首尾空白）。
    public var titleLength: Int { PlanTextProblem.length(title) }
    public var goalLength: Int { PlanTextProblem.length(goal) }

    /// 全部问题（保存按钮灰掉的原因）。
    public var problems: [PlanFormProblem] {
        var out: [PlanFormProblem] = []
        if instanceID == nil { out.append(.noInstance) }
        if let titleProblem { out.append(.title(titleProblem)) }
        if let goalProblem { out.append(.goal(goalProblem)) }
        if let triggersProblem { out.append(triggersProblem) }
        out.append(contentsOf: policy.problems.map(PlanFormProblem.policy))
        return out
    }

    /// 编辑时：标题、目标、策略、补跑方式里改了的（没改的不带）。
    public var change: PlanChange {
        guard let original else { return PlanChange() }
        var change = PlanChange()
        let title = PlanTextProblem.normalized(self.title)
        let goal = PlanTextProblem.normalized(self.goal)
        if title != original.title { change.title = title }
        if goal != original.goal { change.goal = goal }
        if let resolved = policy.policy, resolved != original.policy { change.policy = resolved }
        if catchUp != original.catchUp { change.catchUp = catchUp }
        return change
    }

    /// 有没有改动（关掉 sheet 前提醒“放弃修改”）。
    public var hasChanges: Bool {
        if isEditing {
            return !change.isEmpty || !removedTriggerIDs.isEmpty || triggers.contains(where: \.isNew)
        }
        return !PlanTextProblem.normalized(title).isEmpty || !PlanTextProblem.normalized(goal).isEmpty
            || !triggers.isEmpty || policy != PlanPolicyDraft() || catchUp != .default
    }

    public var canSave: Bool {
        problems.isEmpty && !isSaving && !needsLoad && (!isEditing || hasChanges)
    }

    // MARK: 保存

    /// 保存。成功返回保存后的计划（也放在 `savedPlan`）。
    @discardableResult
    public func save() async -> Plan? {
        guard canSave, let policy = policy.policy else { return nil }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        switch mode {
        case .create:
            return await create(policy: policy)
        case .edit(let id):
            return await saveEdits(planID: id)
        }
    }

    private func create(policy: PlanPolicy) async -> Plan? {
        guard let instanceID else { return nil }
        let new = NewPlan(
            instanceID: instanceID, title: PlanTextProblem.normalized(title), goal: PlanTextProblem.normalized(goal),
            triggers: triggers.map(\.schedule), policy: policy, catchUp: catchUp)
        do {
            let plan = try await client.createPlan(new)
            savedPlan = plan
            snapshots.record(plan)
            return plan
        } catch {
            saveError = PlansErrors.from(error)
            return nil
        }
    }

    private func saveEdits(planID: PlanID) async -> Plan? {
        var didSomething = false
        do {
            let change = self.change
            if !change.isEmpty {
                original = try await client.updatePlan(planID, change: change)
                didSomething = true
            }
            while let id = removedTriggerIDs.first {
                do {
                    try await client.deleteTrigger(id)
                } catch let error as ClientError where error.isNotFound {
                    // 别处已经删了。
                }
                removedTriggerIDs.removeFirst()
                didSomething = true
            }
            for i in triggers.indices where triggers[i].isNew {
                let trigger = try await client.addTrigger(planID: planID, schedule: triggers[i].schedule)
                triggers[i] = PlanTriggerItem(trigger: trigger)
                didSomething = true
            }
        } catch {
            saveError = PlansErrors.from(error)
            isPartiallySaved = didSomething
            return nil
        }
        // 再拉一次：触发器的下一次触发时间、计划的 nextFireAt 以服务端为准。
        let saved: Plan
        if let fresh = try? await client.getPlan(planID) {
            saved = fresh
        } else if var latest = original {
            latest.triggers = triggers.compactMap(\.trigger)
            latest.refreshSchedule()
            saved = latest
        } else {
            return nil
        }
        original = saved
        savedPlan = saved
        isPartiallySaved = false
        snapshots.record(saved)
        return saved
    }

    public func clearSaveError() {
        saveError = nil
    }
}

/// 编辑器里的一条触发规则：已有的（带服务端的 id、下一次 / 上一次触发）或新加的。
public struct PlanTriggerItem: Identifiable, Hashable, Sendable {
    public let id: String
    /// 已有的触发器的 id；新加的为 nil。
    public let triggerID: TriggerID?
    public var schedule: Schedule
    /// 服务端的触发器（已有的才有）。
    public let trigger: Trigger?

    public init(trigger: Trigger) {
        id = trigger.id.rawValue
        triggerID = trigger.id
        schedule = trigger.schedule
        self.trigger = trigger
    }

    public init(schedule: Schedule) {
        id = "new-" + UUID().uuidString
        triggerID = nil
        self.schedule = schedule
        trigger = nil
    }

    public var isNew: Bool { triggerID == nil }
}

/// 标题、目标的问题（和服务端一样：去掉首尾空白后 1 到 N 个字符，按 Unicode 标量数）。
public enum PlanTextProblem: Hashable, Sendable {
    case empty
    case tooLong(max: Int)

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func length(_ text: String) -> Int {
        normalized(text).unicodeScalars.count
    }

    static func check(_ text: String, max: Int) -> PlanTextProblem? {
        let n = length(text)
        if n == 0 { return .empty }
        if n > max { return .tooLong(max: max) }
        return nil
    }
}

/// 计划表单的问题。
public enum PlanFormProblem: Hashable, Sendable {
    case noInstance
    case title(PlanTextProblem)
    case goal(PlanTextProblem)
    case noTriggers
    case tooManyTriggers(max: Int)
    case policy(PlanPolicyProblem)

    public func message(_ language: DisplayLanguage = .current) -> String {
        let zh = language == .chinese
        switch self {
        case .noInstance: return zh ? "选一个实例来执行这个计划。" : "Pick an instance to run this plan."
        case .title(.empty): return zh ? "起个标题吧。" : "Give it a title."
        case .title(.tooLong(let max)): return zh ? "标题最多 \(max) 个字。" : "Titles can be up to \(max) characters."
        case .goal(.empty): return zh ? "写一下要 agent 每次做什么。" : "Describe what the agent should do each time."
        case .goal(.tooLong(let max)): return zh ? "目标最多 \(max) 个字。" : "Goals can be up to \(max) characters."
        case .noTriggers: return zh ? "至少加一条触发规则。" : "Add at least one schedule."
        case .tooManyTriggers(let max): return zh ? "最多 \(max) 条触发规则。" : "Up to \(max) schedules."
        case .policy(let problem): return problem.message(language)
        }
    }
}
