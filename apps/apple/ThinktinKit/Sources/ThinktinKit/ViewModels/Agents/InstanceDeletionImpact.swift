import Foundation

/// 删除一个实例会连带影响什么（ios-packages.md 12.3：删除确认页列出别的计划里的流水线步骤和团队成员身份）。
///
/// `DELETE /v1/instances/{id}` 不会因为实例忙而拒绝（11.9 起的规则，见 crates/client-core/src/ffi.rs 的 `delete_instance`）：
/// 它直接取消实例上没结束的运行、吊销授权、删除实例，模型别名一起删；它自己的计划一起删掉；别的实例的流水线计划有一步
/// 在它上面的，步骤留着（指着已删除的实例），正在生效的计划暂停，之后恢复、确认都报 409，要先把这些步骤改到别的实例上；
/// 团队里不再列出它。删除确认页按 `Plan.instanceID` 和 `Plan.steps[].instanceID` 分成这两组列出来。
public struct InstanceDeletionImpact: Hashable, Sendable {
    public var instanceID: InstanceID
    /// 这个实例自己的计划（一起删掉；列表接口里的，没有步骤）。
    public var ownPlans: [Plan]
    /// 别的实例的流水线计划里在这个实例上的步骤，按计划分组：删除后这些计划停下来，改了步骤才能恢复。
    public var pipelines: [PipelineImpact]
    /// 这个实例在哪些团队里（会被移出）。
    public var teams: [TeamImpact]
    /// 会被停掉的运行（没结束的）。
    public var activeRuns: Int
    /// 会一起删掉的产出物；nil 是没查到。
    public var artifactCount: Int?
    /// 有没查全的（计划、团队、运行、产出物里有拉不到的）：确认页提示“可能还有别的影响”。
    public var isIncomplete: Bool

    public init(
        instanceID: InstanceID, ownPlans: [Plan] = [], pipelines: [PipelineImpact] = [], teams: [TeamImpact] = [],
        activeRuns: Int = 0, artifactCount: Int? = nil, isIncomplete: Bool = false
    ) {
        self.instanceID = instanceID
        self.ownPlans = ownPlans
        self.pipelines = pipelines
        self.teams = teams
        self.activeRuns = activeRuns
        self.artifactCount = artifactCount
        self.isIncomplete = isIncomplete
    }

    /// 一个别的实例的流水线计划、有步骤在这个实例上（11.9）。
    public struct PipelineImpact: Identifiable, Hashable, Sendable {
        /// 删除后这条流水线会怎样。
        public enum Effect: Hashable, Sendable {
            /// 正在生效（没暂停、不在等确认）：服务端把它暂停。
            case paused
            /// 已经暂停了：保持暂停。
            case stillPaused
            /// 在等确认（agent 建的、改的）：确认前要先改步骤。
            case confirmationBlocked

            /// 删除确认页上这条流水线下面的一句话。
            public func message(_ language: DisplayLanguage = .current) -> String {
                let zh = language == .chinese
                switch self {
                case .paused:
                    return zh
                        ? "删除后这条流水线会暂停，把这些步骤改到别的实例上才能恢复。"
                        : "This pipeline will be paused. Move these steps to another instance to resume it."
                case .stillPaused:
                    return zh
                        ? "它已经暂停了，把这些步骤改到别的实例上才能恢复。"
                        : "It's already paused. Move these steps to another instance to resume it."
                case .confirmationBlocked:
                    return zh
                        ? "它在等你确认，确认之前要先把这些步骤改到别的实例上。"
                        : "It's waiting for your confirmation. Move these steps to another instance before confirming."
                }
            }
        }

        /// 计划（详情接口拉的，带步骤）。标题是 agent 写的时要带 AI 生成标识（`AgentsText.isAIGenerated(_:)`）。
        public var plan: Plan
        /// 在这个实例上的步骤：删除后留在流水线里、指着已删除的实例，改到别的实例上之前计划恢复、确认都报 409。
        public var stepsOnInstance: [PlanStep]

        public var id: PlanID { plan.id }

        public init(plan: Plan, stepsOnInstance: [PlanStep]) {
            self.plan = plan
            self.stepsOnInstance = stepsOnInstance
        }

        /// 按计划现在的状态（和服务端一样：只暂停正在生效的，等确认的在服务端本来就算暂停）。
        public var effect: Effect {
            if plan.awaitingConfirmation { return .confirmationBlocked }
            return plan.isPaused ? .stillPaused : .paused
        }

        /// 删除时会被暂停（现在正在生效）。
        public var willPause: Bool { effect == .paused }
    }

    /// 一个会少一个成员的团队。
    public struct TeamImpact: Identifiable, Hashable, Sendable {
        public var teamID: TeamID
        public var teamName: String
        /// 这个实例是团队的负责人：删掉后团队没有负责人，委派没人分工。
        public var isLead: Bool
        /// 删完还剩几个成员（0 时团队还在，但没有成员了）。
        public var remainingMembers: Int

        public var id: TeamID { teamID }

        public init(teamID: TeamID, teamName: String, isLead: Bool, remainingMembers: Int) {
            self.teamID = teamID
            self.teamName = teamName
            self.isLead = isLead
            self.remainingMembers = remainingMembers
        }
    }

