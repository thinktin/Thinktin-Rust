import Foundation

/// 编辑中的一步（WBS 12.7）：`id` 只在本地用（改键名时认得出是哪一步）。
public struct StepDraft: Identifiable, Hashable, Sendable {
    public var id: Int
    public var key: String
    public var instanceID: InstanceID?
    public var prompt: String
    public var dependsOn: [String]

    public init(id: Int, key: String, instanceID: InstanceID?, prompt: String, dependsOn: [String] = []) {
        self.id = id
        self.key = key
        self.instanceID = instanceID
        self.prompt = prompt
        self.dependsOn = dependsOn
    }

    public init(_ step: PlanStep, id: Int) {
        self.init(id: id, key: step.key, instanceID: step.instanceID, prompt: step.prompt, dependsOn: step.dependsOn)
    }

    /// 要保存的样子（键名、提示词去掉首尾空白）。
    public var step: PlanStep {
        PlanStep(
            key: key.trimmingCharacters(in: .whitespaces), instanceID: instanceID ?? "",
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), dependsOn: dependsOn)
    }
}

/// 一步的问题（保存前在本地拦下，和服务端 `routes/plans.rs` 的 `check_steps`、`domain.rs` 的 `order_steps` 一样）。
public enum StepProblem: Hashable, Sendable {
    /// 键名要 1–32 个 a-z 0-9 _ -，以字母或数字开头。
    case badKey(stepID: Int)
    case duplicateKey(stepID: Int)
    case noInstance(stepID: Int)
    /// 选的实例删掉了（服务端会拒绝：先改步骤）。
    case deletedInstance(stepID: Int)
    case emptyPrompt(stepID: Int)
    case promptTooLong(stepID: Int)
    /// 依赖的步骤不在了。
    case unknownDependency(stepID: Int, key: String)
    case selfDependency(stepID: Int)
    /// 依赖成环了。
    case cycle
    case tooMany

    /// 是哪一步的（整体的问题为 nil）。
    public var stepID: Int? {
        switch self {
        case .badKey(let id), .duplicateKey(let id), .noInstance(let id), .deletedInstance(let id),
            .emptyPrompt(let id),
            .promptTooLong(let id), .unknownDependency(let id, _), .selfDependency(let id):
            id
        case .cycle, .tooMany: nil
        }
    }
}

/// 流水线步骤的本地规则（WBS 12.7）：键名格式、唯一、依赖存在、不依赖自己、没有环（Kahn 拓扑排序，同一层按声明顺序），
/// 最多 20 步，提示词 1–8000 字。和服务端、安卓的 `Pipeline` 一致。
public enum PipelineRules {
    /// 流水线最多几步（服务端 MAX_STEPS）。
    public static let maxSteps = 20
    /// 提示词最多几个字（去掉首尾空白后按 Unicode 标量数）。
    public static let maxPrompt = 8000

