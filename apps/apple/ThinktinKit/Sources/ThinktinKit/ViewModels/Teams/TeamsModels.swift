import Foundation
import Observation

/// 团队与模板（WBS 12.7，`.teams`，抽屉里的“团队”）：我的团队（负责人、成员数）和团队模板（一键领养整个团队、删除）。
/// 领养是全成或全不成（服务端 11.9）：放不下报实例数上限；成功后去新团队的详情，逐个给成员配模型路由。
@Observable @MainActor
public final class TeamsModel {
    public private(set) var teams: [Team] = []
    public private(set) var templates: [TeamTemplate] = []
    public private(set) var instanceNames: [InstanceID: String] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var actionError: ClientError?
    /// 正在领养 / 删除的模板。
    public private(set) var busyTemplate: TeamTemplateID?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol) {
        self.client = client
    }

    public func instanceName(_ id: InstanceID) -> String? { instanceNames[id] }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if instanceNames.isEmpty, let cached = try? client.cachedInstances() { instanceNames = TeamNames.of(cached) }
        do {
            teams = try await client.teams().sorted { $0.createdAt > $1.createdAt }
            templates = try await client.teamTemplates().sorted { $0.createdAt > $1.createdAt }
            error = nil
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
        if let fresh = try? await client.instances() { instanceNames = TeamNames.of(fresh) }
        hasLoaded = true
    }

    /// 一键领养；成功返回新团队（页面去它的详情）。
    public func adopt(_ template: TeamTemplate) async -> Team? {
        guard busyTemplate == nil else { return nil }
        busyTemplate = template.id
        actionError = nil
        defer { busyTemplate = nil }
        do {
            let team = try await client.adoptTeamTemplate(template.id, name: nil)
            teams.insert(team, at: 0)
            if let fresh = try? await client.instances() { instanceNames = TeamNames.of(fresh) }
            return team
        } catch {
            if let failure = ConversationErrors.from(error) { actionError = failure }
            return nil
        }
    }

    public func deleteTemplate(_ template: TeamTemplate) async {
        guard busyTemplate == nil else { return }
        busyTemplate = template.id
        actionError = nil
        defer { busyTemplate = nil }
        do {
            try await client.deleteTeamTemplate(template.id)
            templates.removeAll { $0.id == template.id }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { templates.removeAll { $0.id == template.id } } else { actionError = failure }
        }
    }

    public func clearActionError() {
        actionError = nil
    }
}

/// 团队详情（WBS 12.7，`.team(id)`）：负责人和成员（点进实例详情；“配模型”去实例的模型路由，领养来的团队逐个配 `main`）；
/// 编辑、存为模板（同名）、用这个团队建流水线、删除（只删团队，实例不动）。
@Observable @MainActor
public final class TeamDetailModel {
    public let teamID: TeamID
    public private(set) var team: Team?
    public private(set) var instanceNames: [InstanceID: String] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: ClientError?
    public private(set) var isMissing = false
    public private(set) var isWorking = false
    public private(set) var isDeleted = false
    public private(set) var actionError: ClientError?
    /// 刚存成了模板（页面提示一句）。
    public private(set) var savedTemplate: TeamTemplate?

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, teamID: TeamID) {
        self.client = client
        self.teamID = teamID
    }

    /// 成员：负责人在前，其余按顺序。
    public var members: [TeamMember] {
        (team?.members ?? []).sorted { a, b in
            if a.isLead != b.isLead { return a.isLead }
            return a.position < b.position
        }
    }

    public func instanceName(_ id: InstanceID) -> String? { instanceNames[id] }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            team = try await client.team(teamID)
            isMissing = false
            error = nil
            if let fresh = try? await client.instances() { instanceNames = TeamNames.of(fresh) }
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isMissing = true } else { self.error = failure }
        }
        hasLoaded = true
    }

    public func saveAsTemplate() async {
        guard let team, !isWorking else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            savedTemplate = try await client.createTeamTemplateFromTeam(name: team.name, teamID: team.id)
        } catch {
            if let failure = ConversationErrors.from(error) { actionError = failure }
        }
    }

    public func delete() async {
        guard team != nil, !isWorking else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await client.deleteTeam(teamID)
            isDeleted = true
        } catch {
            guard let failure = ConversationErrors.from(error) else { return }
            if failure.isNotFound { isDeleted = true } else { actionError = failure }
        }
    }

    public func clearActionError() {
        actionError = nil
    }

    public func clearSavedTemplate() {
        savedTemplate = nil
    }
}