    /// 会影响别的流水线、团队（要特别提醒的级联）。
    public var hasCascade: Bool { !pipelines.isEmpty || !teams.isEmpty }

    /// 删除时会被暂停的流水线（现在正在生效的）。
    public var pipelinesToPause: [PipelineImpact] { pipelines.filter(\.willPause) }

    // MARK: 计算

    /// 按拉到的数据算影响（纯函数）。
    ///
    /// - Parameters:
    ///   - plans: 全部计划；别的实例的计划要是详情（带步骤），这个实例自己的计划用列表里的就行。
    ///   - teams: 全部团队。
    ///   - runs: 这个实例最近的运行（数没结束的）。
    ///   - artifactCount: 这个实例的产出物个数，没查到为 nil。
    public static func compute(
        instanceID: InstanceID, plans: [Plan], teams: [Team], runs: [Run], artifactCount: Int?,
        isIncomplete: Bool = false
    ) -> InstanceDeletionImpact {
        let ownPlans = plans.filter { $0.instanceID == instanceID }
        let pipelines = plans.filter { $0.instanceID != instanceID }.compactMap { plan -> PipelineImpact? in
            let steps = plan.steps.filter { $0.instanceID == instanceID }
            return steps.isEmpty ? nil : PipelineImpact(plan: plan, stepsOnInstance: steps)
        }
        let teamImpacts = teams.compactMap { team -> TeamImpact? in
            guard let member = team.members.first(where: { $0.instanceID == instanceID }) else { return nil }
            return TeamImpact(
                teamID: team.id, teamName: team.name, isLead: member.isLead, remainingMembers: team.members.count - 1)
        }
        let active = runs.filter { $0.instanceID == instanceID && RunFilter.active.matches($0) }.count
        return InstanceDeletionImpact(
            instanceID: instanceID, ownPlans: ownPlans, pipelines: pipelines, teams: teamImpacts, activeRuns: active,
            artifactCount: artifactCount, isIncomplete: isIncomplete)
    }

    // MARK: 查询

    /// 数没结束的运行时看最近几个。
    public static let runsToCheck = 50
    /// 数产出物时最多拉几个（接口上限 500）。
    public static let artifactsToCheck = 500

    /// 查删除的影响：先拉全部计划（`plans(nil)`），再同时拉别的计划的详情（只有详情里有步骤）、团队、最近的运行、产出物。
    /// 返回影响和第一个错误（有拉不到的时候 `isIncomplete`）；计划详情是 not_found 的（刚被删了）跳过，不算没查全。
    /// 任务被取消时返回 nil。
    public static func check(
        instanceID: InstanceID, client: any ClientProtocol
    ) async -> (impact: InstanceDeletionImpact, error: ClientError?)? {
        var errors: [ClientError] = []
        var cancelled = false
        func note(_ error: any Error) {
            if let failure = AgentsErrors.from(error) { errors.append(failure) } else { cancelled = true }
        }

        var plans: [Plan] = []
        do {
            plans = try await client.plans(instanceID: nil)
        } catch {
            note(error)
        }
        if cancelled { return nil }

        let others = plans.filter { $0.instanceID != instanceID }
        async let details = planDetails(others, client: client)
        async let teamsResult = AgentsErrors.attempt { try await client.teams() }
        async let runsResult = AgentsErrors.attempt {
            try await client.runs(instanceID: instanceID, limit: runsToCheck)
        }
        async let artifactsResult = AgentsErrors.attempt {
            try await client.instanceArtifacts(instanceID, limit: artifactsToCheck)
        }

        let (detailed, detailErrors) = await details
        detailErrors.forEach(note)
        var teams: [Team] = []
        switch await teamsResult {
        case .success(let list): teams = list
        case .failure(let error): note(error)
        }
        var runs: [Run] = []
        switch await runsResult {
        case .success(let list): runs = list
        case .failure(let error): note(error)
        }
        var artifactCount: Int?
        switch await artifactsResult {
        case .success(let list): artifactCount = list.count
        case .failure(let error): note(error)
        }
        if cancelled { return nil }

        let own = plans.filter { $0.instanceID == instanceID }
        let impact = compute(
            instanceID: instanceID, plans: own + detailed, teams: teams, runs: runs, artifactCount: artifactCount,
            isIncomplete: !errors.isEmpty)
        return (impact, errors.first)
    }

    /// 同时拉几个计划的详情（带步骤），按原来的顺序；not_found 的跳过。
    private static func planDetails(_ plans: [Plan], client: any ClientProtocol) async -> ([Plan], [any Error]) {
        await withTaskGroup(of: (Int, Result<Plan, any Error>).self) { group in
            for (index, plan) in plans.enumerated() {
                let planID = plan.id
                group.addTask { (index, await AgentsErrors.attempt { try await client.getPlan(planID) }) }
            }
            var found: [(Int, Plan)] = []
            var errors: [any Error] = []
            for await (index, result) in group {
                switch result {
                case .success(let plan): found.append((index, plan))
                case .failure(let error):
                    if (error as? ClientError)?.isNotFound == true { continue }
                    errors.append(error)
                }
            }
            return (found.sorted { $0.0 < $1.0 }.map(\.1), errors)
        }
    }
}