    public static func isValidKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard (1...32).contains(scalars.count) else { return false }
        return scalars.enumerated().allSatisfy { index, scalar in
            let isLower = scalar.value >= 0x61 && scalar.value <= 0x7A
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            return isLower || isDigit || (index > 0 && (scalar == "_" || scalar == "-"))
        }
    }

    /// `instances` 是还在的实例。
    public static func problems(_ steps: [StepDraft], instances: Set<InstanceID>) -> [StepProblem] {
        var result: [StepProblem] = []
        if steps.count > maxSteps { result.append(.tooMany) }
        let keys = steps.map { $0.key.trimmingCharacters(in: .whitespaces) }
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        for (step, key) in zip(steps, keys) {
            if !isValidKey(key) { result.append(.badKey(stepID: step.id)) }
            if (counts[key] ?? 0) > 1 { result.append(.duplicateKey(stepID: step.id)) }
            if let instance = step.instanceID, !instance.rawValue.isEmpty {
                if !instances.contains(instance) { result.append(.deletedInstance(stepID: step.id)) }
            } else {
                result.append(.noInstance(stepID: step.id))
            }
            let prompt = step.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.isEmpty { result.append(.emptyPrompt(stepID: step.id)) }
            if prompt.unicodeScalars.count > maxPrompt { result.append(.promptTooLong(stepID: step.id)) }
            for dependency in step.dependsOn {
                if dependency == key {
                    result.append(.selfDependency(stepID: step.id))
                } else if counts[dependency] == nil {
                    result.append(.unknownDependency(stepID: step.id, key: dependency))
                }
            }
        }
        if order(steps) == nil { result.append(.cycle) }
        return result
    }

    /// 拓扑序（键名）；有环时为 nil。认不出的依赖不算（另报）。
    public static func order(_ steps: [StepDraft]) -> [String]? {
        let keys = Set(steps.map { $0.key.trimmingCharacters(in: .whitespaces) })
        var done: [String] = []
        var doneSet = Set<String>()
        var pending = steps.map { step -> (String, [String]) in
            let key = step.key.trimmingCharacters(in: .whitespaces)
            return (key, step.dependsOn.filter { keys.contains($0) && $0 != key })
        }
        while !pending.isEmpty {
            let ready = pending.filter { _, deps in deps.allSatisfy(doneSet.contains) }
            if ready.isEmpty { return nil }
            for (key, _) in ready where doneSet.insert(key).inserted { done.append(key) }
            let readyKeys = Set(ready.map(\.0))
            pending.removeAll { readyKeys.contains($0.0) }
        }
        return done
    }

    /// 新加一步的键名：`step1`、`step2`……没用过的第一个。
    public static func nextKey(_ steps: [StepDraft]) -> String {
        let used = Set(steps.map { $0.key.trimmingCharacters(in: .whitespaces) })
        var n = 1
        while used.contains("step\(n)") { n += 1 }
        return "step\(n)"
    }

    /// 改一步的键名：别的步骤依赖它的跟着改。
    public static func rename(_ steps: [StepDraft], id: Int, to key: String) -> [StepDraft] {
        guard let old = steps.first(where: { $0.id == id })?.key else { return steps }
        return steps.map { step in
            var step = step
            if step.id == id {
                step.key = key
            } else if step.dependsOn.contains(old) {
                step.dependsOn = step.dependsOn.map { $0 == old ? key : $0 }
            }
            return step
        }
    }

    /// 删一步：别的步骤对它的依赖一起去掉。
    public static func remove(_ steps: [StepDraft], id: Int) -> [StepDraft] {
        guard let key = steps.first(where: { $0.id == id })?.key else { return steps }
        return steps.filter { $0.id != id }.map { step in
            var step = step
            step.dependsOn.removeAll { $0 == key }
            return step
        }
    }

    /// 上下挪一步（`delta` 是 -1 或 1）。
    public static func move(_ steps: [StepDraft], id: Int, by delta: Int) -> [StepDraft] {
        guard let i = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(i + delta) else { return steps }
        var result = steps
        result.swapAt(i, i + delta)
        return result
    }

    /// 键名输入时的清理：只留小写字母、数字、`_`、`-`（大写转小写），最多 32 个。
    public static func cleanKey(_ raw: String) -> String {
        String(
            raw.lowercased().unicodeScalars.filter { scalar in
                (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || scalar == "_" || scalar == "-"
            }
            .prefix(32)
            .map(Character.init))
    }

    /// 用团队建流水线：每个成员一步（按顺序），负责人最后一步、依赖前面所有步骤（汇总）。提示词留空等用户写。
    public static func fromTeam(_ team: Team, firstID: Int = 1) -> [StepDraft] {
        let ordered = team.members.sorted { $0.position < $1.position }
        var drafts = ordered.filter { !$0.isLead }.enumerated().map { index, member in
            StepDraft(id: firstID + index, key: "step\(index + 1)", instanceID: member.instanceID, prompt: "")
        }
        if let lead = team.lead {
            drafts.append(
                StepDraft(
                    id: firstID + drafts.count, key: "summary", instanceID: lead.instanceID, prompt: "",
                    dependsOn: drafts.map(\.key)))
        }
        return drafts
    }
}