/// 编辑团队表单的问题（保存前在本地拦下，和服务端规则一样，负责人要一个）。
public enum TeamFormProblem: Hashable, Sendable {
    case nameEmpty, nameTooLong, noMembers, tooManyMembers, noLead
}

/// 新建 / 编辑团队（WBS 12.7，团队列表、团队详情里的 sheet）：名字（1–64 字）、成员（从实例里选，1–12 个）、负责人（一个）。
/// 第一个选中的默认当负责人；负责人取消选择时换成剩下的第一个。
@Observable @MainActor
public final class TeamEditorModel {
    /// 最多几个成员（服务端 MAX_MEMBERS）。
    public nonisolated static let maxMembers = Team.maxMembers
    public nonisolated static let maxName = 64

    public let teamID: TeamID?
    public var name = ""
    /// 选中的实例，按选的顺序。
    public private(set) var selected: [InstanceID] = []
    public private(set) var lead: InstanceID?
    /// 能选的实例（不含已删除的），最近活跃的在前。
    public private(set) var instances: [Instance] = []
    public private(set) var hasLoaded = false
    public private(set) var error: ClientError?
    public private(set) var isSaving = false
    public private(set) var saveError: ClientError?
    /// 点过保存：显示问题。
    public private(set) var showsProblems = false

    @ObservationIgnored private let client: any ClientProtocol

    public init(client: any ClientProtocol, teamID: TeamID? = nil) {
        self.client = client
        self.teamID = teamID
    }

    public var problems: Set<TeamFormProblem> {
        var result = Set<TeamFormProblem>()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { result.insert(.nameEmpty) }
        if trimmed.unicodeScalars.count > Self.maxName { result.insert(.nameTooLong) }
        if selected.isEmpty { result.insert(.noMembers) }
        if selected.count > Self.maxMembers { result.insert(.tooManyMembers) }
        if !selected.isEmpty, lead.map(selected.contains) != true { result.insert(.noLead) }
        return result
    }

    /// 要提交的成员：负责人一个，其余是成员，按选的顺序编号。
    public var members: [TeamMember] {
        selected.enumerated().map { index, id in
            TeamMember(instanceID: id, role: id == lead ? .lead : .member, position: index)
        }
    }

    public func load() async {
        do {
            instances = try await client.instances().filter { $0.state != .deleted }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
            if let teamID, !hasLoaded {
                let team = try await client.team(teamID)
                name = team.name
                let ordered = team.members.sorted { $0.position < $1.position }
                let alive = Set(instances.map(\.id))
                selected = ordered.map(\.instanceID).filter(alive.contains)
                lead = team.lead?.instanceID
            }
            error = nil
            hasLoaded = true
        } catch {
            if let failure = ConversationErrors.from(error) { self.error = failure }
        }
    }

    public func toggle(_ id: InstanceID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
            if lead == id { lead = selected.first }
        } else {
            selected.append(id)
            if lead == nil { lead = id }
        }
    }

    public func setLead(_ id: InstanceID) {
        if !selected.contains(id) { selected.append(id) }
        lead = id
    }

    /// 保存；成功返回团队。
    public func save() async -> Team? {
        guard !isSaving else { return nil }
        guard problems.isEmpty else {
            showsProblems = true
            return nil
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let teamID {
                return try await client.updateTeam(teamID, name: trimmed, members: members)
            }
            return try await client.createTeam(name: trimmed, members: members)
        } catch {
            if let failure = ConversationErrors.from(error) { saveError = failure }
            return nil
        }
    }
}

/// 实例 id → 名字（不含已删除的）。
enum TeamNames {
    static func of(_ instances: [Instance]) -> [InstanceID: String] {
        Dictionary(
            instances.filter { $0.state != .deleted }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
