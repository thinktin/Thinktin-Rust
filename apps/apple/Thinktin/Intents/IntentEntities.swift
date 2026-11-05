import AppIntents
import ThinktinKit

// 快捷指令里能选的实例和计划（WBS 12.20）：每次现拉（`QuickActions`），不另存一份。

/// 快捷指令里选的 agent 实例。
struct InstanceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Botin"
    static let defaultQuery = InstanceEntityQuery()

    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ instance: Instance) {
        self.init(id: instance.id.rawValue, name: instance.name)
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct InstanceEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [InstanceEntity.ID]) async throws -> [InstanceEntity] {
        let wanted = Set(identifiers)
        return try await suggestedEntities().filter { wanted.contains($0.id) }
    }

    /// 主 Botin 在最前（只记在这台设备上，规范 4.4.5），其余最近活跃的在前，不含已删除的。
    @MainActor
    func suggestedEntities() async throws -> [InstanceEntity] {
        let instances = try await IntentContext.run { actions async throws(QuickActionError) in
            try await actions.instances()
        }
        return AppEnvironment.shared.appModel.local.primary.primaryFirst(instances).map(InstanceEntity.init)
    }

    /// 参数没填时默认是主 Botin（“给 Botin 下任务”不用每次选）；没设主 Botin、它删掉了或拉不到列表时为 nil，让用户选。
    @MainActor
    func defaultResult() async -> InstanceEntity? {
        let primary = AppEnvironment.shared.appModel.local.primary
        guard primary.primaryID != nil else { return nil }
        let instances = try? await IntentContext.run { actions async throws(QuickActionError) in
            try await actions.instances()
        }
        return primary.primary(in: instances ?? []).map(InstanceEntity.init)
    }
}

/// 快捷指令里选的计划。
struct PlanEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "计划"
    static let defaultQuery = PlanEntityQuery()

    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ plan: Plan) {
        self.init(id: plan.id.rawValue, title: plan.title)
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct PlanEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [PlanEntity.ID]) async throws -> [PlanEntity] {
        let wanted = Set(identifiers)
        return try await suggestedEntities().filter { wanted.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlanEntity] {
        try await IntentContext.run { actions async throws(QuickActionError) in
            try await actions.plans()
        }.map(PlanEntity.init)
    }
}
